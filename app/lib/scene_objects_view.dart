import 'package:flutter/material.dart';

import 'inference.dart';

/// Numbers identify detections in this result only; they are not tracking IDs.
class SceneObjectsView extends StatelessWidget {
  const SceneObjectsView({
    super.key,
    required this.objects,
    this.classLabels = const [],
    this.detectionLimitReached = false,
    this.live = false,
    this.emptyLabel = 'Chưa tìm thấy quả xoài',
  });

  final List<SceneObject> objects;
  final List<String> classLabels;
  final bool detectionLimitReached;
  final bool live;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              objects.isEmpty
                  ? emptyLabel
                  : '${objects.length} quả trong ${live ? 'khung hình' : 'ảnh'}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            objects.isEmpty ? 'Thử đưa quả rõ hơn vào khung.' : 'Số thứ tự chỉ dùng trong khung hình hiện tại; thống kê phiên được theo dõi riêng.',
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF61748B),
            ),
          ),
          if (detectionLimitReached) ...[
            const SizedBox(height: 10),
            Text(
              'Đã đạt giới hạn ${classLabels.length == 2 ? 64 : 8} quả; có thể còn quả chưa được phân tích. Hãy chụp nhóm nhỏ hơn.',
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Color(0xFF996000),
              ),
            ),
          ],
          for (var index = 0; index < objects.length; index++)
            _ObjectScores(
              number: index + 1,
              object: objects[index],
              classLabels: classLabels,
            ),
          const SizedBox(height: 10),
          const Text(
            'Điểm của từng vùng quả là kết quả mô hình; không phải xác suất chất lượng hay độ an toàn.',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: Color(0xFF61748B),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ObjectScores extends StatelessWidget {
  const _ObjectScores({
    required this.number,
    required this.object,
    required this.classLabels,
  });
  final int number;
  final SceneObject object;
  final List<String> classLabels;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: ValueKey('scene-object-$number'),
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 10),
    initiallyExpanded: number == 1,
    title: Text(
      'Quả $number${classLabels.length == 2 || object.species == null ? '' : ' · ${speciesLabel(object.species!)}'}'
      '${object.graded
          ? object.status == AnalysisStatus.ok
                ? ' · Lớp ${object.classId}'
                : ' · Chưa đủ tin cậy'
          : ''}',
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    subtitle: Text(
      object.graded
          ? '${object.status == AnalysisStatus.uncertain ? 'Ứng viên lớp ${object.classId} • ' : ''}'
                'Điểm lớp ${(object.confidence! * 100).toStringAsFixed(1)}% • Phát hiện ${(object.detectionScore * 100).toStringAsFixed(1)}%'
                '${object.classId! < classLabels.length ? '\n${classLabels[object.classId!]}' : ''}'
          : 'Loài quả này chưa hỗ trợ phân lớp. • Phát hiện ${(object.detectionScore * 100).toStringAsFixed(1)}%',
      style: const TextStyle(fontSize: 11, height: 1.5),
    ),
    children: [
      for (var id = 0; object.graded && id < object.probabilities.length; id++)
        Padding(
          key: ValueKey('object-score-$number-$id'),
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Text('Lớp $id', style: const TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LinearProgressIndicator(
                  value: object.probabilities[id],
                  minHeight: 7,
                  color:
                      object.status == AnalysisStatus.ok && object.classId == id
                      ? Theme.of(context).colorScheme.primary
                      : const Color(0xFFA8BAD3),
                  backgroundColor: const Color(0xFFEAF0F8),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                child: Text(
                  '${(object.probabilities[id] * 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
