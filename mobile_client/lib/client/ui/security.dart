import 'package:flutter/material.dart';

import '../biometrics.dart';
import '../session.dart';
import 'components.dart';
import 'face_photo.dart';
import 'secret_scope.dart';
import 'secret_chat.dart';

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  List<Json> _devices = [];
  BiometricInfo? _local;
  Json? _face;
  String? _error;
  bool _loading = true, _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = widget.controller.user;
    if (user == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await widget.controller.api.get(
        '/auth/biometric/devices',
      );
      final local = await widget.controller.biometrics.info(
        widget.controller.api.baseUrl,
        user.email.trim().toLowerCase(),
      );
      final face = await widget.controller.api.get('/auth/face/status');
      if (mounted) {
        setState(() {
          _devices = rows(devices);
          _local = local;
          _face = face;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enroll() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.controller.enrollBiometric();
    if (mounted) {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(Json device) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thu hồi khóa thiết bị?'),
        content: const Text(
          'Thiết bị này sẽ cần mật khẩu và mã xác thực để đăng nhập hoặc đăng ký lại.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Thu hồi'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.api.delete(
        '/auth/biometric/devices/${Uri.encodeComponent(value(device, 'id'))}',
      );
      if (device['deviceId'] == _local?.deviceId) {
        await widget.controller.biometrics.deleteKey(
          widget.controller.api.baseUrl,
          widget.controller.user!.email.trim().toLowerCase(),
        );
      }
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeFace() async {
    if (_busy) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa mẫu đối chiếu khuôn mặt?'),
        content: const Text(
          'Bạn vẫn đăng nhập bằng mật khẩu và mã xác thực. Muốn dùng lại ảnh, bạn cần đăng ký mẫu mới.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xóa mẫu'),
          ),
        ],
      ),
    );
    if (!mounted || remove != true) return;
    setState(() => _busy = true);
    try {
      await widget.controller.api.delete('/auth/face');
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller, user = c.user;
      return Scaffold(
        appBar: AppBar(title: const Text('Bảo mật tài khoản')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SectionTitle('Email và xác thực'),
              Text(
                'Email: ${user?.emailConfirmed == true ? 'Đã xác minh' : 'Chưa xác minh'}',
              ),
              const Text('Đăng nhập chính: mật khẩu và mã gửi qua email.'),
              if (user?.twoFactorEnabled == true)
                const Text(
                  'Tài khoản cũ đã bật ứng dụng xác thực: tiếp tục dùng mã đã đăng ký.',
                ),
              const SizedBox(height: 20),
              if (c.user?.canSell == true &&
                  SecretScope.maybeOf(context) != null) ...[
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SecretDevicesPage(
                        messaging: SecretScope.maybeOf(context)!,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.enhanced_encryption_outlined),
                  label: const Text('Khóa nhắn tin bí mật'),
                ),
                const SizedBox(height: 16),
              ],
              const SectionTitle(
                'Khóa sinh trắc học trên thiết bị',
                subtitle: 'Android xác thực sinh trắc học mạnh để dùng khóa riêng trong Keystore. Máy chủ kiểm tra chữ ký thử thách một lần. Với khóa này, mẫu sinh trắc học của Android không rời thiết bị.',
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) MessageBox(_error!, error: true),
              if (c.error != null) MessageBox(c.error!, error: true),
              if (c.notice != null) MessageBox(c.notice!),
              if (!_loading && _local?.available != true)
                const MessageBox(
                  'Thiết bị chưa có sinh trắc học mạnh sẵn sàng, hoặc nền tảng không hỗ trợ. Bạn vẫn đăng nhập bằng mật khẩu và mã xác thực.',
                ),
              if (_local?.available == true) ...[
                Text(
                  _local!.enrolled
                      ? 'Thiết bị đang có khóa cục bộ cho email và máy chủ này.'
                      : 'Chưa có khóa cục bộ cho email và máy chủ này.',
                ),
                if (!c.canEnrollBiometric)
                  const MessageBox(
                    'Để đăng ký, đăng nhập lại bằng mật khẩu và mã email trong 15 phút. Máy chủ sẽ kiểm tra lại điều kiện này.',
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: !c.canEnrollBiometric || c.busy || _busy
                      ? null
                      : _enroll,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Đăng ký khóa cho thiết bị này'),
                ),
              ],
              const SizedBox(height: 20),
              const SectionTitle('Thiết bị đã đăng ký'),
              if (!_loading &&
                  _devices.where((d) => d['revokedAt'] == null).isEmpty)
                const Text('Chưa có thiết bị đang được cấp quyền.'),
              ..._devices
                  .where((d) => d['revokedAt'] == null)
                  .map(
                    (device) => DataCard(
                      children: [
                        Text(
                          value(device, 'label'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text('Đăng ký ${displayTime(device['createdAt'])}'),
                        if (device['lastUsedAt'] != null)
                          Text(
                            'Dùng gần nhất ${displayTime(device['lastUsedAt'])}',
                          ),
                        OutlinedButton(
                          onPressed: _busy || c.busy
                              ? null
                              : () => _revoke(device),
                          child: const Text('Thu hồi thiết bị'),
                        ),
                      ],
                    ),
                  ),
              TextButton.icon(
                onPressed: _loading || _busy ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Cập nhật trạng thái bảo mật'),
              ),
              const SizedBox(height: 20),
              const SectionTitle('Đối chiếu ảnh khuôn mặt + mã email'),
              const MessageBox(
                'Ảnh khuôn mặt được đối chiếu 2D trên máy chủ khi bạn chủ động gửi. Chưa có kiểm tra người thật (liveness), không phải Face ID của Android. Đăng nhập vẫn cần mã email.',
              ),
              if (_face != null)
                Text(
                  _face!['enrolled'] == true
                      ? 'Đã đăng ký mẫu đối chiếu.'
                      : 'Chưa đăng ký mẫu đối chiếu.',
                ),
              if (_face?['ready'] != true)
                const Text('Dịch vụ đối chiếu ảnh chưa sẵn sàng.'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed:
                    _busy ||
                        c.busy ||
                        _face?['ready'] != true ||
                        !c.canEnrollBiometric
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                FacePhotoPage(controller: c, enroll: true),
                          ),
                        );
                        if (mounted) _load();
                      },
                icon: const Icon(Icons.face_outlined),
                label: const Text('Đăng ký mẫu ảnh khuôn mặt'),
              ),
              if (!c.canEnrollBiometric)
                const Text(
                  'Đăng nhập lại bằng mật khẩu và mã xác thực trong 15 phút để đăng ký hoặc xóa mẫu.',
                ),
              if (_face?['enrolled'] == true)
                OutlinedButton(
                  onPressed: _busy || c.busy || !c.canEnrollBiometric
                      ? null
                      : _removeFace,
                  child: const Text('Xóa mẫu đối chiếu khuôn mặt'),
                ),
            ],
          ),
        ),
      );
    },
  );
}
