import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/live_camera.dart';

Map<String, Object?> frameFixture({String status = 'OK'}) => {
  'type': 'frame',
  'status': status,
  'classId': 1,
  'probabilities': [0.05, 0.8, 0.05, 0.05, 0.05],
  'box': [0.1, 0.2, 0.8, 0.9],
  'imageWidth': 640,
  'imageHeight': 480,
  'modelMs': 30.0,
  'preprocessMs': 10.0,
  'elapsedMs': 45.0,
  'stats': {
    'processed': 15,
    'skipped': 74,
    'delivered': 15,
    'inferenceFps': 4.8,
    'analyzerFps': 29.7,
    'maxFps': 5.0,
    'modelP50Ms': 30.0,
    'modelP95Ms': 38.0,
    'pipelineP50Ms': 45.0,
    'pipelineP95Ms': 53.0,
    'conversionP95Ms': 11.0,
    'callbackToOverlayP95Ms': 60.0,
    'pssMb': 101.0,
    'uptimeMs': 3125,
    'sampleCount': 15,
    'analysisWidth': 640,
    'analysisHeight': 480,
  },
};

class FakeCameraBackend implements LiveCameraBackend {
  final annotations = <(int, List<int>)>[];
  @override
  Future<void> annotate(int timestampMs, List<int> trackIds) async {
    annotations.add((timestampMs, List.of(trackIds)));
  }

  final stream = StreamController<Object?>.broadcast(sync: true);
  final calls = <String>[];
  Completer<void>? pendingStart;
  Completer<void>? pendingStop;
  Object? startError;
  Object? stopError;
  bool cancelPendingStartOnStop = false;

  @override
  Stream<Object?> get events => stream.stream;

  @override
  Future<void> start({
    required int viewId,
    required String lensFacing,
    required int maxFps,
  }) async {
    calls.add('start:$viewId:$lensFacing:$maxFps');
    if (pendingStart != null) await pendingStart!.future;
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (cancelPendingStartOnStop &&
        pendingStart != null &&
        !pendingStart!.isCompleted) {
      pendingStart!.completeError(PlatformException(code: 'CANCELLED'));
    }
    if (pendingStop != null) await pendingStop!.future;
    if (stopError != null) throw stopError!;
  }

  @override
  Future<Map<Object?, Object?>> stats() async =>
      Map<Object?, Object?>.from(frameFixture()['stats'] as Map);

