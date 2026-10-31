import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../media.dart';
import '../api.dart';
import '../session.dart';
import 'components.dart';
import 'event_refresh.dart';
import 'location_picker.dart';
import 'moderation.dart';
import 'photo_viewer.dart';

String roleName(Object? role) =>
    role == 'Producer' ? 'Nhà sản xuất' : 'Thương lái';

class RoleApplicationsPage extends StatefulWidget {
  const RoleApplicationsPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<RoleApplicationsPage> createState() => _RoleApplicationsPageState();
}

class _RoleApplicationsPageState extends State<RoleApplicationsPage> {
  final _list = GlobalKey<ApiListState>();
  bool _busy = false;
  String? _error;
  Future<void> _create(String role) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await widget.controller.api.post('/role-applications', {
        'requestedRole': role,
      });
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RoleApplicationPage(
            controller: widget.controller,
            id: value(data, 'id'),
          ),
        ),
      );
      _list.currentState?.reload();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.controller.user!;
    final canApply =
        user.role == UserRole.consumer &&
        user.isApproved &&
        user.emailConfirmed;
    return Scaffold(
      appBar: AppBar(title: const Text('Vai trò kinh doanh')),
      body: SafeArea(
        child: LiveApiList(
          listKey: _list,
          api: widget.controller.api,
          path: '/role-applications?limit=20',
          targets: const {'RoleApplicationChanged'},
          empty: 'Bạn chưa có hồ sơ nâng vai trò.',
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle(
                'Nâng vai trò kinh doanh',
                subtitle: 'Tài khoản vẫn là Người tiêu dùng cho đến khi quản trị chấp thuận hồ sơ và chứng từ.',
              ),
              if (!canApply)
                const MessageBox(
                  'Tạo hồ sơ yêu cầu tài khoản Người tiêu dùng đang hoạt động, đã được duyệt và đã xác minh email.',
                ),
              if (_error != null) MessageBox(_error!, error: true),
              if (canApply) ...[
                FilledButton.icon(
                  onPressed: _busy ? null : () => _create('Producer'),
                  icon: const Icon(Icons.agriculture_outlined),
                  label: const Text('Đăng ký Nhà sản xuất'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _create('Trader'),
                  icon: const Icon(Icons.storefront_outlined),
                  label: const Text('Đăng ký Thương lái'),
                ),
              ],
              const SizedBox(height: 20),
            ],
          ),
          itemBuilder: (row) => DataCard(
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RoleApplicationPage(
                    controller: widget.controller,
                    id: value(row, 'id'),
                  ),
                ),
              );
              _list.currentState?.reload();
            },
            children: [
              Text(
                roleName(row['requestedRole']),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(applicationStatus(row['status'])),
              if (value(row, 'organisationName').isNotEmpty)
                Text(value(row, 'organisationName')),
              Text(displayTime(row['createdAt'])),
            ],
          ),
        ),
      ),
    );
  }
}

class RoleApplicationPage extends StatefulWidget {
  const RoleApplicationPage({
    super.key,
    required this.controller,
    required this.id,
    this.admin = false,
    this.picker,
  });
  final SessionController controller;
  final String id;
  final bool admin;
  final NativeEvidencePicker? picker;
  @override
  State<RoleApplicationPage> createState() => _RoleApplicationPageState();
}

