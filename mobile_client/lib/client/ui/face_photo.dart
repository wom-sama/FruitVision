import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../media.dart';
import '../session.dart';
import 'components.dart';

class FacePhotoPage extends StatefulWidget {
  const FacePhotoPage({
    super.key,
    required this.controller,
    required this.enroll,
    this.email = '',
    this.picker,
  });
  final SessionController controller;
  final bool enroll;
  final String email;
  final NativeMediaPicker? picker;
  @override
  State<FacePhotoPage> createState() => _FacePhotoPageState();
}

class _FacePhotoPageState extends State<FacePhotoPage> {
  late final _picker = widget.picker ?? NativeMediaPicker();
  PickedMedia? _picked;
  Uint8List? _preview;
  bool _loading = true, _ready = false, _choosing = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.controller.api.get(
        widget.enroll ? '/auth/face/status' : '/auth/methods',
      );
      if (mounted) {
        setState(
          () => _ready = widget.enroll
              ? result['ready'] == true
              : result['faceReady'] == true && result['emailOtpReady'] == true,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose(String method) async {
    if (_choosing || widget.controller.busy) return;
    setState(() {
      _choosing = true;
      _error = null;
    });
    PickedMedia? photo;
    try {
      photo = await _picker.pick(method);
      if (photo == null) return;
      final bytes = await readFaceImage(photo);
      if (!mounted) {
        await _picker.delete(photo);
        return;
      }
      final previous = _picked;
      setState(() {
        _picked = photo;
        _preview = bytes;
      });
      if (previous != null) await _picker.delete(previous);
    } catch (e) {
      if (photo != null && photo != _picked) await _picker.delete(photo);
      if (mounted) {
        setState(
          () => _error = e is FormatException
              ? e.message
              : e is PlatformException && e.code == 'FACE_SCAN'
              ? safeErrorMessage(e.message ?? 'Không quét được khuôn mặt. Kiểm tra quyền camera và thử lại.')
              : 'Không quét được khuôn mặt. Kiểm tra quyền camera và thử lại.',
        );
      }
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _clear() async {
    final old = _picked;
    _preview = null;
    if (mounted) {
      setState(() => _picked = null);
    } else {
      _picked = null;
    }
    if (old != null) await _picker.delete(old);
  }

  Future<void> _submit() async {
    final photo = _picked;
    if (photo == null || widget.controller.busy) return;
    final ok = widget.enroll
        ? await widget.controller.enrollFace(photo)
        : await widget.controller.loginFace(widget.email, photo);
    if (!mounted) return;
    if (ok) {
      await _clear();
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  void dispose() {
    final photo = _picked;
    _picked = null;
    if (photo != null) unawaited(_picker.delete(photo));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller,
          canSend =
              _ready &&
              !_choosing &&
              !c.busy &&
              (!widget.enroll || c.canEnrollBiometric);
      return PopScope(
        canPop: !c.busy,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              widget.enroll
                  ? 'Đăng ký ảnh khuôn mặt'
                  : 'Đối chiếu ảnh + mã email',
            ),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const MessageBox(
                  'Đây là đối chiếu ảnh 2D trên máy chủ, chưa có kiểm tra người thật (liveness), không phải Face ID của hệ điều hành. Đăng nhập phải tiếp tục bằng mã email; không dùng ảnh để bỏ qua mã xác thực.',
                ),
                const SizedBox(height: 12),
                Text(
                  widget.enroll
                      ? 'Chỉ gửi ảnh khi bạn bấm đăng ký. Cần phiên đăng nhập mới bằng mật khẩu và mã xác thực trong 15 phút.'
                      : 'Email: ${widget.email.trim()}',
                ),
                const SizedBox(height: 12),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) MessageBox(_error!, error: true),
                if (c.error != null) MessageBox(c.error!, error: true),
                if (!_loading && !_ready)
                  const MessageBox(
                    'Dịch vụ đối chiếu ảnh hoặc email xác thực chưa sẵn sàng. Hãy dùng đăng nhập bằng mật khẩu và mã xác thực.',
                  ),
                if (widget.enroll && !c.canEnrollBiometric)
                  const MessageBox(
                    'Đăng nhập lại bằng mật khẩu và mã xác thực trước khi đăng ký mẫu ảnh.',
                  ),
                if (_picked case final photo?) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.memory(
                      _preview!,
                      height: 180,
                      fit: BoxFit.contain,
                      cacheWidth: 512,
                      errorBuilder: (_, _, _) => const SizedBox(
                        height: 100,
                        child: Center(
                          child: Text('Không hiển thị được ảnh đã chọn.'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(photo.name),
                  const Text('Ảnh tối đa 2 MiB; chưa gửi lên máy chủ.'),
                  TextButton.icon(
                    onPressed: c.busy ? null : _clear,
                    icon: const Icon(Icons.close),
                    label: const Text('Bỏ ảnh đã chọn'),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Đặt khuôn mặt trong khung hướng dẫn. Camera trong ứng dụng tự lấy ảnh; bạn xem trước rồi chủ động gửi để đối chiếu và nhận mã email.',
                ),
                OutlinedButton.icon(
                  onPressed: canSend ? () => _choose('captureFace') : null,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Quét khuôn mặt'),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: canSend && _picked != null ? _submit : null,
                  icon: const Icon(Icons.send_outlined),
                  label: Text(
                    c.busy
                        ? 'Đang xử lý…'
                        : widget.enroll
                        ? 'Gửi ảnh để đăng ký mẫu'
                        : 'Gửi ảnh và nhận mã email',
                  ),
                ),
                TextButton.icon(
                  onPressed: _loading || c.busy ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Kiểm tra dịch vụ'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