  Future<void> close() => stream.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  // Removing the starting guard would bind the camera twice while permission is pending.
  test(
    'live session counts a repeated fruit once and resets on restart',
    () async {
      await controller.start();
      backend.stream.add({...frameFixture(), 'timestampMs': 100});
      backend.stream.add({...frameFixture(), 'timestampMs': 600});
      backend.stream.add({...frameFixture(), 'timestampMs': 1100});
      expect(controller.countSummary.confirmedCount, 1);
      expect(controller.countSummary.gradeCounts, {'fruit:L1': 1});
      await controller.stop();
      expect(controller.countSummary.confirmedCount, 1);
      await controller.start();
      expect(controller.countSummary.confirmedCount, 0);
    },
  );
  test('overlay receives persistent count identities when detection order reverses', () async {
    await controller.start();
    Map<String, Object?> object(double left) => {
      'box': [left, .1, left + .2, .5],
      'detectionScore': .9,
      'species': 'mango',
      'classId': 0,
      'probabilities': [.9, .1],
      'graded': true,
      'gradeScheme': 'source_two_stage',
      'status': 'OK',
    };
    final a = object(.1);
    final b = object(.65);
    backend.stream.add({
      ...frameFixture(),
      'timestampMs': 100,
      'objects': [a, b],
    });
    backend.stream.add({
      ...frameFixture(),
      'timestampMs': 200,
      'objects': [b, a],
    });
    expect(controller.error, isNull);
    expect(backend.annotations.map((item) => item.$1), [100, 200]);
    expect(backend.annotations.map((item) => item.$2), [
      [1, 2],
      [2, 1],
    ]);
    expect(controller.countSummary.confirmedCount, 2);
  });
  test('duplicate start does not open a second session', () async {
    backend.pendingStart = Completer<void>();
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, LiveCameraPhase.starting);
    await controller.start();
    expect(backend.calls, ['start:7:back:30']);
    backend.pendingStart!.complete();
    await start;
    expect(controller.phase, LiveCameraPhase.running);
    expect(controller.canStart, isFalse);
  });

  // Swallowing permission denial would strand the user on a black preview with no retry.
  test('permission denial is actionable and can be retried', () async {
    backend.startError = PlatformException(code: 'PERMISSION');
    await controller.start();
    expect(controller.phase, LiveCameraPhase.error);
    expect(controller.error, contains('quyền camera'));
    expect(controller.canStart, isTrue);
    backend.startError = null;
    await controller.start();
    expect(controller.error, isNull);
    expect(controller.phase, LiveCameraPhase.running);
  });

  // Exposing retry before failed-start cleanup completes would mark the next live session inactive.
  test('failed start cleanup completes before retry becomes enabled', () async {
    backend.startError = PlatformException(code: 'PERMISSION');
    backend.pendingStop = Completer<void>();
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    final canRetryBeforeCleanup = controller.canStart;
    backend.pendingStop!.complete();
    await start;
    expect(canRetryBeforeCleanup, isFalse);
    expect(controller.canStart, isTrue);
    backend.startError = null;
    await controller.start();
    expect(controller.sessionActive, isTrue);
    await controller.handleLifecycle(AppLifecycleState.paused);
    expect(controller.phase, LiveCameraPhase.idle);
  });

  // Starting the new lens before the old one unbinds would cause a native BUSY error.
  test('lens switch stops before starting the selected camera', () async {
    await controller.start();
    backend.pendingStop = Completer<void>();
    final change = controller.switchLens();
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, LiveCameraPhase.stopping);
    expect(backend.calls, ['start:7:back:30', 'stop']);
    backend.pendingStop!.complete();
    await change;
    expect(backend.calls, ['start:7:back:30', 'stop', 'start:7:front:30']);
    expect(controller.lensFacing, 'front');
    expect(controller.phase, LiveCameraPhase.running);
  });

  // Restoring a session on resumed would activate the camera without another user action.
  test(
    'background stop ignores later frames and resume stays stopped',
    () async {
      await controller.start();
      backend.stream.add(frameFixture());
      expect(controller.result?.classId, 1);
      await controller.handleLifecycle(AppLifecycleState.paused);
      backend.stream.add({...frameFixture(), 'classId': 2});
      await controller.handleLifecycle(AppLifecycleState.resumed);
      expect(controller.phase, LiveCameraPhase.idle);
      expect(controller.result?.classId, 1);
      expect(backend.calls, ['start:7:back:30', 'stop']);
      expect(controller.canStart, isTrue);
    },
  );

  // Stopping only after start resolves must not leave a permission-delayed camera running.
  test('background while starting unbinds after the pending start', () async {
    backend.pendingStart = Completer<void>();
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    final stop = controller.handleLifecycle(AppLifecycleState.paused);
    backend.pendingStart!.complete();
    await start;
    await stop;
    expect(controller.phase, LiveCameraPhase.idle);
    expect(backend.calls, ['start:7:back:30', 'stop']);
  });

  // Queueing stop behind a permission/first-frame reply would leave the camera opening in the background.
  test('stop reaches native while camera start is still pending', () async {
    backend.pendingStart = Completer<void>();
    backend.cancelPendingStartOnStop = true;
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    final stop = controller.handleLifecycle(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    final beforeCompletion = List<String>.of(backend.calls);
    // Ensure the RED run also exits if stop was incorrectly queued behind start.
    if (!backend.pendingStart!.isCompleted) backend.pendingStart!.complete();
    await start;
    await stop;
    expect(beforeCompletion, ['start:7:back:30', 'stop']);
    expect(controller.phase, LiveCameraPhase.idle);
    expect(controller.error, isNull);
  });

  // Treating elapsed uptime as a frame count would reject native fractional millisecond timestamps.
  test('fractional native uptime remains a valid measurement', () async {
    await controller.start();
    backend.stream.add({
      ...frameFixture(),
      'stats': {...frameFixture()['stats'] as Map, 'uptimeMs': 3125.75},
    });
    expect(controller.error, isNull);
    expect(controller.result?.performance.number('uptimeMs'), 3125.75);
  });

  // Disposing without cancelling native work would keep the camera open behind the previous page.
  test(
    'dispose stops and detaches the session without later notifications',
    () async {
      await controller.start();
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.dispose();
      await controller.closed;
      final before = notifications;
      backend.stream.add(frameFixture());
      expect(notifications, before);
      expect(controller.result, isNull);
      expect(backend.calls, ['start:7:back:30', 'stop']);
    },
  );

  // Accepting malformed native data would surface invalid scores or region coordinates.
  test(
    'malformed frame stops the session and clears stale predictions',
    () async {
      for (final mutation in <Map<String, Object?>>[
        {
          'probabilities': [0.1, 0.2],
        },
        {
          'probabilities': [0.1, double.nan, 0.2, 0.3, 0.4],
        },
        {'classId': 1.5},
        {'classId': 5},
        {
          'box': [0.8, 0.1, 0.2, 0.9],
        },
        {'imageWidth': 0},
        {'elapsedMs': -1},
        {
          'stats': {'inferenceFps': double.infinity},
        },
      ]) {
        await controller.start();
        backend.stream.add(frameFixture());
        backend.stream.add({...frameFixture(), ...mutation});
        await controller.settled;
        expect(controller.phase, LiveCameraPhase.error);
        expect(controller.result, isNull);
        expect(controller.error, isNotNull, reason: '$mutation');
      }
      await controller.start();
      backend.stream.add(frameFixture(status: 'NO_MANGO'));
      expect(controller.result?.status, LiveFrameStatus.noMango);
      expect(controller.error, isNull);
    },
  );

  // A native asynchronous error must release the camera and expose restart.
  test('native error event stops the session and exposes retry', () async {
    await controller.start();
    backend.stream.add({
      'type': 'state',
      'state': 'error',
      'message': 'Camera unavailable',
    });
    await controller.settled;
    expect(controller.phase, LiveCameraPhase.error);
    expect(controller.error, contains('Camera unavailable'));
    expect(controller.canStart, isTrue);
    expect(backend.calls, ['start:7:back:30', 'stop']);
  });

  // A stopped session's queued events must not reappear after a new start.
  test('stop then start clears the prior result before new frames', () async {
    await controller.start();
    backend.stream.add(frameFixture());
    await controller.stop();
    backend.stream.add({...frameFixture(), 'classId': 3});
    await controller.start();
    expect(controller.result, isNull);
    backend.stream.add({...frameFixture(), 'classId': 2});
    expect(controller.result?.classId, 2);
  });
}
