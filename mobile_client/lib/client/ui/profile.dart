import 'package:flutter/material.dart';

import '../session.dart';
import '../models.dart';
import '../inbox.dart';
import 'components.dart';
import 'role_applications.dart';

String profileRole(Object? role) =>
    UserRole.values.where((value) => value.wire == role).firstOrNull?.label ??
    'Thành viên';

class OwnProfilePage extends StatefulWidget {
  const OwnProfilePage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<OwnProfilePage> createState() => _OwnProfilePageState();
}

class _OwnProfilePageState extends State<OwnProfilePage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _bio = TextEditingController(),
      _phone = TextEditingController();
  Json? _profile;
  String _gender = 'Unknown';
  bool _showGender = false, _showPhone = false, _showRegion = false;
  bool _loading = true, _saving = false;
  String? _error, _notice;
  int _generation = 0;
  late final _identity =
      '${widget.controller.api.baseUrl}|${widget.controller.user?.id}';
  bool get _valid =>
      mounted &&
      widget.controller.user != null &&
      !widget.controller.endingSession &&
      _identity ==
          '${widget.controller.api.baseUrl}|${widget.controller.user?.id}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_saving || !_valid) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await widget.controller.api.get('/profile');
      if (!_valid || generation != _generation) return;
      setState(() {
        _profile = profile;
        _name.text = value(profile, 'displayName');
        _bio.text = value(profile, 'bio');
        _phone.text = value(profile, 'phone');
        _gender =
            const [
              'Unknown',
              'Male',
              'Female',
              'Other',
            ].contains(profile['gender'])
            ? profile['gender'] as String
            : 'Unknown';
        _showGender = profile['showGender'] == true;
        _showPhone = profile['showPhone'] == true;
        _showRegion = profile['showRegion'] == true;
      });
    } catch (error) {
      if (_valid && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (_valid && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _loading || !_valid || !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      final profile = await widget.controller.api.put('/profile', {
        'displayName': _name.text.trim(),
        'bio': _bio.text.trim(),
        'phone': _phone.text.trim(),
        'gender': _gender,
        'showGender': _showGender,
        'showPhone': _showPhone,
        'showRegion': _showRegion,
      });
      if (!mounted || !_valid) return;
      setState(() {
        _profile = profile;
        _notice = 'Đã lưu hồ sơ và quyền riêng tư.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã lưu hồ sơ và quyền riêng tư.')),
      );
      await widget.controller.refreshProfile();
    } catch (error) {
      if (_valid) setState(() => _error = errorText(error));
    } finally {
      if (_valid) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _name.dispose();
    _bio.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Hồ sơ & quyền riêng tư')),
    body: SafeArea(
      child: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading || _saving) const LinearProgressIndicator(),
            if (_error != null)
              MessageBox(
                _error!,
                error: true,
                child: TextButton(
                  onPressed: _loading || _saving ? null : _load,
                  child: const Text('Tải lại hồ sơ'),
                ),
              ),
            if (_notice != null) MessageBox(_notice!),
            if (_profile != null) ...[
              const SectionTitle(
                'Thông tin cá nhân',
                subtitle: 'Bạn tự quản lý tên hiển thị, giới thiệu và các mục công khai bên dưới. Email chỉ hiển thị cho chính bạn.',
              ),
              Text('Email: ${value(_profile!, 'email')}'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                enabled: !_saving,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Tên hiển thị'),
                validator: (value) => requiredText(value),
              ),
              TextFormField(
                controller: _bio,
                enabled: !_saving,
                maxLength: 500,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Giới thiệu (công khai, tùy chọn)',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _gender,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Giới tính'),
                items: const [
                  DropdownMenuItem(
                    value: 'Unknown',
                    child: Text('Chưa cung cấp'),
                  ),
                  DropdownMenuItem(value: 'Male', child: Text('Nam')),
                  DropdownMenuItem(value: 'Female', child: Text('Nữ')),
                  DropdownMenuItem(value: 'Other', child: Text('Khác')),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _gender = value!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                enabled: !_saving,
                maxLength: 30,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Số điện thoại cá nhân (tùy chọn)',
                ),
              ),
              const SizedBox(height: 12),
              const SectionTitle('Quyền riêng tư'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Công khai giới tính'),
                value: _showGender,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _showGender = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Công khai số điện thoại'),
                value: _showPhone,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _showPhone = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Công khai khu vực'),
                subtitle: const Text(
                  'Khu vực lấy từ hồ sơ địa lý đã xác nhận; không sửa bằng văn bản tự do tại đây.',
                ),
                value: _showRegion,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _showRegion = value),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Lưu hồ sơ'),
              ),
              const SizedBox(height: 20),
              const SectionTitle(
                'Thông tin vai trò · Chỉ xem',
                subtitle: 'Vai trò, chứng từ và thông tin pháp lý do quy trình xét duyệt quản lý; không thay đổi bằng phần sửa hồ sơ cá nhân.',
              ),
              Text(profileRole(_profile!['role'])),
              if (value(_profile!, 'region').isNotEmpty)
                Text('Khu vực: ${value(_profile!, 'region')}'),
              if (_profile!['roleDetails'] is Map)
                _RoleDetails(
                  data: Map<String, dynamic>.from(_profile!['roleDetails']),
                ),
              if (widget.controller.user?.role == UserRole.consumer)
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          RoleApplicationsPage(controller: widget.controller),
                    ),
                  ),
                  icon: const Icon(Icons.assignment_ind_outlined),
                  label: const Text('Hồ sơ nâng vai trò'),
                ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      BlockedProfilesPage(controller: widget.controller),
                ),
              ),
              icon: const Icon(Icons.block_outlined),
              label: const Text('Danh sách đã chặn'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RoleDetails extends StatelessWidget {
  const _RoleDetails({required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (value(data, 'establishmentName').isNotEmpty)
        Text('Cơ sở đã xét duyệt: ${value(data, 'establishmentName')}'),
    ],
  );
}

class UserProfilePage extends StatefulWidget {
  const UserProfilePage({
    super.key,
    required this.controller,
    required this.userId,
    this.inbox,
  });
  final SessionController controller;
  final String userId;
  final InboxController? inbox;
  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  Json? _profile;
  String? _error;
  bool _loading = true, _busy = false;
  int _generation = 0;
  late final _identity =
      '${widget.controller.api.baseUrl}|${widget.controller.user?.id}';
  bool get _valid =>
      mounted &&
      widget.controller.user != null &&
      !widget.controller.endingSession &&
      _identity ==
          '${widget.controller.api.baseUrl}|${widget.controller.user?.id}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await widget.controller.api.get(
        '/profiles/${Uri.encodeComponent(widget.userId)}',
      );
      if (_valid && generation == _generation) {
        setState(() => _profile = profile);
      }
    } catch (error) {
      if (_valid && generation == _generation) {
        setState(() {
          _profile = null;
          _error = error is ApiException && error.status == 404
              ? 'Không thể xem hồ sơ này.'
              : errorText(error);
        });
      }
    } finally {
      if (_valid && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _block() async {
    if (_busy || !_valid || widget.userId == widget.controller.user?.id) return;
    setState(() => _busy = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Chặn ${value(_profile!, 'displayName')}?'),
          content: const Text(
            'Chặn tin nhắn trực tiếp mới từ tài khoản này. Lịch sử đã có và trao đổi nhóm không bị xóa. Bạn có thể bỏ chặn trong danh sách đã chặn của mình.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xác nhận chặn'),
            ),
          ],
        ),
      );
      if (!_valid || confirmed != true) return;
      await widget.controller.api.put(
        '/profiles/${Uri.encodeComponent(widget.userId)}/block',
        {},
      );
      if (!mounted || !_valid) return;
      await widget.inbox?.refresh();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (_valid) setState(() => _error = errorText(error));
    } finally {
      if (_valid) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Hồ sơ người dùng')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            MessageBox(
              _error!,
              error: true,
              child: TextButton(
                onPressed: _busy ? null : _load,
                child: const Text('Thử lại'),
              ),
            ),
          if (_profile != null) ...[
            const CircleAvatar(
              radius: 32,
              child: Icon(Icons.person_outline, size: 36),
            ),
            const SizedBox(height: 16),
            SectionTitle(
              value(_profile!, 'displayName'),
              subtitle: profileRole(_profile!['role']),
            ),
            if (value(_profile!, 'bio').isNotEmpty)
              Text(value(_profile!, 'bio')),
            if (value(_profile!, 'gender').isNotEmpty &&
                _profile!['gender'] != 'Unknown')
              Text(
                'Giới tính: ${switch (_profile!['gender']) {
                  'Male' => 'Nam',
                  'Female' => 'Nữ',
                  'Other' => 'Khác',
                  _ => 'Chưa cung cấp',
                }}',
              ),
            if (value(_profile!, 'phone').isNotEmpty)
              Text('Điện thoại: ${value(_profile!, 'phone')}'),
            if (value(_profile!, 'region').isNotEmpty)
              Text('Khu vực: ${value(_profile!, 'region')}'),
            if (_profile!['roleDetails'] is Map &&
                value(
                  Map<String, dynamic>.from(_profile!['roleDetails']),
                  'establishmentName',
                ).trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              const SectionTitle('Thông tin vai trò đã xét duyệt'),
              _RoleDetails(
                data: Map<String, dynamic>.from(_profile!['roleDetails']),
              ),
            ],
            const SizedBox(height: 24),
            if (widget.userId != widget.controller.user?.id)
              OutlinedButton.icon(
                onPressed: _busy ? null : _block,
                icon: const Icon(Icons.block),
                label: const Text('Chặn người dùng'),
              ),
          ],
        ],
      ),
    ),
  );
}

