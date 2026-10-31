import 'package:flutter/material.dart';

import '../session.dart';
import 'components.dart';

class AdminAppointmentsPage extends StatefulWidget {
  const AdminAppointmentsPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<AdminAppointmentsPage> createState() => _AdminAppointmentsPageState();
}

class _AdminAppointmentsPageState extends State<AdminAppointmentsPage> {
  final _search = TextEditingController(),
      _password = TextEditingController(),
      _reason = TextEditingController(),
      _form = GlobalKey<FormState>();
  List<Json> _candidates = [];
  Json? _selected;
  String? _error, _notice;
  bool _loading = false, _busy = false, _submitting = false;
  int _generation = 0;
  bool get _allowed =>
      widget.controller.user?.isAdmin == true &&
      widget.controller.user?.isApproved == true &&
      widget.controller.user?.isActive == true &&
      !widget.controller.endingSession;
  @override
  void initState() {
    super.initState();
    if (_allowed) _load();
  }

  Future<void> _load() async {
    if (!_allowed || _busy) return;
    final generation = ++_generation, origin = widget.controller.api.baseUrl;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.controller.api.get(
        '/admin/admin-candidates?limit=20&search=${Uri.encodeQueryComponent(_search.text.trim())}',
      );
      if (mounted &&
          _allowed &&
          generation == _generation &&
          origin == widget.controller.api.baseUrl) {
        setState(() => _candidates = rows(result));
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _appoint() async {
    if (!_allowed ||
        _busy ||
        _selected == null ||
        !_form.currentState!.validate()) {
      return;
    }
    final candidate = _selected!,
        origin = widget.controller.api.baseUrl,
        administrator = widget.controller.user!.id;
    // Lock the form while the explicit decision dialog is open, too.
    setState(() => _busy = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Xác nhận bổ nhiệm quản trị viên?'),
          content: Text(
            '${value(candidate, 'displayName')} sẽ có quyền quản trị và xét duyệt. Chỉ tiếp tục khi bạn đã kiểm tra đúng người.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xác nhận bổ nhiệm'),
            ),
          ],
        ),
      );
      if (!mounted ||
          confirmed != true ||
          !_allowed ||
          origin != widget.controller.api.baseUrl ||
          administrator != widget.controller.user?.id) {
        return;
      }
      setState(() => _submitting = true);
      final password = _password.text;
      _password.clear();
      await widget.controller.api.post('/admin/admin-appointments', {
        'userId': value(candidate, 'id'),
        'password': password,
        'reason': _reason.text.trim(),
      });
      if (mounted && _allowed && origin == widget.controller.api.baseUrl) {
        setState(() {
          _notice =
              'Đã bổ nhiệm ${value(candidate, 'displayName')} làm quản trị viên.';
          _error = null;
          _selected = null;
          _reason.clear();
          _candidates.removeWhere((row) => row['id'] == candidate['id']);
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) _password.clear();
      if (mounted) {
        setState(() {
          _busy = false;
          _submitting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _search.dispose();
    _password.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bổ nhiệm quản trị viên')),
    body: SafeArea(
      child: !_allowed
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Chỉ quản trị viên được sử dụng chức năng này.'),
              ),
            )
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const MessageBox(
                    'Chọn tài khoản Người tiêu dùng đã xác minh và đang hoạt động. Bổ nhiệm là thay đổi quyền quản trị; cần xác nhận mật khẩu hiện tại của bạn.',
                  ),
                  if (_error != null) MessageBox(_error!, error: true),
                  if (_notice != null) MessageBox(_notice!),
                  TextField(
                    controller: _search,
                    enabled: !_busy,
                    maxLength: 80,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _load(),
                    decoration: InputDecoration(
                      labelText: 'Tìm người được bổ nhiệm',
                      suffixIcon: IconButton(
                        tooltip: 'Tìm ứng viên',
                        onPressed: _busy || _loading ? null : _load,
                        icon: const Icon(Icons.search),
                      ),
                    ),
                  ),
                  if (_loading) const LinearProgressIndicator(),
                  if (!_loading && _candidates.isEmpty)
                    const Text('Không có tài khoản phù hợp với tìm kiếm.'),
                  for (final candidate in _candidates)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        _selected?['id'] == candidate['id']
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(value(candidate, 'displayName')),
                      subtitle: Text(
                        '${value(candidate, 'email')}\n${value(candidate, 'region')}',
                      ),
                      onTap: _busy
                          ? null
                          : () => setState(() {
                              _selected = candidate;
                              _notice = null;
                            }),
                    ),
                  if (_selected != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Đã chọn: ${value(_selected!, 'displayName')}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _reason,
                      enabled: !_busy,
                      maxLength: 1000,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Lý do bổ nhiệm',
                      ),
                      validator: (value) => requiredText(value, min: 3),
                    ),
                    TextFormField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Mật khẩu quản trị viên hiện tại',
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Nhập mật khẩu hiện tại để xác nhận.'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _appoint,
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                      label: const Text('Bổ nhiệm quản trị viên'),
                    ),
                    if (_submitting) const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
    ),
  );
}
