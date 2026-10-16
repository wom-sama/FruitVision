import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/live_camera.dart';
import 'package:mango_offline/live_camera_page.dart';

import 'live_camera_test.dart' show FakeCameraBackend, frameFixture;

class FakePreview extends StatefulWidget {
  const FakePreview(this.onCreated, {super.key});
  final ValueChanged<int> onCreated;

  @override
  State<FakePreview> createState() => _FakePreviewState();
}

class _FakePreviewState extends State<FakePreview> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onCreated(7);
    });
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

void main() {
  for (final size in const [Size(390, 844), Size(844, 390)]) {
    // Removing preview constraints would create an unusable native view or an overflow.
    testWidgets('live preview has positive bounds at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeCameraBackend();
      final controller = LiveCameraController(backend: backend);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveCameraPage(
            controller: controller,
            previewBuilder: (_, onCreated) => FakePreview(onCreated),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bounds = tester.getSize(
        find.byKey(const ValueKey('live-camera-preview')),
      );
      expect(bounds.width, greaterThan(0));
      expect(bounds.height, greaterThan(0));
      expect(tester.takeException(), isNull);
      expect(controller.phase, LiveCameraPhase.running);
      backend.stream.add(frameFixture());
      await tester.pump();
      expect(find.text('Lớp dự đoán: 1'), findsOneWidget);
      expect(find.textContaining('80.0%'), findsWidgets);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
      expect(backend.calls, ['start:7:back:30', 'stop']);
      await tester.runAsync(backend.close);
    });
  }

  // Equating analysis FPS or overlay timing with sensor/display performance would mislead users.
  testWidgets('performance details explain the measured boundaries', (
    tester,
  ) async {
    final backend = FakeCameraBackend();
    final controller = LiveCameraController(backend: backend);
    await tester.pumpWidget(
      MaterialApp(
        home: LiveCameraPage(
          controller: controller,
          previewBuilder: (_, onCreated) => FakePreview(onCreated),
        ),
      ),
    );
    await tester.pumpAndSettle();
    backend.stream.add(frameFixture());
    await tester.pump();
    await tester.ensureVisible(find.text('Hiệu năng phiên camera'));
    await tester.tap(find.text('Hiệu năng phiên camera'));
    await tester.pumpAndSettle();
    expect(find.textContaining('không phải FPS xem trước'), findsOneWidget);
    expect(find.textContaining('photon'), findsOneWidget);
    expect(find.textContaining('53.0 ms'), findsOneWidget);
    expect(find.textContaining('101.0 MB'), findsOneWidget);
    expect(find.text('Khung analyzer nhận'), findsOneWidget);
    expect(find.text('Đã gửi kết quả'), findsNothing);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await backend.close();
    });
  });

  // A permission error without an enabled restart control would force users to leave the page.
  testWidgets('camera page exposes restart after a failure', (tester) async {
    late FakeCameraBackend backend;
    late LiveCameraController controller;
    await tester.runAsync(() async {
      backend = FakeCameraBackend()
        ..startError = StateError('Cannot open camera');
      controller = LiveCameraController(backend: backend)..attachPreview(7);
      await controller.start();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LiveCameraPage(
          controller: controller,
          previewBuilder: (_, onCreated) =>
              const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Cannot open camera'), findsOneWidget);
    final restart = find.widgetWithText(FilledButton, 'Thử lại');
    expect(tester.widget<FilledButton>(restart).onPressed, isNotNull);
    backend.startError = null;
    await tester.ensureVisible(restart);
    await tester.runAsync(() async {
      await tester.tap(restart);
      await tester.pump();
      await controller.settled;
    });
    await tester.pumpAndSettle();
    expect(controller.phase, LiveCameraPhase.running);
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await controller.settled;
    });
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.phase, LiveCameraPhase.idle);
    expect(find.text('Bắt đầu camera'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await backend.close();
    });
  });

  // Popping before native drain would enable home media actions while camera inference still owns the model.
  testWidgets('back waits for camera shutdown before returning home', (
    tester,
  ) async {
    final backend = FakeCameraBackend();
    final controller = LiveCameraController(backend: backend);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LiveCameraPage(
                    controller: controller,
                    previewBuilder: (_, onCreated) => FakePreview(onCreated),
                  ),
                ),
              ),
              child: const Text('Open camera'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open camera'));
    await tester.pumpAndSettle();
    backend.pendingStop = Completer<void>();
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final stillOnCamera = find.byType(LiveCameraPage).evaluate().isNotEmpty;
    await tester.runAsync(() async {
      backend.pendingStop!.complete();
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(stillOnCamera, isTrue);
    expect(find.byType(LiveCameraPage), findsNothing);
    expect(find.text('Open camera'), findsOneWidget);
    await tester.runAsync(backend.close);
  });
}
