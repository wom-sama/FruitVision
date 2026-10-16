import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/inference.dart';

const _channel = MethodChannel('vn.mangodemo/inference');

Map<String, Object?> resultFixture({List<double>? box}) => {
  'status': 'OK',
  'probabilities': [0.8, 0.05, 0.05, 0.05, 0.05],
  'classId': 0,
  'box': box ?? [0.1, 0.2, 0.8, 0.9],
  'previewPath': '/preview.jpg',
  'elapsedMs': 40.0,
  'modelMs': 25.0,
  'preprocessMs': 12.0,
  'nativePssMb': 88.0,
};

Map<String, Object?> prepareFixture() => {
  'modelName': 'MobileNetV3-Small',
  'modelBytes': 4000000,
  'threads': 2,
  'abi': 'arm64-v8a',
  'offline': true,
  'samplePath': '/sample.jpg',
  'metrics': {'nativePssMb': 78.0},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  // Removing the busy guard would replace the current media and launch a second inference.
  test(
    'busy image analysis preserves current selection and rejects a duplicate',
    () async {
      final pending = Completer<Map<String, Object?>>();
      final paths = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'prepare') return prepareFixture();
            if (call.method == 'analyzeImage') {
              paths.add((call.arguments as Map)['path'] as String);
              return pending.future;
            }
            return null;
          });
      final controller = MangoController();
      addTearDown(controller.dispose);
      await controller.prepare();
      final first = controller.analyzeImage('/first.jpg');
      await controller.analyzeImage('/second.jpg');
      expect(controller.busy, isTrue);
      expect(controller.canSelect, isFalse);
      expect(controller.selectedPath, '/first.jpg');
      pending.complete(resultFixture());
      await first;
      expect(controller.result?.previewPath, '/preview.jpg');
      expect(controller.canSelect, isTrue);
      expect(paths, ['/first.jpg']);
    },
  );

  // Ignoring a malformed box would draw outside the actual photo or reverse its corners.
  test(
    'rejects invalid normalized bounding boxes instead of showing a result',
    () async {
      for (final box in [
        <double>[-0.1, 0.2, 0.8, 0.9],
        <double>[0.8, 0.2, 0.1, 0.9],
        <double>[0.1, 0.2, 0.8, 1.1],
        <double>[0.1, 0.2, double.nan, 0.9],
        <double>[0.1, 0.2, 0.8],
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              if (call.method == 'prepare') return prepareFixture();
              if (call.method == 'analyzeImage') return resultFixture(box: box);
              return null;
            });
        final controller = MangoController();
        await controller.prepare();
        await controller.analyzeImage('/bad-box.jpg');
        expect(controller.result, isNull, reason: 'Invalid native box: $box');
        expect(controller.error, contains('vùng quả'));
        expect(controller.canSelect, isTrue);
        controller.dispose();
      }
    },
  );

  // Routing a selected video to the image decoder would lose timestamp sampling.
  test('video selection enters a sequential frame analysis phase', () async {
    final frame = Completer<Map<String, Object?>>();
    final called = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') return prepareFixture();
          called.add(call.method);
          if (call.method == 'openVideoSequence') {
            return {
              'durationMs': 8000,
              'width': 1920,
              'height': 1080,
              'estimatedFrameCount': 240,
            };
          }
          if (call.method == 'nextVideoFrame') {
            if (called.where((m) => m == 'nextVideoFrame').length == 1) {
              return frame.future;
            }
            return {'endOfStream': true, 'framesDecoded': 1};
          }
          return resultFixture();
        });
    final controller = MangoController();
    addTearDown(controller.dispose);
    await controller.prepare();
    final selection = controller.selectMedia(
      () async =>
          const MediaSelection('/video.mp4', isVideo: true, label: 'Video'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, WorkPhase.video);
    expect(called, ['openVideoSequence', 'nextVideoFrame']);
    frame.complete({
      ...resultFixture(),
      'timestampMs': 17,
      'frameIndex': 0,
      'endOfStream': false,
      'previewUpdated': true,
    });
    await selection;
    expect(controller.error, isNull);
  });

  // An unbounded loop or Future.wait would process too many frames or overlap native calls.
  test('video consumes actual decoded timestamps until EOS with one frame in flight', () async {
    final timestamps = <int>[];
    var activeFrames = 0;
    var peakFrames = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') return prepareFixture();
          if (call.method == 'openVideoSequence') {
            return {
              'durationMs': 1000,
              'width': 1920,
              'height': 1080,
              'estimatedFrameCount': 30,
            };
          }
          if (call.method == 'nextVideoFrame') {
            if (timestamps.length == 30) {
              return {'endOfStream': true, 'framesDecoded': 30};
            }
            final timestamp = 7 + timestamps.length * 33;
            timestamps.add(timestamp);
            activeFrames++;
            if (activeFrames > peakFrames) peakFrames = activeFrames;
            await Future<void>.delayed(Duration.zero);
            activeFrames--;
            return {
              ...resultFixture(),
              'timestampMs': timestamp,
              'frameIndex': timestamps.length - 1,
              'endOfStream': false,
              'previewUpdated': timestamps.length % 6 == 1,
            };
          }
          return resultFixture();
        });
    final controller = MangoController();
    addTearDown(controller.dispose);
    await controller.prepare();
    await controller.selectMedia(
      () async => const MediaSelection('/long.mp4', isVideo: true),
    );
    expect(timestamps.length, 30);
    expect(timestamps.first, 7);
    expect(timestamps.last, 964);
    expect(peakFrames, 1);
    expect(controller.result, isNotNull);
    expect(controller.busy, isFalse);
    expect(controller.countSummary.confirmedCount, 1);
    expect(controller.countSummary.gradeCounts, {'fruit:L0': 1});
  });
  test('new image clears prior video production counts', () async {
    var frames = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') return prepareFixture();
          if (call.method == 'openVideoSequence') {
            return {'durationMs': 1000, 'estimatedFrameCount': 2};
          }
          if (call.method == 'nextVideoFrame') {
            if (frames == 2) return {'endOfStream': true, 'framesDecoded': 2};
            final index = frames++;
            return {
              ...resultFixture(),
              'timestampMs': index * 33,
              'frameIndex': index,
              'endOfStream': false,
              'previewUpdated': true,
            };
          }
          return resultFixture();
        });
    final controller = MangoController();
    addTearDown(controller.dispose);
    await controller.prepare();
    await controller.selectMedia(
      () async => const MediaSelection('/a.mp4', isVideo: true),
    );
    expect(controller.countSummary.confirmedCount, 1);
    await controller.analyzeImage('/b.jpg');
    expect(controller.countSummary.confirmedCount, 0);
  });

  test(
    'cancelling video closes the decoder after its in-flight frame',
    () async {
      final pending = Completer<Map<String, Object?>>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'prepare') return prepareFixture();
            calls.add(call.method);
            if (call.method == 'openVideoSequence') {
              return {'durationMs': 1000, 'estimatedFrameCount': 30};
            }
            if (call.method == 'nextVideoFrame') return pending.future;
            return null;
          });
      final controller = MangoController();
      addTearDown(controller.dispose);
      await controller.prepare();
      final work = controller.selectMedia(
        () async => const MediaSelection('/a.mp4', isVideo: true),
      );
      await Future<void>.delayed(Duration.zero);
      controller.cancelVideo();
      pending.complete({
        ...resultFixture(),
        'timestampMs': 0,
        'frameIndex': 0,
        'endOfStream': false,
        'previewUpdated': true,
      });
      await work;
      expect(calls, [
        'openVideoSequence',
        'nextVideoFrame',
        'closeVideoSequence',
      ]);
      expect(controller.videoCanceled, isTrue);
      expect(controller.busy, isFalse);
    },
  );
  test('invalid sequence metadata closes the opened decoder before reporting failure', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'prepare') return prepareFixture();
          calls.add(call.method);
          if (call.method == 'openVideoSequence') return {'durationMs': 0};
          return null;
        });
    final controller = MangoController();
    addTearDown(controller.dispose);
    await controller.prepare();
    await controller.selectMedia(
      () async => const MediaSelection('/empty.mp4', isVideo: true),
    );
    expect(calls, ['openVideoSequence', 'closeVideoSequence']);
    expect(controller.error, contains('Video rỗng'));
  });
}
