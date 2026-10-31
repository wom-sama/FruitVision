import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/live_camera.dart';

class Frames implements LiveFrameSource {
  int starts = 0, stops = 0, captures = 0;
  @override
  Future<void> start(int id) async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<CameraFrame> frame() async {
    captures++;
    return CameraFrame(Uint8List.fromList([255, 216, 255, 217]), 640, 480);
  }
}

class Gateway implements LiveAiGateway {
  final pending = <Completer<Map<String, dynamic>>>[];
  final sequences = <int>[];
  int closes = 0;
  @override
  Future<Map<String, dynamic>> open() async => {
    'id': 'owned',
    'nextSequence': 1,
    'minFrameIntervalMs': 150,
  };
  @override
  Future<void> close(String id) async {
    closes++;
  }

  @override
  Future<Map<String, dynamic>> infer(
    String id,
    int sequence,
    CameraFrame f,
    UploadCancellation cancel,
  ) {
    sequences.add(sequence);
    final c = Completer<Map<String, dynamic>>();
    pending.add(c);
    return c.future;
  }

  Map<String, dynamic> response(int sequence) => {
    'sessionId': 'owned',
    'sequence': sequence,
    'imageWidth': 640,
    'imageHeight': 480,
    'visibleCount': 0,
    'objects': [],
    'processingMs': 15.0,
  };
}

void main() {
  testWidgets(
    'captures no next frame while API is pending and drops response after stop',
    (tester) async {
      final f = Frames(), g = Gateway();
      final c = LiveCameraController(source: f, gateway: g);
      await c.start(7);
      await tester.pump(const Duration(seconds: 1));
      expect(g.sequences, [1]);
      expect(f.captures, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(f.captures, 1);
      await c.stop();
      g.pending.single.complete(g.response(1));
      await tester.pump();
      expect(c.result, isNull);
      expect(c.frames, 0);
      expect(c.running, false);
      expect(g.closes, 1);
      expect(f.stops, 1);
      c.dispose();
    },
  );
  testWidgets(
    'only validated current response updates processed counts, then asks a fresh frame',
    (tester) async {
      final f = Frames(), g = Gateway();
      final c = LiveCameraController(source: f, gateway: g);
      await c.start(1);
      await tester.pump(const Duration(seconds: 1));
      g.pending.first.complete(g.response(1));
      await tester.pump();
      expect(c.frames, 1);
      expect(c.analyzedFrame?.width, 640);
      await tester.pump(const Duration(milliseconds: 200));
      expect(g.sequences, [1, 2]);
      await c.stop();
      g.pending.last.complete(g.response(2));
      await tester.pump();
      c.dispose();
    },
  );
  testWidgets(
    'wrong sequence fails closed and stops camera instead of painting another frame',
    (tester) async {
      final f = Frames(), g = Gateway();
      final c = LiveCameraController(source: f, gateway: g);
      await c.start(2);
      await tester.pump(const Duration(seconds: 1));
      g.pending.first.complete(g.response(99));
      await tester.pump();
      expect(c.frames, 0);
      expect(c.result, isNull);
      expect(c.running, false);
      expect(c.error, isNotNull);
      expect(g.closes, 1);
      c.dispose();
    },
  );
}
