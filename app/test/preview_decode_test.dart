import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/image_preview.dart';

Future<File> _portraitFixture() async {
  final directory = await Directory.systemTemp.createTemp(
    'mango-preview-test-',
  );
  final file = File('${directory.path}/portrait.png');
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 32, 2048),
    Paint()..color = Colors.green,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 2048);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  await file.writeAsBytes(data!.buffer.asUint8List());
  return file;
}

void main() {
  // Width-only caching would keep a very tall image fully decoded in memory.
  testWidgets('preview decode bounds both dimensions for a very tall photo', (
    tester,
  ) async {
    final file = (await tester.runAsync(_portraitFixture))!;
    addTearDown(() => file.parent.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 300,
          child: MangoImagePreview(path: file.path, version: 1),
        ),
      ),
    );
    ui.Image? decoded;
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      decoded = tester.widget<RawImage>(find.byType(RawImage)).image;
      if (decoded != null) break;
    }
    expect(decoded, isNotNull);
    expect(decoded!.height, lessThanOrEqualTo(1080));
    expect(decoded.width, lessThanOrEqualTo(1080));
    await tester.pumpWidget(const SizedBox());
  });
}
