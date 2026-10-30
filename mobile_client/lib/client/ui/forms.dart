import 'package:flutter/material.dart';

import '../session.dart';
import '../models.dart';
import 'components.dart';

class ForecastForm extends StatefulWidget {
  const ForecastForm({super.key, required this.controller});
  final SessionController controller;
  @override
  State<ForecastForm> createState() => _ForecastFormState();
}

class _ForecastFormState extends State<ForecastForm> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(),
      _body = TextEditingController(),
      _quantity = TextEditingController();
  late final _region = TextEditingController(
    text: widget.controller.user!.region,
  );
  final _priceMin = TextEditingController(),
      _priceMax = TextEditingController();
  late String _purpose = widget.controller.user!.role == UserRole.trader
      ? 'Demand'
      : 'Supply';
  DateTime? _available;
  List<Json> _products = [];
  String? _product, _error;
  bool _loading = true, _busy = false;
  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _quantity.dispose();
    _region.dispose();
    _priceMin.dispose();
    _priceMax.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.controller.api.get('/catalog/products');
      if (!mounted) return;
      setState(() {
        _products = rows(data);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      await widget.controller.api.post('/posts', {
        'title': _title.text.trim(),
        'body': _body.text.trim(),
        'productCode': _product,
        'estimatedQuantityKg': double.parse(
          _quantity.text.trim().replaceAll(',', '.'),
        ),
        'region': _region.text.trim(),
        'purpose': _purpose,
        if (_available != null)
          'availableOn':
              '${_available!.year}-${_available!.month.toString().padLeft(2, '0')}-${_available!.day.toString().padLeft(2, '0')}',
        if (_priceMin.text.trim().isNotEmpty)
          'priceMinVndPerKg': double.parse(
            _priceMin.text.trim().replaceAll(',', '.'),
          ),
        if (_priceMax.text.trim().isNotEmpty)
          'priceMaxVndPerKg': double.parse(
            _priceMax.text.trim().replaceAll(',', '.'),
          ),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã gửi tin dự kiến, đang chờ kiểm duyệt.'),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  String? _priceError(String? text, {bool upper = false}) {
    final other = upper ? _priceMin.text.trim() : _priceMax.text.trim();
    if ((text?.trim().isEmpty ?? true) && other.isEmpty) return null;
    if ((text?.trim().isEmpty ?? true) || other.isEmpty) {
      return 'Điền cả hai giá chào hoặc để trống cả hai.';
    }
    final price = double.tryParse(text!.trim().replaceAll(',', '.'));
    if (price == null || !price.isFinite || price <= 0 || price > 1000000000) {
      return 'Nhập giá lớn hơn 0, tối đa 1 tỷ đ/kg.';
    }
    if ((price * 100 - (price * 100).round()).abs() > .000001) {
      return 'Giá chào có tối đa hai chữ số thập phân.';
    }
    final low = double.tryParse(_priceMin.text.trim().replaceAll(',', '.'));
    return upper && low != null && price < low
        ? 'Giá tối đa cần lớn hơn hoặc bằng giá tối thiểu.'
        : null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Tạo tin dự kiến')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle(
                'Giới thiệu nông sản',
                subtitle: 'Số lượng là dự kiến, chưa phải hàng tồn kho. Tin được gửi để kiểm duyệt trước khi công bố.',
              ),
              if (_error != null) ...[
                MessageBox(_error!, error: true),
                const SizedBox(height: 16),
              ],
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_products.isEmpty)
                OutlinedButton.icon(
                  onPressed: _loadProducts,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tải lại danh mục nông sản'),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _product,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Nông sản'),
                  items: _products
                      .map(
                        (p) => DropdownMenuItem(
                          value: value(p, 'code'),
                          child: Text(value(p, 'name')),
                        ),
                      )
                      .toList(),
                  validator: (v) => v == null ? 'Chọn nông sản.' : null,
                  onChanged: _busy ? null : (v) => setState(() => _product = v),
                ),
              const SizedBox(height: 16),
              if (widget.controller.user!.role == UserRole.trader) ...[
                DropdownButtonFormField<String>(
                  initialValue: _purpose,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Mục đích đăng tin',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Demand',
                      child: Text('Nhu cầu thu mua'),
                    ),
                    DropdownMenuItem(
                      value: 'Supply',
                      child: Text('Nguồn cung dự kiến'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null) setState(() => _purpose = value);
                        },
                ),
                const SizedBox(height: 16),
              ] else ...[
                const Text(
                  'Nguồn cung dự kiến',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _region,
                enabled: !_busy,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Khu vực nông sản / nhu cầu',
                ),
                validator: requiredText,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _title,
                enabled: !_busy,
                maxLength: 160,
                decoration: const InputDecoration(labelText: 'Tiêu đề'),
                textInputAction: TextInputAction.next,
                validator: (v) => requiredText(v, min: 5),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantity,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Số lượng dự kiến (kg)',
                ),
                validator: (v) {
                  final number = double.tryParse(
                    v?.trim().replaceAll(',', '.') ?? '',
                  );
                  return number == null ||
                          !number.isFinite ||
                          number < .001 ||
                          number > 1000000
                      ? 'Nhập số từ 0,001 đến 1.000.000 kg.'
                      : null;
                },
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final now = DateTime.now();
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _available ?? now,
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: now.add(const Duration(days: 730)),
                        );
                        if (mounted && date != null) {
                          setState(() => _available = date);
                        }
                      },
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  _available == null
                      ? 'Chọn ngày dự kiến (tùy chọn)'
                      : '${_available!.day}/${_available!.month}/${_available!.year}',
                ),
              ),
              if (_available != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _available = null),
                  child: const Text('Bỏ ngày dự kiến'),
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _priceMin,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Giá chào tối thiểu (đ/kg, tùy chọn)',
                ),
                validator: _priceError,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _priceMax,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Giá chào tối đa (đ/kg, tùy chọn)',
                ),
                validator: (value) => _priceError(value, upper: true),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _body,
                enabled: !_busy,
                minLines: 4,
                maxLines: 8,
                maxLength: 5000,
                decoration: const InputDecoration(
                  labelText: 'Mô tả / thời gian dự kiến',
                ),
                validator: (v) => requiredText(v, min: 10),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy || _loading || _products.isEmpty
                    ? null
                    : _submit,
                child: Text(_busy ? 'Đang gửi…' : 'Gửi kiểm duyệt'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ResubmitForm extends StatefulWidget {
  const ResubmitForm({super.key, required this.controller});
  final SessionController controller;
  @override
  State<ResubmitForm> createState() => _ResubmitFormState();
}

class _ResubmitFormState extends State<ResubmitForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.controller.user!.displayName,
  );
  late final _region = TextEditingController(
    text: widget.controller.user!.region,
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _region.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.controller.resubmit(
      displayName: _name.text.trim(),
      region: _region.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = widget.controller.error;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bổ sung hồ sơ')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionTitle(
                'Cập nhật thông tin',
                subtitle:
                    widget.controller.user!.reviewReason ??
                    'Kiểm tra thông tin và gửi lại để quản trị xét duyệt.',
              ),
              if (_error != null) ...[
                MessageBox(_error!, error: true),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _name,
                enabled: !_busy,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Tên hiển thị'),
                validator: requiredText,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _region,
                enabled: !_busy,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Khu vực / tỉnh thành',
                ),
                validator: requiredText,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? 'Đang gửi…' : 'Gửi lại hồ sơ'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
