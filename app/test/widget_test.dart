import 'package:flutter/material.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/inference.dart';
import 'package:mango_offline/main.dart';

const _channel = MethodChannel('vn.mangodemo/inference');
const _pickerChannel = MethodChannel('plugins.flutter.io/image_picker');

Map<String, Object?> _result(String status) => {
  'status': status,
  'probabilities': [0.01, 0.02, 0.02, 0.05, 0.90],
  'classId': 4,
  'box': null,
  'previewPath': '/sample.jpg',
  'elapsedMs': 40.0,
  'modelMs': 25.0,
  'preprocessMs': 12.0,
  'nativePssMb': 88.0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') {
            return {
              'modelName': 'MobileNetV3-Small',
              'modelBytes': 4000000,
              'threads': 2,
              'abi': 'arm64-v8a',
              'offline': true,
              'samplePath': '/sample.jpg',
              'metrics': {'nativePssMb': 78.0},
            };
          }
          if (call.method == 'analyzeImage') return _result('NO_MANGO');
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  // Enabling live camera during image inference would compete for the native model.
  testWidgets('live camera action follows the media controller busy guard', (
    tester,
  ) async {
    final pending = Completer<Map<String, Object?>>();
    final controller = MangoController();
    addTearDown(controller.dispose);
    await controller.prepare();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => pending.future);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    final live = find.widgetWithText(OutlinedButton, 'Camera trực tiếp');
    expect(live, findsOneWidget);
    expect(tester.widget<OutlinedButton>(live).onPressed, isNotNull);
    final analysis = controller.analyzeImage('/photo.jpg');
    await tester.pump();
    expect(tester.widget<OutlinedButton>(live).onPressed, isNull);
    pending.complete(_result('NO_MANGO'));
    await analysis;
    await tester.pump();
    expect(tester.widget<OutlinedButton>(live).onPressed, isNotNull);
  });

  // Catches a missing sample action or treating NO_MANGO as class 4.
  testWidgets('sample analysis reports no mango without a winning class', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Ảnh mẫu'), findsOneWidget);
    await tester.tap(find.text('Ảnh mẫu'));
    await tester.pumpAndSettle();
    expect(find.text('Chưa tìm thấy quả xoài'), findsOneWidget);
    expect(find.text('Lớp dự đoán: 4'), findsNothing);
    expect(find.textContaining('an toàn thực phẩm'), findsOneWidget);
  });

  // Catches errors being swallowed or replaced with a fabricated prediction.
  testWidgets('native failure is visible and media actions become usable', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') {
            return {
              'modelName': 'MobileNetV3-Small',
              'modelBytes': 4000000,
              'threads': 2,
              'abi': 'arm64-v8a',
              'offline': true,
              'samplePath': '/sample.jpg',
              'metrics': {'nativePssMb': 78.0},
            };
          }
          if (call.method == 'analyzeImage') {
            throw PlatformException(code: 'DECODE', message: 'Ảnh bị hỏng');
          }
          return null;
        });
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Ảnh mẫu'), findsOneWidget);
    await tester.tap(find.text('Ảnh mẫu'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ảnh bị hỏng'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Ảnh mẫu'),
    );
    expect(button.onPressed, isNotNull);
  });

  // Removing the cancel check after an in-flight frame would advance to the next timestamp.
  testWidgets(
    'video cancel stops after the in-flight frame and keeps its result',
    (tester) async {
      final pending = Completer<Map<String, Object?>>();
      var frameCalls = 0;
      var closes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'prepare') {
              return {
                'modelName': 'MobileNetV3-Small',
                'modelBytes': 4000000,
                'threads': 2,
                'abi': 'arm64-v8a',
                'offline': true,
                'samplePath': '/sample.jpg',
                'metrics': {'nativePssMb': 78.0},
              };
            }
            if (call.method == 'openVideoSequence') {
              return {
                'durationMs': 10000,
                'width': 1920,
                'height': 1080,
                'estimatedFrameCount': 300,
              };
            }
            if (call.method == 'nextVideoFrame') {
              frameCalls++;
              return pending.future;
            }
            if (call.method == 'closeVideoSequence') {
              closes++;
              return null;
            }
            return _result('OK');
          });
      final controller = MangoController();
      addTearDown(controller.dispose);
      await controller.prepare();
      await tester.pumpWidget(MyApp(controller: controller));
      final video = controller.selectMedia(
        () async => const MediaSelection('/video.mp4', isVideo: true),
      );
      await tester.pump();
      expect(find.text('Hủy video'), findsOneWidget);
      await tester.tap(find.text('Hủy video'));
      await tester.pump();
      expect(find.text('Đang dừng sau khung hình hiện tại…'), findsOneWidget);
      pending.complete({
        ..._result('OK'),
        'timestampMs': 17,
        'frameIndex': 0,
        'endOfStream': false,
        'previewUpdated': true,
      });
      await video;
      await tester.pumpAndSettle();
      expect(frameCalls, 1);
      expect(controller.videoPoints.single.timestampMs, 17);
      expect(closes, 1);
      expect(controller.result, isNotNull);
      expect(controller.canSelect, isTrue);
      expect(find.textContaining('Đã dừng'), findsOneWidget);
    },
  );

  // Keeping null progress after cancellation would leave a stopped video's spinner running.
  testWidgets('early video cancellation leaves a stopped progress indicator', (
    tester,
  ) async {
    final metadata = Completer<Map<String, Object?>>();
    var frameCalls = 0;
    var closes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') {
            return {
              'modelName': 'MobileNetV3-Small',
              'modelBytes': 4000000,
              'threads': 2,
              'abi': 'arm64-v8a',
              'offline': true,
              'samplePath': '/sample.jpg',
              'metrics': {'nativePssMb': 78.0},
            };
          }
          if (call.method == 'openVideoSequence') return metadata.future;
          if (call.method == 'nextVideoFrame') frameCalls++;
          if (call.method == 'closeVideoSequence') {
            closes++;
            return null;
          }
          return _result('OK');
        });
    final controller = MangoController();
    addTearDown(controller.dispose);
    await controller.prepare();
    await tester.pumpWidget(MyApp(controller: controller));
    final video = controller.selectMedia(
      () async => const MediaSelection('/video.mp4', isVideo: true),
    );
    await tester.pump();
    await tester.tap(find.text('Hủy video'));
    await tester.pump();
    metadata.complete({
      'durationMs': 10000,
      'width': 1920,
      'height': 1080,
      'estimatedFrameCount': 300,
    });
    await video;
    await tester.pump();
    expect(find.text('Đã dừng • 0 khung'), findsOneWidget);
    final videoCard = find.ancestor(
      of: find.text('Đã dừng • 0 khung'),
      matching: find.byType(Card),
    );
    final progress = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: videoCard,
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(progress.value, 0);
    expect(frameCalls, 0);
    expect(closes, 1);
    expect(controller.canSelect, isTrue);
  });

  // Omitting the native region must not quietly display an unannotated success image.
  testWidgets('a detected region is represented by an image overlay', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') {
            return {
              'modelName': 'MobileNetV3-Small',
              'modelBytes': 4000000,
              'threads': 2,
              'abi': 'arm64-v8a',
              'offline': true,
              'samplePath': '/sample.jpg',
              'metrics': {'nativePssMb': 78.0},
            };
          }
          return {
            ..._result('OK'),
            'box': [0.25, 0.25, 0.75, 0.75],
          };
        });
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ảnh mẫu'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mango-image-overlay')), findsOneWidget);
  });

  // Continuing inference after the app is paused would consume memory offscreen.
  testWidgets('backgrounding requests a stop at the current video frame', (
    tester,
  ) async {
    final pending = Completer<Map<String, Object?>>();
    var frameCalls = 0;
    var closes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') {
            return {
              'modelName': 'MobileNetV3-Small',
              'modelBytes': 4000000,
              'threads': 2,
              'abi': 'arm64-v8a',
              'offline': true,
              'samplePath': '/sample.jpg',
              'metrics': {'nativePssMb': 78.0},
            };
          }
          if (call.method == 'openVideoSequence') {
            return {
              'durationMs': 10000,
              'width': 1920,
              'height': 1080,
              'estimatedFrameCount': 300,
            };
          }
          if (call.method == 'nextVideoFrame') {
            frameCalls++;
            return pending.future;
          }
          if (call.method == 'closeVideoSequence') {
            closes++;
            return null;
          }
          return _result('OK');
        });
    final controller = MangoController();
    addTearDown(controller.dispose);
    await controller.prepare();
    await tester.pumpWidget(MyApp(controller: controller));
    final video = controller.selectMedia(
      () async => const MediaSelection('/video.mp4', isVideo: true),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(controller.cancelRequested, isTrue);
    pending.complete({
      ..._result('OK'),
      'timestampMs': 0,
      'frameIndex': 0,
      'endOfStream': false,
      'previewUpdated': true,
    });
    await video;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.canSelect, isTrue);
    expect(frameCalls, 1);
    expect(closes, 1);
  });

  // Failing to recover Android's picker result after process death would lose the user's photo.
  testWidgets(
    'startup recovers and analyzes a photo returned after activity destruction',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pickerChannel, (call) async {
            if (call.method == 'retrieve') {
              return {'path': '/recovered.jpg', 'type': 'image'};
            }
            return null;
          });
      final controller = MangoController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(controller.selectedPath, '/recovered.jpg');
      expect(find.text('Ảnh được khôi phục'), findsOneWidget);
      expect(find.text('Chưa tìm thấy quả xoài'), findsOneWidget);
    },
  );

  // Reading the wrong runtime fields or hiding research provenance would misstate the phone/model.
  testWidgets(
    'technical details show actual device and labeled student test metrics',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'prepare') {
              return {
                'modelName': 'MobileNetV3-Small',
                'modelBytes': 4000000,
                'threads': 2,
                'abi': 'arm64-v8a',
                'offline': true,
                'samplePath': '/sample.jpg',
                'loadMs': 85.0,
                'nativePssMb': 78.0,
                'device': 'Google Pixel 8',
                'androidSdk': 37,
                'totalMemoryMb': 8064.0,
                'classLabels': [
                  'Nhãn A',
                  'Nhãn B',
                  'Nhãn C',
                  'Nhãn D',
                  'Nhãn E',
                ],
                'metrics': {
                  'internal_test': {
                    'n': 274,
                    'accuracy': 0.95,
                    'macro_f1': 0.90,
                    'class1_f1': 0.64,
                  },
                },
              };
            }
            return null;
          });
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      expect(find.text('Chi tiết model & thiết bị'), findsOneWidget);
      await tester.ensureVisible(find.text('Chi tiết model & thiết bị'));
      await tester.tap(find.text('Chi tiết model & thiết bị'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Google Pixel 8'), findsOneWidget);
      expect(find.textContaining('95.0%'), findsOneWidget);
      expect(find.textContaining('test nội bộ'), findsOneWidget);
      expect(find.textContaining('Nhãn A'), findsOneWidget);
      expect(find.textContaining('78.0 MB'), findsOneWidget);
    },
  );
}
