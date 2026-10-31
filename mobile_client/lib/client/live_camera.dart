import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';

class CameraFrame {
  CameraFrame(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width, height;
}

abstract interface class LiveFrameSource {
  Future<void> start(int viewId);
  Future<CameraFrame> frame();
  Future<void> stop();
}

abstract interface class LiveAiGateway {
  Future<Map<String, dynamic>> open();
  Future<Map<String, dynamic>> infer(
    String id,
    int sequence,
    CameraFrame frame,
    UploadCancellation cancel,
  );
  Future<void> close(String id);
}

class NativeLiveFrameSource implements LiveFrameSource {
  static const channel = MethodChannel('vn.fruitvision/live_camera');
  int? _view;
  @override
  Future<void> start(int viewId) async {
    _view = viewId;
    await channel.invokeMethod<void>('start', {'viewId': viewId});
  }

  @override
  Future<CameraFrame> frame() async {
    final data = await channel.invokeMapMethod<String, dynamic>('frame', {
      'viewId': _view,
    });
    final bytes = data?['bytes'],
        width = data?['width'],
        height = data?['height'];
    if (bytes is! Uint8List ||
        bytes.isEmpty ||
        bytes.length > 1048576 ||
        width is! int ||
        height is! int ||
        width < 1 ||
        height < 1 ||
        width > 960 ||
        height > 960) {
      throw const ApiException('Khung hình camera không hợp lệ.');
    }
    return CameraFrame(bytes, width, height);
  }

  @override
  Future<void> stop() async {
    final view = _view;
    _view = null;
    if (view != null) {
      await channel.invokeMethod<void>('stop', {'viewId': view});
    }
  }
}

class ServerLiveAiGateway implements LiveAiGateway {
  ServerLiveAiGateway(this.api);
  final ApiClient api;
  @override
  Future<Map<String, dynamic>> open() => api.post('/ai/live/sessions', {});
  @override
  Future<Map<String, dynamic>> infer(
    String id,
    int sequence,
    CameraFrame frame,
    UploadCancellation cancel,
  ) => api.sendJpeg(
    '/ai/live/sessions/${Uri.encodeComponent(id)}/frames',
    frame.bytes,
    headers: {'X-Frame-Sequence': '$sequence'},
    cancellation: cancel,
  );
  @override
  Future<void> close(String id) async {
    await api.delete('/ai/live/sessions/${Uri.encodeComponent(id)}');
  }
}

class LiveCameraController extends ChangeNotifier {
  LiveCameraController({required this.source, required this.gateway});
  final LiveFrameSource source;
  final LiveAiGateway gateway;
  bool running = false, starting = false;
  String? error;
  Map<String, dynamic>? result;
  CameraFrame? analyzedFrame;
  int frames = 0;
  double fps = 0;
  int _generation = 0, _sequence = 0, _minimumMs = 167;
  bool _disposed = false;
  String? _id;
  Timer? _timer;
  UploadCancellation? _cancel;
  final _elapsed = Stopwatch();
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(int viewId) async {
    if (running || starting || _disposed) return;
    starting = true;
    error = null;
    result = null;
    analyzedFrame = null;
    frames = 0;
    fps = 0;
    final ticket = ++_generation;
    _emit();
    try {
      await source.start(viewId);
      if (ticket != _generation) return;
      final session = await gateway.open();
      final id = session['id'];
      if (id is! String || id.isEmpty) {
        throw const ApiException('Không khởi tạo được phiên camera.');
      }
      if (ticket != _generation) {
        await gateway.close(id);
        return;
      }
      _id = id;
      _sequence = (session['nextSequence'] as int?) ?? 1;
      if (_sequence < 1) throw const ApiException('Phiên camera không hợp lệ.');
      _minimumMs = ((session['minFrameIntervalMs'] as num?)?.toInt() ?? 150)
          .clamp(167, 5000);
      running = true;
      _elapsed
        ..reset()
        ..start();
      // CameraX binds before the first visible camera frame is available.
      _timer = Timer(const Duration(milliseconds: 500), () => _tick(ticket));
    } catch (e) {
      if (ticket == _generation) {
        error = _message(e);
        await stop();
      }
    } finally {
      starting = false;
      _emit();
    }
  }

  Future<void> _tick(int ticket) async {
    if (ticket != _generation || !running || _disposed) return;
    final tick = Stopwatch()..start();
    final cancellation = UploadCancellation();
    _cancel = cancellation;
    try {
      final frame = await source.frame();
      if (ticket != _generation) return;
      final sequence = _sequence++;
      final response = await gateway.infer(_id!, sequence, frame, cancellation);
      if (ticket != _generation || !running) return;
      if (response['sessionId'] != _id ||
          response['sequence'] != sequence ||
          response['imageWidth'] != frame.width ||
          response['imageHeight'] != frame.height ||
          response['objects'] is! List ||
          response['visibleCount'] is! int) {
        throw const ApiException(
          'Kết quả camera không khớp với khung hình đã gửi.',
        );
      }
      result = response;
      analyzedFrame = frame;
      frames++;
      fps = frames * 1000 / _elapsed.elapsedMilliseconds.clamp(1, 1 << 53);
      _emit();
      final remaining = _minimumMs - tick.elapsedMilliseconds;
      _timer = Timer(
        Duration(milliseconds: remaining > 0 ? remaining : 0),
        () => _tick(ticket),
      );
    } catch (e) {
      if (ticket == _generation && running) {
        error = _message(e);
        await stop();
      }
    } finally {
      if (identical(_cancel, cancellation)) _cancel = null;
    }
  }

  static String _message(Object e) => e is ApiException
      ? e.message
      : e is PlatformException
      ? (e.message ?? 'Không mở được camera.')
      : 'Camera chưa hoàn tất xử lý. Hãy kiểm tra kết nối và thử lại.';
  Future<void> stop() async {
    ++_generation;
    running = false;
    _timer?.cancel();
    _timer = null;
    _cancel?.cancel();
    _cancel = null;
    _elapsed.stop();
    result = null;
    analyzedFrame = null;
    final id = _id;
    _id = null;
    _emit();
    try {
      await source.stop();
    } on PlatformException {
      /* View can already be disposed. */
    }
    if (id != null) {
      try {
        await gateway.close(id);
      } on ApiException {
        /* Server idle expiry also releases it. */
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
