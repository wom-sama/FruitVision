import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/image_preview.dart';
import 'package:mango_offline/inference.dart';
import 'package:mango_offline/fruit_tracking.dart';
import 'package:mango_offline/live_camera.dart';
import 'package:mango_offline/live_camera_page.dart';
import 'package:mango_offline/main.dart';
import 'package:mango_offline/scene_objects_view.dart';

import 'controller_test.dart' show prepareFixture, resultFixture;
import 'live_camera_page_test.dart' show FakePreview;
import 'live_camera_test.dart' show FakeCameraBackend, frameFixture;
import 'multi_object_test.dart' show objectFixture;

Map<String, Object?> unsupportedObject() => {
  'box': [0.1, 0.2, 0.8, 0.9],
  'detectionScore': 0.9,
  'species': 'apple',
  'status': 'UNSUPPORTED_SPECIES',
};

Map<String, Object?> ungradedScene(
  Map<String, Object?> base, {
  String status = 'UNSUPPORTED_SPECIES',
}) =>
    {
        ...base,
        'status': status,
        'species': status == 'NO_FRUIT' ? null : 'apple',
        'objects': status == 'NO_FRUIT' ? [] : [unsupportedObject()],
      }
      ..remove('classId')
      ..remove('probabilities');

void main() {
  test('generic fruit wire counts regions without invented ripeness votes', () {
    final object = SceneObject.fromMap({
      ...unsupportedObject(),
      'species': 'fruit',
      'gradeScheme': 'source_two_stage',
      'graded': false,
    });
    final tracker = FruitTracker();
    for (final time in [0, 100]) {
      tracker.update(time, [
        FruitObservation(box: object.box, species: object.species),
      ]);
    }
    expect(object.classId, isNull);
    expect(object.probabilities, isEmpty);
    expect(tracker.summary.confirmedCount, 1);
    expect(tracker.summary.ungradedCount, 1);
    expect(tracker.summary.gradeCounts, isEmpty);
    expect(
      () => SceneObject.fromMap({
        ...unsupportedObject(),
        'species': 'fruit',
        'gradeScheme': 'source_two_stage',
        'graded': false,
        'classId': 1,
        'probabilities': [.1, .9],
      }),
      throwsFormatException,
    );
  });
  test('direct detector has explicit two-stage wire contract, not five fake grades', () {
    final object = SceneObject.fromMap({
      ...objectFixture(),
      'gradeScheme': 'source_two_stage',
      'classId': 1,
      'probabilities': [.1, .9],
      'species': 'banana',
    });
    expect(object.probabilities, [.1, .9]);
    expect(object.classId, 1);
    expect(
      () => SceneObject.fromMap({
        ...objectFixture(),
        'gradeScheme': 'source_two_stage',
        'classId': 4,
        'probabilities': [.1, .9],
      }),
      throwsFormatException,
    );
    expect(
      () => SceneObject.fromMap({
        ...objectFixture(),
        'probabilities': [.1, .9],
      }),
      throwsFormatException,
    );
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vn.mangodemo/inference');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // Ignoring the new mode would promise mango grading for a banana-only model.
  testWidgets('classifier-only home declares its supported fruit', (
    tester,
  ) async {
    final controller = MangoController()
      ..runtime = RuntimeInfo.fromMap({
        ...prepareFixture(),
        'modelName': 'YOLOX fruit + banana skin-stage grader',
        'graderMode': 'classification_only',
        'supportedSpecies': ['banana'],
      });
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Fruit Offline'), findsOneWidget);
    expect(find.textContaining('Phân lớp vỏ hỗ trợ: Chuối'), findsOneWidget);
    expect(find.textContaining('xoài'), findsNothing);
    expect(find.text('Mango Offline'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // Dropping runtime metadata at navigation would restore the mango-only camera hint.
  testWidgets('classifier-only camera inherits supported fruit metadata', (
    tester,
  ) async {
    // This route test uses the non-Android preview; camera pixels stay native.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = MangoController()
      ..runtime = RuntimeInfo.fromMap({
        ...prepareFixture(),
        'graderMode': 'classification_only',
        'supportedSpecies': ['banana'],
      });
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    final cameraButton = find.widgetWithText(
      OutlinedButton,
      'Camera trực tiếp',
    );
    expect(tester.widget<OutlinedButton>(cameraButton).onPressed, isNotNull);
    await tester.ensureVisible(cameraButton);
    await tester.tap(cameraButton);
    await tester.pumpAndSettle();
    expect(find.byType(LiveCameraPage), findsOneWidget);
    expect(find.textContaining('Phân lớp vỏ hỗ trợ: Chuối'), findsOneWidget);
    expect(find.textContaining('Giữ các quả rõ trong khung'), findsOneWidget);
    expect(find.textContaining('xoài'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  // Accepting bad metadata would display unsupported species or select a wrong mode.
  for (final invalid in <Map<String, Object?>>[
    {'graderMode': 'unknown'},
    {'graderMode': 1},
    {'supportedSpecies': 'banana'},
    {
      'supportedSpecies': [''],
    },
    {
      'supportedSpecies': [1],
    },
  ]) {
    test('runtime rejects invalid species metadata $invalid', () {
      expect(
        () => RuntimeInfo.fromMap({...prepareFixture(), ...invalid}),
        throwsFormatException,
      );
    });
  }

  // Requiring a mango grade would reject an otherwise valid species detection.
  test('photo and live retain an unsupported object without grade fields', () {
    final photo = AnalysisResult.fromMap(ungradedScene(resultFixture()));
    final live = LiveFrame.fromMap(ungradedScene(frameFixture()));
    expect(photo.classId, isNull);
    expect(photo.probabilities, isEmpty);
    expect(photo.confidence, isNull);
    expect(live.classId, isNull);
    expect(live.confidence, isNull);
    for (final object in [
      photo.sceneObjects.single,
      live.sceneObjects.single,
    ]) {
      expect(object.box, const Rect.fromLTRB(0.1, 0.2, 0.8, 0.9));
      expect(object.classId, isNull);
      expect(object.probabilities, isEmpty);
      expect(object.confidence, isNull);
      expect(object.detectionScore, 0.9);
    }
  });

  // Treating NO_FRUIT as an invalid status would stop a healthy live session.
  test('photo and live accept no-fruit scenes without a grade', () {
    final photo = AnalysisResult.fromMap(
      ungradedScene(resultFixture(), status: 'NO_FRUIT'),
    );
    final live = LiveFrame.fromMap(
      ungradedScene(frameFixture(), status: 'NO_FRUIT'),
    );
    expect(photo.sceneObjects, isEmpty);
    expect(live.sceneObjects, isEmpty);
    expect(photo.classId, isNull);
    expect(live.probabilities, isEmpty);
  });

  // Accepting partial, contradictory or malformed grades could fabricate a class.
  for (final mutation in <Map<String, Object?>>[
    {'classId': 2},
    {
      'probabilities': [0.05, 0.05, 0.8, 0.05, 0.05],
    },
    {'graded': true},
    {'graded': 'false'},
    {'species': ''},
    {'species': 1},
  ]) {
    test('unsupported object rejects inconsistent data $mutation', () {
      expect(
        () => SceneObject.fromMap({...unsupportedObject(), ...mutation}),
        throwsFormatException,
      );
    });
  }

  // Mixed species must keep the supported crop's grade and leave apple ungraded.
  test(
    'mixed scene retains a supported crop grade beside unsupported fruit',
    () {
      final photo = AnalysisResult.fromMap({
        ...resultFixture(),
        'objects': [
          {...objectFixture(classId: 2), 'species': 'banana', 'graded': true},
          {...unsupportedObject(), 'graded': false},
        ],
      });
      expect(photo.sceneObjects.map((object) => object.classId), [2, null]);
      expect(photo.sceneObjects.map((object) => object.confidence), [
        0.8,
        null,
      ]);
    },
  );

  // An unsupported card must show the species without rendering grade bars.
  testWidgets('unsupported card shows species and no grade scores', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SceneObjectsView(
            objects: [SceneObject.fromMap(unsupportedObject())],
            classLabels: const [
              'Xanh',
              'Chuyển chín',
              'Chín',
              'Quá chín',
              'Hỏng',
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Táo'), findsOneWidget);
    expect(find.textContaining('chưa hỗ trợ phân lớp'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('Lớp'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // A photo overlay must draw an ungraded box without indexing a missing class.
  testWidgets('unsupported photo overlay paints its detection box', (
    tester,
  ) async {
    final painter = MangoObjectsPainter(
      objects: [SceneObject.fromMap(unsupportedObject())],
      imageSize: const Size(400, 200),
    );
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(400, 300));
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(400, 300));
    final rgba = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    // x=.1*400=40; y=150 lies on the box within the centered photo.
    expect(rgba!.getUint32((150 * 400 + 40) * 4) & 0xff, 0xff);
    image!.dispose();
    picture.dispose();
  });

  // Missing top-level grade must not abort image/video or report a mango class.
  for (final video in [false, true]) {
    testWidgets('${video ? 'video' : 'photo'} displays unsupported species', (
      tester,
    ) async {
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
            if (call.method == 'analyzeImage') {
              return ungradedScene(resultFixture());
            }
            if (call.method == 'nextVideoFrame') {
              if (frames == 2) return {'endOfStream': true, 'framesDecoded': 2};
              final index = frames++;
              return {
                ...ungradedScene(resultFixture()),
                'timestampMs': index * 250,
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
        () async =>
            MediaSelection('/fruit.${video ? 'mp4' : 'jpg'}', isVideo: video),
      );
      expect(controller.error, isNull);
      expect(controller.result?.sceneObjects, hasLength(1));
      if (video) {
        expect(controller.videoPoints, hasLength(2));
        expect(
          controller.videoPoints.every((point) => point.objectCount == 1),
          isTrue,
        );
        expect(controller.countSummary.ungradedCount, 1);
        expect(controller.videoReachedEnd, isTrue);
        expect(closes, 1);
      }
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.textContaining('Táo'), findsOneWidget);
      expect(find.textContaining('chưa hỗ trợ phân lớp'), findsOneWidget);
      expect(find.textContaining('Lớp dự đoán'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  // Ungraded event parsing must not stop the live camera or clear its detection.
  testWidgets('live unsupported frame stays running and displays species', (
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
    backend.stream.add(ungradedScene(frameFixture()));
    await tester.pumpAndSettle();
    expect(controller.phase, LiveCameraPhase.running);
    expect(controller.error, isNull);
    expect(find.textContaining('Táo'), findsOneWidget);
    expect(find.textContaining('chưa hỗ trợ phân lớp'), findsOneWidget);
    expect(find.textContaining('Lớp dự đoán'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await backend.close();
    });
  });

  // NO_FRUIT must use the broader species wording without changing NO_MANGO.
  testWidgets('no-fruit photo displays a generic empty result', (tester) async {
    final controller = MangoController()
      ..runtime = RuntimeInfo.fromMap(prepareFixture())
      ..result = AnalysisResult.fromMap(
        ungradedScene(resultFixture(), status: 'NO_FRUIT'),
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Chưa tìm thấy quả'), findsOneWidget);
    expect(find.textContaining('Lớp dự đoán'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