class _RoleApplicationPageState extends State<RoleApplicationPage> {
  final _form = GlobalKey<FormState>();
  final _organisation = TextEditingController(),
      _address = TextEditingController(),
      _phone = TextEditingController(),
      _area = TextEditingController(),
      _tax = TextEditingController(),
      _registration = TextEditingController();
  late final _picker = widget.picker ?? NativeEvidencePicker();
  Json? _data;
  List<Json> _catalog = [];
  final _products = <String>{};
  LocationSelection? _location;
  String? _error, _notice;
  bool _busy = false;
  UploadCancellation? _upload;
  String get path =>
      '/${widget.admin ? 'admin/' : ''}role-applications/${Uri.encodeComponent(widget.id)}';
  bool get _editable =>
      !widget.admin &&
      {'Draft', 'NeedsInformation', 'Rejected'}.contains(_data?['status']);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.controller.api.get(path),
        widget.controller.api.get('/catalog/products'),
      ]);
      if (!mounted) return;
      final data = results[0];
      setState(() {
        _data = data;
        _catalog = rows(results[1]);
        _error = null;
        _organisation.text = value(data, 'organisationName');
        _address.text = value(data, 'address');
        _phone.text = value(data, 'phone');
        _area.text = value(data, 'cultivatedAreaHa');
        _tax.text = value(data, 'taxCode');
        _registration.text = value(data, 'businessRegistrationNumber');
        _products
          ..clear()
          ..addAll((data['products'] as List? ?? []).whereType<String>());
        _location = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _mutate(
    Future<Json?> Function() action, {
    String? successMessage,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final next = await action();
      if (next == null) return;
      if (mounted) {
        setState(() {
          _data = next;
          _notice = next['status'] == 'Submitted'
              ? 'Đã gửi xét duyệt. Quản trị sẽ thấy hồ sơ trong danh sách chờ.'
              : successMessage ??
                    'Đã lưu bản nháp. Hồ sơ chưa được gửi xét duyệt.';
        });
      }
    } catch (e) {
      if (e is ApiException && e.status == 409) await _load();
      if (mounted) {
        setState(
          () => _error = e is ApiException && e.status == 409
              ? 'Hồ sơ đã thay đổi. Đã tải lại; hãy kiểm tra và thử lại.'
              : errorText(e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool submit = false}) async {
    if (_busy) return;
    if (submit && (_data?['evidence'] as List? ?? []).isEmpty) {
      setState(
        () => _error = 'Thêm ít nhất một chứng từ trước khi gửi xét duyệt.',
      );
      return;
    }
    if (!_form.currentState!.validate() ||
        _products.isEmpty ||
        _products.length > 8 ||
        _location == null) {
      setState(
        () => _error = 'Hoàn tất hồ sơ, chọn địa giới và từ 1 đến 8 sản phẩm.',
      );
      return;
    }
    final producer = _data!['requestedRole'] == 'Producer';
    if (!producer &&
        _tax.text.trim().isEmpty &&
        _registration.text.trim().isEmpty) {
      setState(
        () => _error = 'Thương lái cần mã số thuế hoặc số đăng ký kinh doanh.',
      );
      return;
    }
    await _mutate(() async {
      final saved = await widget.controller.api.put(
        '/role-applications/${Uri.encodeComponent(widget.id)}',
        {
          'organisationName': _organisation.text.trim(),
          'address': _address.text.trim(),
          'phone': _phone.text.trim(),
          'countryCode': _location!.countryCode,
          'provinceCode': _location!.provinceCode,
          'products': _products.toList(),
          'cultivatedAreaHa': producer
              ? double.parse(_area.text.replaceAll(',', '.'))
              : null,
          'taxCode': producer || _tax.text.trim().isEmpty
              ? null
              : _tax.text.trim(),
          'businessRegistrationNumber':
              producer || _registration.text.trim().isEmpty
              ? null
              : _registration.text.trim(),
          'expectedRevision': _data!['revision'],
        },
      );
      if (!submit) return saved;
      if (mounted) setState(() => _data = saved);
      final submitted = await widget.controller.api.post(
        '/role-applications/${Uri.encodeComponent(widget.id)}/submit',
        {'expectedRevision': saved['revision']},
      );
      if (submitted['status'] != 'Submitted') {
        throw const ApiException(
          'Chưa nhận được xác nhận gửi xét duyệt. Tải lại hồ sơ để kiểm tra.',
        );
      }
      return submitted;
    });
  }

  Future<void> _addEvidence() async {
    await _mutate(
      () async {
        final picked = await _picker.pick();
        if (picked == null) return null;
        try {
          if (!mounted) return null;
          _upload = UploadCancellation();
          return await widget.controller.api.uploadEvidence(
            applicationId: widget.id,
            category: _data!['requestedRole'] == 'Producer'
                ? 'ProductionEvidence'
                : 'BusinessEvidence',
            expectedRevision: _data!['revision'] as int,
            file: File(picked.path),
            contentType: picked.contentType,
            cancellation: _upload,
          );
        } finally {
          _upload = null;
          await _picker.delete(picked);
        }
      },
      successMessage: 'Đã thêm chứng từ. Hồ sơ vẫn chưa gửi; bấm Gửi xét duyệt để chuyển cho quản trị.',
    );
  }

  Future<void> _viewEvidence(Json evidence) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await widget.controller.api.evidenceBytes(
        widget.id,
        value(evidence, 'id'),
        admin: widget.admin,
      );
      if (!mounted) return;
      final contentType = value(evidence, 'contentType');
      if (contentType == 'image/jpeg' || contentType == 'image/png') {
        try {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  PhotoViewerPage(bytes: bytes, title: 'Ảnh minh chứng'),
            ),
          );
        } finally {
          await ResizeImage(
            MemoryImage(bytes),
            width: 2048,
            height: 2048,
            policy: ResizeImagePolicy.fit,
          ).evict();
          bytes.fillRange(0, bytes.length, 0);
        }
      } else {
        await _picker.view(bytes, contentType);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? errorText(e)
              : value(evidence, 'contentType') == 'application/pdf'
              ? 'Không mở được PDF. Thiết bị cần ứng dụng đọc PDF phù hợp.'
              : 'Không mở được ảnh minh chứng. Hãy tải lại hoặc kiểm tra tệp đã gửi.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _upload?.cancel();
    for (final field in [
      _organisation,
      _address,
      _phone,
      _area,
      _tax,
      _registration,
    ]) {
      field.dispose();
    }
    unawaited(_picker.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data, producer = data?['requestedRole'] == 'Producer';
    final evidence = (data?['evidence'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Hồ sơ nâng vai trò')),
      bottomNavigationBar: _editable
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) MessageBox(_error!, error: true),
                    Text(
                      evidence.isEmpty
                          ? 'Bước tiếp theo: thêm ít nhất một chứng từ.'
                          : 'Bản nháp chưa gửi · ${evidence.length} chứng từ đã tải lên.',
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _busy ? null : _save,
                            child: const Text('Lưu bản nháp'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: _busy ? null : () => _save(submit: true),
                            child: Text(
                              _busy ? 'Đang xử lý…' : 'Gửi xét duyệt',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null && !_editable)
                MessageBox(_error!, error: true),
              if (_notice != null) MessageBox(_notice!),
              if (data == null && _error == null)
                const LinearProgressIndicator(),
              if (data != null) ...[
                SectionTitle(
                  roleName(data['requestedRole']),
                  subtitle: applicationStatus(data['status']),
                ),
                if (_editable)
                  const MessageBox(
                    'Lưu nháp và tải chứng từ chưa phải gửi hồ sơ. Khi hoàn tất, bấm Gửi xét duyệt ở cuối màn hình. Chỉ khi trạng thái là Đã gửi xét duyệt quản trị mới nhận được hồ sơ.',
                  ),
                if (value(data, 'reviewReason').isNotEmpty)
                  MessageBox(value(data, 'reviewReason')),
                if (_editable)
                  Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _organisation,
                          enabled: !_busy,
                          maxLength: 160,
                          decoration: const InputDecoration(
                            labelText: 'Đơn vị / hộ kinh doanh',
                          ),
                          validator: requiredText,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _address,
                          enabled: !_busy,
                          maxLength: 240,
                          decoration: const InputDecoration(
                            labelText: 'Địa chỉ liên hệ',
                          ),
                          validator: (v) => requiredText(v, min: 5),
                        ),
                        const SizedBox(height: 12),
                        CountryProvincePicker(
                          key: ValueKey(
                            '${data['id']}:${data['countryCode']}:${data['provinceCode']}',
                          ),
                          api: widget.controller.api,
                          countryCode: data['countryCode'] as String?,
                          provinceCode: data['provinceCode'] as String?,
                          enabled: !_busy,
                          onChanged: (v) => _location = v,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _phone,
                          enabled: !_busy,
                          keyboardType: TextInputType.phone,
                          maxLength: 30,
                          decoration: const InputDecoration(
                            labelText: 'Số điện thoại',
                          ),
                          validator: (v) => requiredText(v, min: 7),
                        ),
                        const SizedBox(height: 12),
                        if (producer)
                          TextFormField(
                            controller: _area,
                            enabled: !_busy,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Diện tích canh tác (ha)',
                            ),
                            validator: (v) =>
                                (double.tryParse(
                                          (v ?? '').replaceAll(',', '.'),
                                        ) ??
                                        0) >
                                    0
                                ? null
                                : 'Nhập diện tích lớn hơn 0.',
                          )
                        else ...[
                          TextFormField(
                            controller: _tax,
                            enabled: !_busy,
                            maxLength: 40,
                            decoration: const InputDecoration(
                              labelText: 'Mã số thuế',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _registration,
                            enabled: !_busy,
                            maxLength: 80,
                            decoration: const InputDecoration(
                              labelText: 'Số đăng ký kinh doanh',
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        const Text('Sản phẩm kinh doanh (1–8 loại)'),
                        Wrap(
                          spacing: 8,
                          children: _catalog
                              .map(
                                (p) => FilterChip(
                                  label: Text(value(p, 'name')),
                                  selected: _products.contains(p['code']),
                                  onSelected: _busy
                                      ? null
                                      : (selected) => setState(() {
                                          if (selected) {
                                            _products.add(value(p, 'code'));
                                          } else {
                                            _products.remove(p['code']);
                                          }
                                        }),
                                ),
                              )
                              .toList(),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  )
                else
                  DataCard(
                    children: [
                      Text(value(data, 'organisationName')),
                      Text(value(data, 'address')),
                      Text(value(data, 'region')),
                      Text(value(data, 'phone')),
                      Text(
                        'Sản phẩm: ${(data['products'] as List? ?? []).join(', ')}',
                      ),
                      if (producer)
                        Text('Diện tích: ${data['cultivatedAreaHa']} ha')
                      else ...[
                        Text('Mã số thuế: ${value(data, 'taxCode')}'),
                        Text(
                          'Đăng ký kinh doanh: ${value(data, 'businessRegistrationNumber')}',
                        ),
                      ],
                    ],
                  ),
                const SizedBox(height: 20),
                const SectionTitle(
                  'Chứng từ riêng tư',
                  subtitle: 'JPEG, PNG hoặc PDF; mỗi tệp tối đa 5 MiB, tối đa 4 tệp. Chỉ chủ hồ sơ và quản trị được xem.',
                ),
                ...evidence.map(
                  (e) => DataCard(
                    children: [
                      Text(
                        '${value(e, 'contentType')} · ${((e['sizeBytes'] as num? ?? 0) / 1024).round()} KiB',
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _viewEvidence(e),
                        icon: const Icon(Icons.visibility_outlined),
                        label: const Text('Xem chứng từ'),
                      ),
                      if (_editable)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _mutate(
                                  () => widget.controller.api.delete(
                                    '/role-applications/${Uri.encodeComponent(widget.id)}/evidence/${Uri.encodeComponent(value(e, 'id'))}?expectedRevision=${data['revision']}',
                                  ),
                                ),
                          child: const Text('Xóa chứng từ'),
                        ),
                    ],
                  ),
                ),
                if (evidence.isEmpty)
                  const Text('Chưa có chứng từ được tải lên.'),
                if (_editable) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy || evidence.length >= 4
                        ? null
                        : _addEvidence,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Thêm chứng từ'),
                  ),
                  const SizedBox(height: 12),
                ],
                if (widget.admin && data['status'] == 'Submitted')
                  ReviewActions(
                    controller: widget.controller,
                    path: path,
                    data: data,
                    onUpdated: (next) => setState(() => _data = next),
                    reload: _load,
                  ),
                if (!widget.admin && data['status'] == 'Approved')
                  FilledButton(
                    onPressed: widget.controller.busy
                        ? null
                        : widget.controller.refreshProfile,
                    child: const Text('Cập nhật quyền tài khoản'),
                  ),
              ],
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Tải lại hồ sơ'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
