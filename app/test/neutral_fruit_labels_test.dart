import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/count_summary_card.dart';
import 'package:mango_offline/fruit_tracking.dart';

void main() {
  testWidgets('shared two-stage summary combines uncertain species names without losing counts', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CountSummaryCard(
      summary: FruitCountSummary(4, 1, {'banana:L1': 1, 'mango:L1': 1, 'mango:L0': 1}),
      source: 'video', frameCount: 10, currentObjects: 2,
      classLabels: ['Xanh / chưa chín', 'Chín'],
    ))));
    expect(find.text('Quả · Chín'), findsOneWidget);
    expect(find.text('2 quả'), findsOneWidget);
    expect(find.text('Quả · Xanh / chưa chín'), findsOneWidget);
    expect(find.textContaining('Chuối'), findsNothing);
    expect(find.textContaining('Xoài'), findsNothing);
  });
}
