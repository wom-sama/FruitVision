import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/fruit_line_counter.dart';
import 'package:mango_offline/inference.dart';
import 'package:mango_offline/live_camera.dart';

import 'controller_test.dart' show prepareFixture, resultFixture;
import 'live_camera_test.dart' show FakeCameraBackend, frameFixture;

const _channel = MethodChannel('vn.mangodemo/inference');
const _crossing = [.38, .38, .4, .46, .54, .58];

Map<String, Object?> _scene(
  Map<String, Object?> base,
  int timestamp,
  double? center, {
  bool unknown = false,
}) {
  final data = <String, Object?>{
    ...base,
    'timestampMs': timestamp,
    'previewUpdated': false,
    'objects': [
      if (center != null)
        {
          'box': [.2, center - .15, .5, center + .15],
          'detectionScore': .9,
          'species': unknown ? 'fruit' : 'mango',
          'status': unknown ? 'UNSUPPORTED_SPECIES' : 'OK',
          'graded': !unknown,
          if (!unknown) ...{
            'classId': 0,
            'probabilities': [.8, .05, .05, .05, .05],
          },
        },
    ],
  };
  if (unknown || center == null) {
    data.remove('classId');
    data.remove('probabilities');
    data['graded'] = false;
    data['status'] = center == null ? 'NO_FRUIT' : 'UNSUPPORTED_SPECIES';
    if (center != null) data['species'] = 'fruit';
  }
  return data;
}

void _videoFrames(List<double?> centers, {bool unknown = false}) {
  var index = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'openVideoSequence') {
          index = 0;
          return {'durationMs': 10000, 'estimatedFrameCount': centers.length};
        }
        if (call.method == 'nextVideoFrame') {
          if (index == centers.length) return {'endOfStream': true};
          final i = index++;
          return _scene(resultFixture(), i * 100, centers[i], unknown: unknown);
        }
        if (call.method == 'analyzeImage') return resultFixture();
        return null;
      });
}

