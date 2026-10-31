import 'package:flutter/material.dart';

import '../session.dart';
import 'components.dart';
import 'publishing.dart';
import 'learning_practice.dart';

class MangoLearningPage extends StatefulWidget {
  const MangoLearningPage({
    super.key,
    required this.controller,
    required this.header,
  });
  final SessionController controller;
  final Widget header;
  @override
  State<MangoLearningPage> createState() => _MangoLearningPageState();
}

class _MangoLearningPageState extends State<MangoLearningPage> {
  Json? _content;
  String? _error;
  bool _loading = false;
  double _zoom = 1;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    if (widget.controller.user!.isApproved) _load();
  }

  Future<void> _load() async {
    if (widget.controller.user?.isApproved != true) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final content = await widget.controller.api.get('/learning/mango');
      if (!mounted || generation != _generation) return;
      if (content['schemaVersion'] != 1 || content['productCode'] != 'mango') {
        throw const FormatException(
          'Nội dung học về xoài không đúng định dạng.',
        );
      }
      setState(() => _content = content);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _content;
    final scope = content?['modelScope'] is Map
        ? Map<String, dynamic>.from(content!['modelScope'])
        : <String, dynamic>{};
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          widget.header,
          const Icon(
            Icons.menu_book_outlined,
            size: 48,
            color: Color(0xFF146347),
          ),
          const SizedBox(height: 16),
          SectionTitle(
            content == null ? 'Hiểu về xoài' : value(content, 'title'),
            subtitle: content == null
                ? 'Kiến thức về xoài và cách hiểu kết quả nhận diện.'
                : value(content, 'summary'),
          ),
          if (!widget.controller.user!.isApproved)
            const MessageBox(
              'Tài khoản cần được duyệt và đang hoạt động để xem nội dung này.',
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            MessageBox(
              _error!,
              error: true,
              child: TextButton(
                onPressed: _loading ? null : _load,
                child: const Text('Tải lại kiến thức'),
              ),
            ),
          if (content != null) ...[
            if (!widget.controller.user!.isAdmin)
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PublicationEditor(
                      controller: widget.controller,
                      article: true,
                    ),
                  ),
                ),
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  widget.controller.user!.canSell
                      ? 'Viết bài chuyên môn'
                      : 'Chia sẻ bài và ảnh cộng đồng',
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                const Text('Cỡ chữ nội dung'),
                IconButton(
                  tooltip: 'Thu nhỏ chữ',
                  onPressed: _zoom <= 1
                      ? null
                      : () =>
                            setState(() => _zoom = (_zoom - .2).clamp(1, 1.8)),
                  icon: const Icon(Icons.text_decrease),
                ),
                Text('${(_zoom * 100).round()}%'),
                IconButton(
                  tooltip: 'Phóng to chữ',
                  onPressed: _zoom >= 1.8
                      ? null
                      : () =>
                            setState(() => _zoom = (_zoom + .2).clamp(1, 1.8)),
                  icon: const Icon(Icons.text_increase),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...rows({'items': scope['stages']}).map(
              (stage) => DataCard(
                children: [
                  Text(
                    value(stage, 'label'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    value(stage, 'description'),
                    style: TextStyle(fontSize: 16 * _zoom, height: 1.5),
                  ),
                ],
              ),
            ),
            LearningPractice(
              lessons: rows({'items': content['sections']}),
              zoom: _zoom,
            ),
            const SizedBox(height: 16),
            const SectionTitle('Giới hạn cần hiểu'),
            ...(content['limitations'] as List? ?? []).whereType<String>().map(
              (text) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '• $text',
                  style: TextStyle(fontSize: 16 * _zoom, height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ArticlesPage(
                    controller: widget.controller,
                    lane: 'Professional',
                  ),
                ),
              ),
              icon: const Icon(Icons.school_outlined),
              label: const Text('Đọc bài chuyên môn về xoài'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ArticlesPage(controller: widget.controller),
                ),
              ),
              icon: const Icon(Icons.groups_outlined),
              label: const Text('Đọc chia sẻ cộng đồng'),
            ),
          ],
        ],
      ),
    );
  }
}