class BlockedProfilesPage extends StatefulWidget {
  const BlockedProfilesPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<BlockedProfilesPage> createState() => _BlockedProfilesPageState();
}

class _BlockedProfilesPageState extends State<BlockedProfilesPage> {
  List<Json> _profiles = [];
  String? _error, _busy;
  bool _loading = true;
  int _generation = 0;
  late final _identity =
      '${widget.controller.api.baseUrl}|${widget.controller.user?.id}';
  bool get _valid =>
      mounted &&
      widget.controller.user != null &&
      !widget.controller.endingSession &&
      _identity ==
          '${widget.controller.api.baseUrl}|${widget.controller.user?.id}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation,
        origin = widget.controller.api.baseUrl,
        user = widget.controller.user?.id;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.controller.api.get('/profile/blocked');
      if (mounted &&
          generation == _generation &&
          origin == widget.controller.api.baseUrl &&
          user == widget.controller.user?.id) {
        setState(() => _profiles = rows(response));
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

  Future<void> _unblock(Json profile) async {
    if (_busy != null || !_valid) return;
    final id = value(profile, 'id');
    setState(() => _busy = id);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Bỏ chặn ${value(profile, 'displayName')}?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Bỏ chặn'),
            ),
          ],
        ),
      );
      if (!_valid || confirmed != true) return;
      await widget.controller.api.delete(
        '/profiles/${Uri.encodeComponent(id)}/block',
      );
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Danh sách đã chặn')),
    body: SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) MessageBox(_error!, error: true),
            if (!_loading && _profiles.isEmpty)
              const Text('Bạn chưa chặn người dùng nào.'),
            for (final profile in _profiles)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(value(profile, 'displayName')),
                subtitle: Text(profileRole(profile['role'])),
                trailing: TextButton(
                  onPressed: _busy != null ? null : () => _unblock(profile),
                  child: const Text('Bỏ chặn'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
