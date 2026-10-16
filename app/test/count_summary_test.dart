import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mango_offline/count_summary_card.dart';
import 'package:mango_offline/fruit_tracking.dart';
import 'package:mango_offline/fruit_line_counter.dart';

void main() {
  testWidgets(
    'line-crossing JSON identifies count semantics and the configured line',
    (tester) async {
      String? report;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              report = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CountSummaryCard(
                summary: const FruitCountSummary(2, 2, {}),
                source: 'video',
                frameCount: 30,
                currentObjects: 5,
                lineCounter: FruitLineCounter(
                  axis: FruitLineAxis.vertical,
                  direction: FruitLineDirection.decreasing,
                  position: .4,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('lượt quả qua vạch'), findsOneWidget);
      await tester.tap(find.text('Sao chép báo cáo JSON'));
      await tester.pump();
      final json = jsonDecode(report!) as Map;
      expect(json['schema'], 'fruit-line-crossing-v1');
      expect(json['counting_mode'], 'line_crossings');
      expect(json['crossed_track_count'], 2);
      expect(json['line'], {
        'axis': 'vertical',
        'position': .4,
        'direction': 'decreasing',
        'hysteresis': .025,
      });
      expect(json['mass_kg'], isNull);
    },
  );
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('session statistics and JSON report fit $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? report;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              report = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CountSummaryCard(
                summary: FruitCountSummary(3, 1, {'banana:L1': 2}),
                source: 'video',
                frameCount: 10,
                currentObjects: 1,
                classLabels: ['Xanh / chưa chín', 'Chín'],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Quả · Chín'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.textContaining('Không quy đổi ra kg'), findsOneWidget);
      await tester.ensureVisible(find.text('Sao chép báo cáo JSON'));
      await tester.tap(find.text('Sao chép báo cáo JSON'));
      await tester.pump();
      final json = jsonDecode(report!) as Map;
      expect(json['confirmed_track_count'], 3);
      expect(json['mass_kg'], isNull);
      expect(json['grade_counts'], {'banana:L1': 2});
      expect(json['display_stage_counts'], {'fruit:L1': 2});
      expect(tester.takeException(), isNull);
    });
  }
}
