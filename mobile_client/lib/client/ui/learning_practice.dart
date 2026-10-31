import 'package:flutter/material.dart';

import 'components.dart';

class LearningPractice extends StatefulWidget {
  const LearningPractice({
    super.key,
    required this.lessons,
    required this.zoom,
  });
  final List<Json> lessons;
  final double zoom;
  @override
  State<LearningPractice> createState() => _LearningPracticeState();
}

class _LearningPracticeState extends State<LearningPractice> {
  final _read = <String>{};
  final _answers = <int, int>{};
  static const _questions =
      <({String title, List<String> choices, int correct, String explanation})>[
        (
          title: '“Chưa xác định” cho biết điều gì?',
          choices: [
            'Chưa đủ tin cậy để gán giai đoạn.',
            'Quả chắc chắn đã hư.',
          ],
          correct: 0,
          explanation: 'Đây là trạng thái thiếu tự tin của mô hình; không phải nhãn xoài hư.',
        ),
        (
          title: 'Nhãn “Chín” có chứng nhận an toàn thực phẩm không?',
          choices: [
            'Có, có thể kết luận từ nhãn.',
            'Không. Đây chỉ là nhãn giai đoạn nguồn được dự đoán.',
          ],
          correct: 1,
          explanation: 'Nhãn nguồn không xác nhận chất lượng bên trong, vị ngọt hoặc an toàn thực phẩm.',
        ),
        (
          title: 'Có thể cộng ba số đếm rồi đổi thành kg hoặc tồn kho không?',
          choices: [
            'Không. Thấy đồng thời, track và lượt qua vạch là ba đại lượng khác nhau.',
            'Có, cộng lại là tổng quả duy nhất.',
          ],
          correct: 0,
          explanation: 'Đếm đối tượng và theo dõi không đo khối lượng hay bảo đảm số quả vật lý duy nhất.',
        ),
        (
          title: 'Không phát hiện xoài đạt ngưỡng có chứng minh ảnh không có xoài?',
          choices: [
            'Có, chắc chắn không có.',
            'Không. Mô hình vẫn có thể bỏ sót.',
          ],
          correct: 1,
          explanation: 'Kết quả chỉ cho biết không có đối tượng đạt ngưỡng trong lần phân tích, không chứng minh sự vắng mặt.',
        ),
      ];
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionTitle(
        'Học từng bước',
        subtitle: 'Đọc nội dung từ học liệu FruitVision, đánh dấu phần đã hiểu rồi tự kiểm tra cách diễn giải.',
      ),
      Text(
        '${_read.length}/${widget.lessons.length} mục đã đọc trong lần mở này',
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: widget.lessons.isEmpty
            ? 0
            : _read.length / widget.lessons.length,
      ),
      for (var index = 0; index < widget.lessons.length; index++)
        Card(
          child: ExpansionTile(
            key: ValueKey('lesson:${widget.lessons[index]['id']}'),
            initiallyExpanded: index == 0,
            leading: Icon(
              _read.contains(widget.lessons[index]['id'])
                  ? Icons.check_circle_outline
                  : Icons.menu_book_outlined,
            ),
            title: Text(
              '${index + 1}. ${value(widget.lessons[index], 'title')}',
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SelectableText(
                  value(widget.lessons[index], 'body'),
                  style: TextStyle(fontSize: 16 * widget.zoom, height: 1.5),
                ),
              ),
              CheckboxListTile(
                value: _read.contains(widget.lessons[index]['id']),
                onChanged: (checked) => setState(() {
                  final id = value(widget.lessons[index], 'id');
                  if (checked == true) {
                    _read.add(id);
                  } else {
                    _read.remove(id);
                  }
                }),
                title: const Text('Tôi đã đọc và hiểu mục này'),
              ),
            ],
          ),
        ),
      Card(
        child: ExpansionTile(
          title: const Text('Tự kiểm tra cách hiểu'),
          subtitle: const Text(
            'Không phải bài kiểm định chất lượng hoặc độ chín của quả.',
          ),
          children: [
            for (var question = 0; question < _questions.length; question++)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${question + 1}. ${_questions[question].title}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    RadioGroup<int>(
                      groupValue: _answers[question],
                      onChanged: (answer) {
                        if (answer != null) {
                          setState(() => _answers[question] = answer);
                        }
                      },
                      child: Column(
                        children: [
                          for (
                            var choice = 0;
                            choice < _questions[question].choices.length;
                            choice++
                          )
                            RadioListTile<int>(
                              value: choice,
                              title: Text(_questions[question].choices[choice]),
                            ),
                        ],
                      ),
                    ),
                    if (_answers.containsKey(question))
                      MessageBox(
                        '${_answers[question] == _questions[question].correct ? 'Đúng về cách hiểu. ' : 'Hãy đọc lại học liệu. '}${_questions[question].explanation}',
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}
