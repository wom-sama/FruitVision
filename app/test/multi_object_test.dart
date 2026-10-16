import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/inference.dart';
import 'package:mango_offline/image_preview.dart';
import 'package:mango_offline/live_camera.dart';
import 'package:mango_offline/live_camera_page.dart';
import 'package:mango_offline/main.dart';

import 'controller_test.dart' show prepareFixture, resultFixture;
import 'live_camera_page_test.dart' show FakePreview;
import 'live_camera_test.dart' show FakeCameraBackend, frameFixture;

Map<String, Object?> objectFixture({int classId = 0}) => {
  'box': classId == 0 ? [0.05, 0.15, 0.4, 0.8] : [0.55, 0.1, 0.95, 0.7],
  'detectionScore': 0.9,
  'classId': classId,
  'probabilities': classId == 0
      ? [0.8, 0.05, 0.05, 0.05, 0.05]
      : [0.05, 0.05, 0.8, 0.05, 0.05],
  'status': 'OK',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vn.mangodemo/inference');
  testWidgets(
    'direct-stage real multi photo is not labelled a synthetic collage',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            (call) async => null,
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeImage') {
              return {...resultFixture(), 'objects': <Object?>[]};
            }
            return null;
          });
      final controller = MangoController()
        ..runtime = RuntimeInfo.fromMap({
          ...prepareFixture(),
          'graderMode': 'detection_stages',
          'supportedSpecies': ['banana', 'mango'],
          'classLabels': ['Xanh / chưa chín', 'Chín'],
          'multiSamplePath': '/files/actual_multi.png',
        });
      addTearDown(controller.dispose);
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Ảnh nhiều quả'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Ảnh nhiều quả'));
      });
      await tester.pumpAndSettle();
      expect(
        controller.mediaLabel,
        'Ảnh nhiều quả · ảnh thật trong nguồn dữ liệu',
      );
      expect(find.textContaining('không phải cảnh quay thực tế'), findsNothing);
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, null);
  });

  // Ignoring malformed objects would draw invalid regions or fabricate grades.
  for (final invalid in <Object?>[
    null,
    'not a list',
    [null],
    [<String, Object?>{}],
    [
      {
        ...objectFixture(),
        'box': [0.8, 0.1, 0.2, 0.9],
      },
    ],
    [
      {
        ...objectFixture(),
        'box': [0.1, 0.2, double.nan, 0.9],
      },
    ],
    [
      {
        ...objectFixture(),
        'box': [0.1, 0.2, 0.8, 1.1],
      },
    ],
    [
      {...objectFixture(), 'detectionScore': -0.1},
    ],
    [
      {...objectFixture(), 'detectionScore': double.infinity},
    ],
    [
      {...objectFixture(), 'classId': 0.5},
    ],
    [
      {...objectFixture(), 'classId': 5},
    ],
    [
      {
        ...objectFixture(),
        'probabilities': [1.0],
      },
    ],
    [
      {
        ...objectFixture(),
        'probabilities': [0.1, 0.2, 0.3, 0.4, 1.1],
      },
    ],
    [
      {...objectFixture(), 'status': 'NO_MANGO'},
    ],
    List.generate(9, (_) => objectFixture()),
  ]) {
    test('photo and live reject malformed objects: $invalid', () {
      expect(
        () => AnalysisResult.fromMap({...resultFixture(), 'objects': invalid}),
        throwsFormatException,
      );
      expect(
        () => LiveFrame.fromMap({...frameFixture(), 'objects': invalid}),
        throwsFormatException,
      );
    });
  }

  for (final entry in <String, Object?>{
    'detectorMs': double.nan,
    'classificationMs': -1.0,
    'detectionLimitReached': 'true',
    'timestampMs': double.infinity,
  }.entries) {
    test('photo rejects invalid scene metadata ${entry.key}', () {
      expect(
        () => AnalysisResult.fromMap({
          ...resultFixture(),
          'objects': [objectFixture()],
          entry.key: entry.value,
        }),
        throwsFormatException,
      );
    });
  }

  // A global classifier score must never replace either crop's own score.
  test('scene objects retain separate classes and immutable crop scores', () {
    final input = [objectFixture(), objectFixture(classId: 2)];
    final photo = AnalysisResult.fromMap({
      ...resultFixture(),
      'objects': input,
    });
    final live = LiveFrame.fromMap({...frameFixture(), 'objects': input});
    expect(photo.sceneObjects.map((object) => object.classId), [0, 2]);
    expect(live.sceneObjects.map((object) => object.confidence), [0.8, 0.8]);
    expect(() => photo.objects!.clear(), throwsUnsupportedError);
    expect(() => live.objects![1].probabilities[2] = 0, throwsUnsupportedError);
    input.clear();
    expect(photo.objects, hasLength(2));
  });

  // The sample action must analyze the provided scene, not the single-fruit path.
  testWidgets('stitched multi-fruit sample reuses bounded image analysis', (
    tester,
  ) async {
    final pending = Completer<Map<String, Object?>>();
    final analyzedPaths = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'analyzeImage') {
            analyzedPaths.add((call.arguments as Map)['path'] as String);
            return pending.future;
          }
          return null;
        });
    final controller = MangoController()
      ..runtime = RuntimeInfo.fromMap({
        ...prepareFixture(),
        'multiSamplePath': '/files/demo_multi_mango.png',
      });
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    final button = find.widgetWithText(OutlinedButton, 'Ảnh nhiều quả (ghép)');
    expect(button, findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pump();
    expect(analyzedPaths, ['/files/demo_multi_mango.png']);
    expect(controller.selectedPath, '/files/demo_multi_mango.png');
    expect(controller.busy, isTrue);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    expect(find.textContaining('không phải cảnh quay thực tế'), findsOneWidget);
    pending.complete({
      ...resultFixture(),
      'objects': [objectFixture(), objectFixture(classId: 2)],
    });
    await tester.pumpAndSettle();
    expect(find.text('Quả 1 · Lớp 0'), findsOneWidget);
    expect(find.text('Quả 2 · Lớp 2'), findsOneWidget);
    expect(controller.busy, isFalse);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'single-model runtime does not offer an unavailable multi sample',
    (tester) async {
      final controller = MangoController()
        ..runtime = RuntimeInfo.fromMap(prepareFixture());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Ảnh nhiều quả (ghép)'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'absent objects use a legacy fruit only with a box and mango status',
    () {
      expect(
        AnalysisResult.fromMap(resultFixture()).sceneObjects,
        hasLength(1),
      );
      expect(LiveFrame.fromMap(frameFixture()).sceneObjects, hasLength(1));
      expect(
        AnalysisResult.fromMap({...resultFixture(), 'box': null}).sceneObjects,
        isEmpty,
      );
      expect(
        LiveFrame.fromMap(frameFixture(status: 'NO_MANGO')).sceneObjects,
        isEmpty,
      );
      expect(
        AnalysisResult.fromMap({...resultFixture(), 'objects': []})
            .sceneObjects,
        isEmpty,
      );
      expect(
        LiveFrame.fromMap({...frameFixture(), 'objects': []}).sceneObjects,
        isEmpty,
      );
    },
  );

  test('live rejects nonfinite scene timings and fractional timestamps', () {
    for (final entry in <String, Object?>{
      'detectorMs': double.infinity,
      'classificationMs': -1.0,
      'detectionLimitReached': 1,
      'timestampMs': 0.5,
    }.entries) {
      expect(
        () => LiveFrame.fromMap({...frameFixture(), entry.key: entry.value}),
        throwsFormatException,
      );
    }
  });

  // Video summaries must count detections instead of displaying one scene-wide grade.
  testWidgets(
    'video timeline reports object counts at actual decoded timestamps',
    (tester) async {
      var frames = 0;
      var closes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'openVideoSequence') {
              return {'durationMs': 1000, 'estimatedFrameCount': 2};
            }
            if (call.method == 'closeVideoSequence') {
              closes++;
              return null;
            }
            if (call.method == 'nextVideoFrame') {
              if (frames == 2) return {'endOfStream': true, 'framesDecoded': 2};
              final index = frames++;
              return {
                ...resultFixture(),
                'objects': [objectFixture(), objectFixture(classId: 2)],
                'timestampMs': index == 0 ? 17 : 250,
                'frameIndex': index,
                'endOfStream': false,
                'previewUpdated': true,
              };
            }
            return null;
          });
      final controller = MangoController()
        ..runtime = RuntimeInfo.fromMap(prepareFixture());
      addTearDown(controller.dispose);
      await controller.selectMedia(
        () async => const MediaSelection('/movie.mp4', isVideo: true),
      );
      expect(controller.videoPoints, hasLength(2));
      expect(
        controller.videoPoints.every((point) => point.objectCount == 2),
        isTrue,
      );
      expect(controller.countSummary.confirmedCount, 2);
      expect(controller.videoPoints.map((point) => point.timestampMs), [
        17,
        250,
      ]);
      expect(controller.videoReachedEnd, isTrue);
      expect(closes, 1);
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('00:00.0 · 2 quả'), findsOneWidget);
      expect(find.text('Quả 1 · Lớp 0'), findsOneWidget);
      expect(find.text('Quả 2 · Lớp 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'uncertain object is labeled as a candidate without hiding other fruits',
    (tester) async {
      final controller = MangoController()
        ..runtime = RuntimeInfo.fromMap(prepareFixture())
        ..result = AnalysisResult.fromMap({
          ...resultFixture(),
          'objects': [
            objectFixture(),
            {...objectFixture(classId: 2), 'status': 'UNCERTAIN'},
          ],
        });
      addTearDown(controller.dispose);
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Quả 1 · Lớp 0'), findsOneWidget);
      expect(find.text('Quả 2 · Chưa đủ tin cậy'), findsOneWidget);
      expect(find.textContaining('Ứng viên lớp 2'), findsOneWidget);
      expect(find.text('Quả 2 · Lớp 2'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in const [Size(390, 844), Size(844, 390)]) {
    // A global-class fallback would turn two different mango grades into one.
    testWidgets('photo displays both objects with bounded layout at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = MangoController()
        ..runtime = RuntimeInfo.fromMap(prepareFixture())
        ..result = AnalysisResult.fromMap({
          ...resultFixture(),
          'classId': 4,
          'objects': [objectFixture(), objectFixture(classId: 2)],
          'detectorMs': 12.0,
          'classificationMs': 30.0,
          'detectionLimitReached': true,
        });
      addTearDown(controller.dispose);
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Quả 1 · Lớp 0'), findsOneWidget);
      expect(find.text('Quả 2 · Lớp 2'), findsOneWidget);
      expect(find.text('Lớp dự đoán: 4'), findsNothing);
      expect(find.textContaining('giới hạn 8 quả'), findsOneWidget);
      await tester.ensureVisible(find.text('Quả 2 · Lớp 2'));
      await tester.tap(find.text('Quả 2 · Lớp 2'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('object-score-2-2')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('live displays each current fruit at $size', (tester) async {
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
      backend.stream.add({
        ...frameFixture(),
        'classId': 4,
        'objects': [objectFixture(), objectFixture(classId: 2)],
        'detectorMs': 12.0,
        'classificationMs': 30.0,
        'detectionLimitReached': true,
      });
      await tester.pumpAndSettle();
      expect(find.text('Quả 1 · Lớp 0'), findsOneWidget);
      expect(find.text('Quả 2 · Lớp 2'), findsOneWidget);
      expect(find.text('Lớp dự đoán: 4'), findsNothing);
      expect(find.textContaining('giới hạn 8 quả'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await backend.close();
      });
    });
  }

  // Explicitly empty detection results must suppress a legacy winning class/box.
  testWidgets('empty object list displays no mango despite legacy OK', (
    tester,
  ) async {
    final controller = MangoController()
      ..runtime = RuntimeInfo.fromMap(prepareFixture())
      ..result = AnalysisResult.fromMap({...resultFixture(), 'objects': []});
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Chưa tìm thấy quả xoài'), findsOneWidget);
    expect(find.text('Lớp dự đoán: 0'), findsNothing);
    expect(find.text('Quả 1 · Lớp 0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  // Labeling the classifier hash as the whole pipeline hides detector identity.
  testWidgets('dual-model details distinguish detector and grader provenance', (
    tester,
  ) async {
    final controller = MangoController()
      ..runtime = RuntimeInfo.fromMap({
        ...prepareFixture(),
        'modelName': 'SSDLite mango + MobileNetV3 grader',
        'modelBytes': 12000000,
        'modelSha256': 'grader-hash',
        'detectorModelSha256': 'detector-hash',
        'metrics': {
          'internal_test': {'accuracy': 0.95},
        },
      });
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Chi tiết model & thiết bị'));
    await tester.tap(find.text('Chi tiết model & thiết bị'));
    await tester.pumpAndSettle();
    expect(find.text('SHA-256 bộ phân lớp'), findsOneWidget);
    expect(find.text('SHA-256 bộ phát hiện'), findsOneWidget);
    expect(find.text('grader-hash'), findsOneWidget);
    expect(find.text('detector-hash'), findsOneWidget);
    expect(find.textContaining('Student lịch sử'), findsOneWidget);
    expect(
      find.textContaining('chưa đo độ chính xác bộ phát hiện'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // A retained legacy box must not mark a fruit after a NO_MANGO result.
  testWidgets('legacy no-mango result does not retain an overlay box', (
    tester,
  ) async {
    final controller = MangoController()
      ..runtime = RuntimeInfo.fromMap(prepareFixture())
      ..selectedPath = '/photo.jpg'
      ..result = AnalysisResult.fromMap({
        ...resultFixture(),
        'status': 'NO_MANGO',
      });
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MangoImagePreview>(find.byType(MangoImagePreview)).box,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
