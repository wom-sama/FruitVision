import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/image_preview.dart';
import 'package:mango_offline/inference.dart';

import 'multi_object_test.dart' show objectFixture;

Future<File> photoFixture(int width, int height) async {
  final directory = await Directory.systemTemp.createTemp(
    'mango-multi-overlay-',
  );
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.green,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${directory.path}/photo.png');
  await file.writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return file;
}

void main() {
  for (final dimensions in const [Size(400, 200), Size(200, 400)]) {
    // Drawing only the global box or stretching normalized regions misses a fruit.
    testWidgets('decoded $dimensions photo draws both crop regions', (
      tester,
    ) async {
      final file = (await tester.runAsync(
        () => photoFixture(dimensions.width.toInt(), dimensions.height.toInt()),
      ))!;
      addTearDown(() => file.parent.delete(recursive: true));
      final objects = [
        SceneObject.fromMap(objectFixture()),
        SceneObject.fromMap(objectFixture(classId: 2)),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: MangoImagePreview(
                path: file.path,
                version: 1,
                box: const Rect.fromLTRB(0, 0, 1, 1),
                label: 'global',
                objects: objects,
              ),
            ),
          ),
        ),
      );
      final multiPainter = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is MangoObjectsPainter,
      );
      for (
        var attempt = 0;
        attempt < 30 && multiPainter.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(multiPainter, findsOneWidget);
      final painter =
          tester.widget<CustomPaint>(multiPainter).painter!
              as MangoObjectsPainter;
      expect(painter.objects.map((object) => object.classId), [0, 2]);
      expect(painter.imageSize, dimensions);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is MangoBoxPainter,
        ),
        findsNothing,
      );
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(400, 300));
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(400, 300));
      final rgba = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      // Literal positions are hand-mapped through the centered photo letterbox.
      final x1 = dimensions.width == 400 ? 20 : 132;
      final x2 = dimensions.width == 400 ? 220 : 207;
      final pixel1 = rgba!.getUint32((150 * 400 + x1) * 4);
      final pixel2 = rgba.getUint32((150 * 400 + x2) * 4);
      expect(pixel1, 0xffd267ff);
      expect(pixel2, 0x95ccffff);
      image!.dispose();
      picture.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
