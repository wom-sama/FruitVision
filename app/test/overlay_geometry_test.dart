import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/image_preview.dart';

void main() {
  // Stretching a landscape box across the whole portrait canvas would miss the photo.
  test('maps a landscape photo box inside vertical letterboxing', () {
    expect(
      mapNormalizedBox(
        const Rect.fromLTRB(.25, .25, .75, .75),
        const Size(400, 200),
        const Size(400, 300),
      ),
      const Rect.fromLTRB(100, 100, 300, 200),
    );
  });

  // Failing to add horizontal padding would shift a portrait photo's region left.
  test('maps a portrait photo box inside horizontal letterboxing', () {
    expect(
      mapNormalizedBox(
        const Rect.fromLTRB(0, 0, 1, 1),
        const Size(200, 400),
        const Size(400, 300),
      ),
      const Rect.fromLTRB(125, 0, 275, 300),
    );
  });
}