Future<void> _runVideo(MangoController controller) => controller.selectMedia(
  () async => const MediaSelection('/conveyor.mp4', isVideo: true),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('video line counting', () {
    late MangoController controller;

    setUp(() {
      controller = MangoController()
        ..runtime = RuntimeInfo.fromMap(prepareFixture());
    });

    tearDown(() {
      controller.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test(
      'decoded frames count one crossing without requiring preview updates',
      () async {
        _videoFrames(_crossing);
        controller.setCountingLine(FruitLineCounter());
        await _runVideo(controller);
        expect(controller.error, isNull);
        expect(controller.countSummary.confirmedCount, 1);
        expect(controller.countSummary.gradeCounts, {'mango:L0': 1});
        expect(controller.trackingSummary.confirmedCount, 1);
        expect(controller.completedSamples, 6);
      },
    );

    test('repeated crossings retain one tracker ID and count once', () async {
      _videoFrames([..._crossing, .58, .54, .46, .4, .4, .46, .54, .58]);
      controller.setCountingLine(FruitLineCounter());
      await _runVideo(controller);
      expect(controller.error, isNull);
      expect(controller.trackingSummary.confirmedCount, 1);
      expect(controller.countSummary.confirmedCount, 1);
    });

    test(
      'generic unknown fruit crosses without a fabricated maturity',
      () async {
        _videoFrames(_crossing, unknown: true);
        controller.setCountingLine(FruitLineCounter());
        await _runVideo(controller);
        expect(controller.error, isNull);
        expect(controller.countSummary.confirmedCount, 1);
        expect(controller.countSummary.ungradedCount, 1);
        expect(controller.countSummary.gradeCounts, isEmpty);
      },
    );

    test('empty decoded frame advances the selected counter once', () async {
      _videoFrames([..._crossing, null]);
      final line = FruitLineCounter();
      controller.setCountingLine(line);
      await _runVideo(controller);
      expect(controller.error, isNull);
      expect(controller.countSummary.confirmedCount, 1);
      expect(() => line.update(600, []), throwsArgumentError);
    });

    test(
      'new video and image reset counts while preserving the selected line',
      () async {
        _videoFrames(_crossing);
        final line = FruitLineCounter();
        controller.setCountingLine(line);
        await _runVideo(controller);
        await _runVideo(controller);
        expect(controller.error, isNull);
        expect(controller.lineCounter, same(line));
        expect(controller.countSummary.confirmedCount, 1);
        expect(controller.trackingSummary.confirmedCount, 1);
        await controller.analyzeImage('/new.jpg');
        expect(controller.lineCounter, same(line));
        expect(controller.countSummary.confirmedCount, 0);
        expect(controller.trackingSummary.confirmedCount, 0);
      },
    );

    test(
      'configuration cannot change during a pending native video frame',
      () async {
        final pending = Completer<Map<String, Object?>>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              if (call.method == 'openVideoSequence') {
                return {'durationMs': 1000};
              }
              if (call.method == 'nextVideoFrame') return pending.future;
              return null;
            });
        final line = FruitLineCounter();
        controller.setCountingLine(line);
        final run = _runVideo(controller);
        await Future<void>.delayed(Duration.zero);
        expect(controller.busy, isTrue);
        expect(() => controller.setCountingLine(null), throwsStateError);
        expect(controller.lineCounter, same(line));
        pending.complete({'endOfStream': true});
        await run;
        controller.setCountingLine(null);
        expect(controller.lineCounter, isNull);
      },
    );

    test(
      'default tracker counts observed fruit without requiring a crossing',
      () async {
        _videoFrames([.38, .38, .38]);
        await _runVideo(controller);
        expect(controller.lineCounter, isNull);
        expect(controller.countSummary.confirmedCount, 1);
        expect(controller.trackingSummary.confirmedCount, 1);
      },
    );
  });

  group('live line counting', () {
    late FakeCameraBackend backend;
    late LiveCameraController controller;

    setUp(() {
      backend = FakeCameraBackend();
      controller = LiveCameraController(backend: backend)..attachPreview(7);
    });

    tearDown(() async {
      controller.dispose();
      await controller.closed;
      await backend.close();
    });

    void emit(List<double?> centers, {bool unknown = false}) {
      for (var i = 0; i < centers.length; i++) {
        backend.stream.add(
          _scene(frameFixture(), i * 100, centers[i], unknown: unknown),
        );
      }
    }

    test(
      'live frames cross once with confirmed IDs and retain overlay IDs',
      () async {
        controller.setCountingLine(FruitLineCounter());
        await controller.start();
        emit([..._crossing, .54, .46, .4, .4, .46, .54, .58]);
        expect(controller.error, isNull);
        expect(controller.phase, LiveCameraPhase.running);
        expect(controller.countSummary.confirmedCount, 1);
        expect(controller.countSummary.gradeCounts, {'mango:L0': 1});
        expect(controller.trackingSummary.confirmedCount, 1);
        expect(
          backend.annotations.every((frame) => frame.$2.single == 1),
          isTrue,
        );
      },
    );

    test(
      'live unknown fruit stays ungraded and restart resets both histories',
      () async {
        final line = FruitLineCounter();
        controller.setCountingLine(line);
        await controller.start();
        emit(_crossing, unknown: true);
        expect(controller.countSummary.confirmedCount, 1);
        expect(controller.countSummary.ungradedCount, 1);
        expect(controller.countSummary.gradeCounts, isEmpty);
        await controller.stop();
        expect(controller.countSummary.confirmedCount, 1);
        await controller.start();
        expect(controller.lineCounter, same(line));
        expect(controller.countSummary.confirmedCount, 0);
        expect(controller.trackingSummary.confirmedCount, 0);
        emit(_crossing, unknown: true);
        expect(controller.error, isNull);
        expect(controller.countSummary.confirmedCount, 1);
        expect(controller.trackingSummary.confirmedCount, 1);
      },
    );

    test(
      'empty live frames advance once and duplicate callbacks are ignored',
      () async {
        final line = FruitLineCounter();
        controller.setCountingLine(line);
        await controller.start();
        emit([..._crossing, null]);
        backend.stream.add(_scene(frameFixture(), 600, null));
        expect(controller.error, isNull);
        expect(controller.phase, LiveCameraPhase.running);
        expect(controller.countSummary.confirmedCount, 1);
        expect(backend.annotations.last.$1, 600);
        expect(backend.annotations.last.$2, isEmpty);
        expect(backend.annotations.length, 7);
        expect(() => line.update(600, []), throwsArgumentError);
      },
    );

    test('configuration is locked during start, running and stop', () async {
      final line = FruitLineCounter();
      controller.setCountingLine(line);
      backend.pendingStart = Completer<void>();
      final start = controller.start();
      expect(() => controller.setCountingLine(null), throwsStateError);
      backend.pendingStart!.complete();
      await start;
      expect(() => controller.setCountingLine(null), throwsStateError);
      backend.pendingStop = Completer<void>();
      final stop = controller.stop();
      expect(() => controller.setCountingLine(null), throwsStateError);
      expect(controller.lineCounter, same(line));
      backend.pendingStop!.complete();
      await stop;
      controller.setCountingLine(null);
      expect(controller.lineCounter, isNull);
    });

    test('default live tracking retains observed-unique counting', () async {
      await controller.start();
      emit([.38, .38, .38]);
      expect(controller.lineCounter, isNull);
      expect(controller.countSummary.confirmedCount, 1);
      expect(controller.trackingSummary.confirmedCount, 1);
    });
  });
}
