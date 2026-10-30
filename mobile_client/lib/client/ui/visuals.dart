import 'package:flutter/material.dart';

const ink = Color(0xFF17352A);
const blue = Color(0xFF2C5F83);

class IconBadge extends StatelessWidget {
  const IconBadge(
    this.icon, {
    super.key,
    this.color = const Color(0xFF146347),
    this.size = 44,
  });
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, color: color, size: size * .52),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill(
    this.label, {
    super.key,
    this.color = const Color(0xFF146347),
    this.icon,
  });
  final String label;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class CountMetric extends StatelessWidget {
  const CountMetric({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.primary = false,
    this.semanticLabel,
  });
  final String label, value;
  final IconData icon;
  final bool primary;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel ?? '$label: $value',
    excludeSemantics: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: primary ? const Color(0xFFE5F2ED) : const Color(0xFFF0F5F8),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: primary ? const Color(0xFF146347) : blue,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: primary ? const Color(0xFF146347) : blue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: primary ? 48 : 34,
              height: 1.05,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
        ],
      ),
    ),
  );
}

Color gradeColor(String label) => label.toLowerCase().contains('chưa xác định')
    ? const Color(0xFF7B8B97)
    : label.toLowerCase().contains('xanh')
    ? const Color(0xFF238466)
    : const Color(0xFFC57835);

class GradeSummary extends StatelessWidget {
  const GradeSummary({super.key, required this.counts, this.caption});
  final Map<String, dynamic> counts;
  final String? caption;
  @override
  Widget build(BuildContext context) {
    final values = <String, int>{
      for (final entry in counts.entries)
        if (entry.value is num &&
            (entry.value as num).isFinite &&
            (entry.value as num) >= 0)
          entry.key: (entry.value as num).toInt(),
    };
    final total = values.values.fold<int>(0, (sum, value) => sum + value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Giai đoạn theo mô hình',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (caption != null) ...[
          const SizedBox(height: 5),
          Text(
            caption!,
            style: const TextStyle(fontSize: 12, color: Color(0xFF526860)),
          ),
        ],
        const SizedBox(height: 12),
        if (total > 0)
          Semantics(
            label: 'Tỷ lệ phân loại từ $total kết quả',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  for (final entry in values.entries)
                    if (entry.value > 0)
                      Expanded(
                        flex: entry.value,
                        child: Container(
                          height: 12,
                          color: gradeColor(entry.key),
                        ),
                      ),
                ],
              ),
            ),
          ),
        if (total == 0) const Text('Chưa có phân loại.'),
        const SizedBox(height: 10),
        for (final entry in values.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: gradeColor(entry.key),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(entry.key, style: const TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                Text(
                  '${entry.value}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 42,
                  child: Text(
                    '${total == 0 ? 0 : (entry.value * 100 / total).round()}%',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF526860),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
