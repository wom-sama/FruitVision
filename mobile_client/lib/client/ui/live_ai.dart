import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../live_camera.dart';
import '../session.dart';
import 'components.dart';

class LiveAiPage extends StatefulWidget {
  const LiveAiPage({super.key, required this.session, this.controller});
  final SessionController session;

  /// Injected controllers remain caller-owned; leaving this page still stops capture.
  final LiveCameraController? controller;
  @override
  State<LiveAiPage> createState() => _LiveAiPageState();
}

class _LiveAiPageState extends State<LiveAiPage> with WidgetsBindingObserver {
  late final LiveCameraController camera =
      widget.controller ??
      LiveCameraController(
        source: NativeLiveFrameSource(),
        gateway: ServerLiveAiGateway(widget.session.api),
      );
  int? viewId;
  bool _resumed = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (widget.session.user?.canSell != true) {
      unawaited(camera.stop());
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive && camera.starting) {
      return;
    }
    if (!_resumed && (state != AppLifecycleState.inactive || camera.running)) {
      unawaited(camera.stop());
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) {
      camera.dispose();
    } else {
      unawaited(camera.stop());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Camera nhận diện xoài')),
    bottomNavigationBar: widget.session.user?.canSell != true
        ? null
        : AnimatedBuilder(
            animation: camera,
            builder: (context, _) => SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                ),
                icon: Icon(
                  camera.running
                      ? Icons.stop_circle_outlined
                      : Icons.videocam_outlined,
                ),
                label: Text(
                  camera.starting
                      ? 'Đang mở camera…'
                      : camera.running
                      ? 'Dừng nhận diện'
                      : 'Bắt đầu nhận diện',
                ),
                onPressed: camera.starting
                    ? null
                    : camera.running
                    ? () => camera.stop()
                    : viewId != null && _resumed
                    ? () => camera.start(viewId!)
                    : null,
              ),
            ),
          ),
    body: widget.session.user?.canSell != true
        ? const Padding(
            padding: EdgeInsets.all(20),
            child: MessageBox(
              'Chỉ Nhà sản xuất và Thương lái đã được duyệt sử dụng AI.',
            ),
          )
        : AnimatedBuilder(
            animation: camera,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Camera trên điện thoại · AI xử lý trên máy tính',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  key: const ValueKey('live-camera-preview'),
                  height: MediaQuery.sizeOf(context).height * .45,
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: AspectRatio(
                        aspectRatio: 3 / 4,
                        child: defaultTargetPlatform == TargetPlatform.android
                            ? AndroidView(
                                viewType: 'vn.fruitvision/live_camera/preview',
                                onPlatformViewCreated: (id) =>
                                    setState(() => viewId = id),
                              )
                            : const ColoredBox(
                                color: Colors.black,
                                child: Center(
                                  child: Text(
                                    'Camera trực tiếp cần Android.',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (camera.error != null) ...[
                  const SizedBox(height: 8),
                  MessageBox(camera.error!, error: true),
                ],
                const SizedBox(height: 8),
                Text(
                  'Đã xử lý ${camera.frames} khung · ${camera.fps.toStringAsFixed(2)} khung AI/giây',
                ),
                const Text(
                  'Tốc độ thực tế phụ thuộc mạng và máy chủ. Chỉ gửi khung mới khi máy chủ đã trả lời; không lưu từng khung vào lịch sử.',
                ),
                if (camera.result != null && camera.analyzedFrame != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    '${camera.result!['visibleCount']} quả xoài được dự đoán trong khung gần nhất',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  AspectRatio(
                    aspectRatio:
                        camera.analyzedFrame!.width /
                        camera.analyzedFrame!.height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(
                          camera.analyzedFrame!.bytes,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                        CustomPaint(
                          painter: _MangoBoxes(
                            camera.result!['objects'] as List,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Khung đã phân tích · xử lý ${(camera.result!['processingMs'] as num?)?.toStringAsFixed(0) ?? '—'} ms',
                  ),
                ],
                const SizedBox(height: 12),
                const MessageBox(
                  'Số quả là số nhìn thấy trong một khung, không phải tổng quả duy nhất đã đi qua. Xanh/chín là dự đoán từ hình ảnh; không kết luận an toàn thực phẩm.',
                ),
              ],
            ),
          ),
  );
}

class _MangoBoxes extends CustomPainter {
  _MangoBoxes(this.objects);
  final List objects;
  @override
  void paint(Canvas canvas, Size size) {
    for (final row in objects.whereType<Map>()) {
      final b = row['box'];
      if (b is! List ||
          b.length != 4 ||
          b.any((x) => x is! num || !x.isFinite)) {
        continue;
      }
      final v = b.cast<num>().map((x) => x.toDouble().clamp(0.0, 1.0)).toList();
      final rect = Rect.fromLTRB(
        v[0] * size.width,
        v[1] * size.height,
        v[2] * size.width,
        v[3] * size.height,
      );
      if (rect.width <= 0 || rect.height <= 0) continue;
      final color = row['stageCode'] == 0
          ? const Color(0xFF9AFFC2)
          : const Color(0xFFFFE185);
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = color,
      );
      final text = TextPainter(
        text: TextSpan(
          text: ' ${row['stageLabel'] ?? 'Chưa xác định'} ',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            backgroundColor: Color(0xDD143B31),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width);
      text.paint(
        canvas,
        Offset(
          rect.left.clamp(0, size.width - text.width),
          (rect.top - text.height).clamp(0, size.height - text.height),
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_MangoBoxes old) => old.objects != objects;
}
