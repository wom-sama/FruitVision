import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/counting_line_controls.dart';
import 'package:mango_offline/fruit_line_counter.dart';

void main() {
  testWidgets('video line mode is optional and locked during processing', (
    tester,
  ) async {
    FruitLineCounter? chosen;
    Widget page(bool enabled) => MaterialApp(
      home: Scaffold(
        body: CountingLineControls(
          line: null,
          enabled: enabled,
          onChanged: (value) => chosen = value,
        ),
      ),
    );
    await tester.pumpWidget(page(true));
    await tester.tap(find.byType(Switch));
    expect(chosen?.axis, FruitLineAxis.vertical);
    expect(chosen?.direction, FruitLineDirection.increasing);
    chosen = null;
    await tester.pumpWidget(page(false));
    await tester.tap(find.byType(Switch));
    expect(chosen, isNull);
  });

  testWidgets(
    'line controls expose direction and position without a production guarantee',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CountingLineControls(
              line: FruitLineCounter(),
              enabled: true,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.byType(Slider), findsOneWidget);
      expect(find.textContaining('Camera cố định'), findsOneWidget);
      expect(find.textContaining('Đếm video qua vạch'), findsOneWidget);
    },
  );

  test(
    'line painter maps a line into the contained photo, not the blank bars',
    () {
      final vertical = countingLinePoints(
        FruitLineCounter(axis: FruitLineAxis.vertical, position: .25),
        const Size(200, 100),
        const Size(200, 200),
      );
      expect(vertical, [const Offset(50, 50), const Offset(50, 150)]);
      final horizontal = countingLinePoints(
        FruitLineCounter(
          position: .75,
          direction: FruitLineDirection.decreasing,
        ),
        const Size(100, 200),
        const Size(200, 200),
      );
      expect(horizontal, [const Offset(50, 150), const Offset(150, 150)]);
    },
  );
}
