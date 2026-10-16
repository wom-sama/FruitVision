import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'fruit_tracking.dart';
import 'fruit_line_counter.dart';
import 'inference.dart';

/// Counts are tracks, not a claim of physical re-identification or measured mass.
class CountSummaryCard extends StatelessWidget {
  const CountSummaryCard({
    super.key,
    required this.summary,
    required this.source,
    required this.frameCount,
    required this.currentObjects,
    this.classLabels = const [],
    this.lineCounter,
  });
  final FruitCountSummary summary;
  final String source;
  final int frameCount, currentObjects;
  final List<String> classLabels;
  final FruitLineCounter? lineCounter;

  // The current two source stages have the same display meaning for both
  // supported fruits. Species predictions remain diagnostics, not UI claims.
  Map<String, int> get displayedCounts {
    if (classLabels.length != 2) return summary.gradeCounts;
    final counts = <String, int>{};
    for (final entry in summary.gradeCounts.entries) {
      final key = 'fruit:L${entry.key.split(':L').last}';
      counts.update(key, (n) => n + entry.value, ifAbsent: () => entry.value);
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lineCounter == null ? 'Thống kê phiên' : 'Thống kê qua vạch',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _number(
                '${summary.confirmedCount}',
                lineCounter == null ? 'lượt quả xác nhận' : 'lượt quả qua vạch',
              ),
              _number('$currentObjects', 'quả trong khung hiện tại'),
              _number('${summary.ungradedCount}', 'chưa rõ mức chín'),
            ],
          ),
          if (summary.gradeCounts.isNotEmpty) ...[
            const Divider(height: 28),
            for (final entry in displayedCounts.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(_label(entry.key))),
                    Text(
                      '${entry.value} quả',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Text(
            lineCounter == null
                ? 'Xác nhận qua ít nhất 2 khung. Không cộng lại từng khung. Quả rời rồi quay lại, che lâu hoặc camera di chuyển có thể gây đếm trùng/bỏ sót. Không quy đổi ra kg.'
                : 'Camera phải cố định. ID cần được xác nhận ở cả hai phía và đi đúng chiều mới được cộng một lần. Đổi ID, che khuất hoặc quay lại vẫn có thể đếm sai. Không quy đổi ra kg.',
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF61748B),
            ),
          ),
          TextButton.icon(
            onPressed: frameCount == 0
                ? null
                : () async {
                    final report = const JsonEncoder.withIndent('  ').convert({
                      'schema': lineCounter == null
                          ? 'fruit-tracking-v1'
                          : 'fruit-line-crossing-v1',
                      'counting_mode': lineCounter == null
                          ? 'observed_tracks'
                          : 'line_crossings',
                      'source': source,
                      'frames_processed': frameCount,
                      'confirmed_track_count': summary.confirmedCount,
                      if (lineCounter != null) ...{
                        'crossed_track_count': summary.confirmedCount,
                        'line': {
                          'axis': lineCounter!.axis.name,
                          'position': lineCounter!.position,
                          'direction': lineCounter!.direction.name,
                          'hysteresis': lineCounter!.hysteresis,
                        },
                      },
                      'ungraded_tracks': summary.ungradedCount,
                      'grade_counts': summary.gradeCounts,
                      'display_stage_counts': displayedCounts,
                      'species_labels_are_diagnostic_only':
                          classLabels.length == 2,
                      'mass_kg': null,
                      'limitations': 'Geometry tracking; re-entry/occlusion/moving camera may miscount. Not food-safety evaluation.',
                    });
                    await Clipboard.setData(ClipboardData(text: report));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Đã sao chép báo cáo JSON.'),
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Sao chép báo cáo JSON'),
          ),
        ],
      ),
    ),
  );

  Widget _number(String value, String caption) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w800,
          color: Color(0xFF0754AA),
        ),
      ),
      Text(caption, style: const TextStyle(fontSize: 12)),
    ],
  );

  String _label(String key) {
    final parts = key.split(':L');
    final species = parts.first;
    final index = parts.length == 2 ? int.tryParse(parts.last) : null;
    final label = index != null && index < classLabels.length
        ? classLabels[index]
        : 'Mức ${index ?? "?"}';
    return '${species == "fruit" ? "Quả" : speciesLabel(species)} · $label';
  }
}
