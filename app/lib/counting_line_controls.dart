import 'package:flutter/material.dart';

import 'fruit_line_counter.dart';

/// Configure before selecting a video; changing the line starts a fresh count.
class CountingLineControls extends StatelessWidget {
  const CountingLineControls({
    super.key,
    required this.line,
    required this.enabled,
    required this.onChanged,
  });
  final FruitLineCounter? line;
  final bool enabled;
  final ValueChanged<FruitLineCounter?> onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Đếm video qua vạch băng chuyền'),
            subtitle: const Text(
              'Camera cố định. Chọn trước khi mở video; đổi vạch sẽ xóa thống kê phiên.',
            ),
            value: line != null,
            onChanged: !enabled
                ? null
                : (value) => onChanged(
                    value
                        ? FruitLineCounter(axis: FruitLineAxis.vertical)
                        : null,
                  ),
          ),
          if (line != null) ...[
            DropdownButtonFormField<int>(
              key: ValueKey('${line!.axis.name}/${line!.direction.name}'),
              initialValue: line!.axis.index * 2 + line!.direction.index,
              decoration: const InputDecoration(
                labelText: 'Chiều quả đi qua vạch',
              ),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Trên → dưới')),
                DropdownMenuItem(value: 1, child: Text('Dưới → trên')),
                DropdownMenuItem(value: 2, child: Text('Trái → phải')),
                DropdownMenuItem(value: 3, child: Text('Phải → trái')),
              ],
              onChanged: !enabled
                  ? null
                  : (value) {
                      if (value != null) {
                        onChanged(
                          FruitLineCounter(
                            axis: FruitLineAxis.values[value ~/ 2],
                            direction: FruitLineDirection.values[value % 2],
                            position: line!.position,
                          ),
                        );
                      }
                    },
            ),
            Text('Vị trí vạch: ${(line!.position * 100).round()}% khung hình'),
            Slider(
              value: line!.position,
              min: .1,
              max: .9,
              divisions: 16,
              label: '${(line!.position * 100).round()}%',
              onChanged: !enabled
                  ? null
                  : (value) => onChanged(
                      FruitLineCounter(
                        axis: line!.axis,
                        direction: line!.direction,
                        position: value,
                      ),
                    ),
            ),
            const Text(
              'Chỉ cộng ID đi đúng chiều và được xác nhận ở cả hai phía. Che lâu, đổi ID hoặc camera di chuyển vẫn có thể gây sai số.',
              style: TextStyle(fontSize: 12, color: Color(0xFF61748B)),
            ),
          ],
        ],
      ),
    ),
  );
}

List<Offset> countingLinePoints(
  FruitLineCounter line,
  Size imageSize,
  Size canvasSize,
) {
  final fit = applyBoxFit(BoxFit.contain, imageSize, canvasSize);
  final photo = Alignment.center.inscribe(
    fit.destination,
    Offset.zero & canvasSize,
  );
  return line.axis == FruitLineAxis.vertical
      ? [
          Offset(photo.left + line.position * photo.width, photo.top),
          Offset(photo.left + line.position * photo.width, photo.bottom),
        ]
      : [
          Offset(photo.left, photo.top + line.position * photo.height),
          Offset(photo.right, photo.top + line.position * photo.height),
        ];
}

class CountingLinePainter extends CustomPainter {
  const CountingLinePainter({required this.line, required this.imageSize});
  final FruitLineCounter line;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final points = countingLinePoints(line, imageSize, size);
    final paint = Paint()
      ..color = const Color(0xFFFFD230)
      ..strokeWidth = 3;
    canvas.drawLine(points[0], points[1], paint);
    final center = (points[0] + points[1]) / 2;
    final sign = line.direction == FruitLineDirection.increasing ? 1.0 : -1.0;
    final vector = line.axis == FruitLineAxis.vertical
        ? Offset(18 * sign, 0)
        : Offset(0, 18 * sign);
    final normal = Offset(-vector.dy, vector.dx) / 3;
    canvas.drawLine(center - vector, center + vector, paint);
    canvas.drawLine(center + vector, center + vector / 2 + normal, paint);
    canvas.drawLine(center + vector, center + vector / 2 - normal, paint);
  }

  @override
  bool shouldRepaint(CountingLinePainter oldDelegate) =>
      oldDelegate.imageSize != imageSize || oldDelegate.line != line;
}
