import 'dart:math';

import 'package:flutter/material.dart';

import '../session.dart';
import '../api.dart';
import 'components.dart';
import 'event_refresh.dart';

class ArticleEngagement extends StatefulWidget {
  const ArticleEngagement({
    super.key,
    required this.controller,
    required this.articleId,
  });
  final SessionController controller;
  final String articleId;
  @override
  State<ArticleEngagement> createState() => _ArticleEngagementState();
}

class _ArticleEngagementState extends State<ArticleEngagement> {
  final _comment = TextEditingController();
  final _random = Random.secure();
  Json? _counts;
  List<Json> _comments = [];
  String? _next, _error, _pendingId, _pendingBody;
  bool _loading = false, _busy = false, _dirty = false;
  int _generation = 0;
  String get _path => '/articles/${Uri.encodeComponent(widget.articleId)}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _comment.dispose();
    super.dispose();
  }

  String _newId() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _load({bool more = false}) async {
    if (_loading || _busy) {
      _dirty = true;
      return;
    }
    if (more && _next == null) return;
    final generation = ++_generation;
    setState(() => _loading = true);
    try {
      final responses = await Future.wait([
        widget.controller.api.get('$_path/likes'),
        widget.controller.api.get(
          '$_path/comments?limit=20${more ? '&after=${Uri.encodeQueryComponent(_next!)}' : ''}',
        ),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _counts = responses[0];
        final incoming = rows(responses[1]);
        _comments = more
            ? [
                ..._comments,
                ...incoming.where(
                  (row) =>
                      !_comments.any((existing) => existing['id'] == row['id']),
                ),
              ]
            : incoming;
        _next = responses[1]['next'] as String?;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        if (_dirty) {
          _dirty = false;
          _load();
        }
      }
    }
  }

  Future<void> _like() async {
    if (_busy || _counts == null) return;
    setState(() => _busy = true);
    try {
      final counts = await widget.controller.api.put('$_path/like', {
        'liked': _counts!['liked'] != true,
      });
      if (mounted) setState(() => _counts = counts);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_dirty) {
          _dirty = false;
          _load();
        }
      }
    }
  }

  Future<void> _send() async {
    if (_busy) return;
    final body = _pendingBody ?? _comment.text.trim();
    if (body.length < 2 || body.length > 1000) {
      setState(() => _error = 'Nhập bình luận từ 2 đến 1000 ký tự.');
      return;
    }
    _pendingId ??= _newId();
    _pendingBody ??= body;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.controller.api.post('$_path/comments', {
        'body': _pendingBody,
        'clientCommentId': _pendingId,
      });
      if (!mounted) return;
      if (value(created, 'id').isEmpty) {
        throw const ApiException('Bình luận chưa được xác nhận.');
      }
      setState(() {
        _pendingId = null;
        _pendingBody = null;
        _comment.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_pendingId == null || _dirty) {
          _dirty = false;
          await _load();
        }
      }
    }
  }

  Future<void> _delete(Json row) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa bình luận?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.controller.api.delete(
        '$_path/comments/${Uri.encodeComponent(value(row, 'id'))}',
      );
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) => EventRefresh(
    targets: const {'ArticleChanged', 'PublishedArticleChanged'},
    matches: (event) => event.data['id'] == widget.articleId,
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        if (_counts case final counts?)
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _busy || !widget.controller.user!.isApproved
                    ? null
                    : _like,
                icon: Icon(
                  counts['liked'] == true
                      ? Icons.favorite
                      : Icons.favorite_border,
                ),
                label: Text(
                  '${counts['liked'] == true ? 'Đã thích' : 'Thích'} · ${counts['likeCount']}',
                ),
              ),
              Text('${counts['commentCount']} bình luận'),
            ],
          ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) MessageBox(_error!, error: true),
        if (widget.controller.user!.isApproved) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: _comment,
            enabled: !_busy && _pendingId == null,
            minLines: 2,
            maxLines: 5,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: 'Viết bình luận'),
          ),
          if (_pendingId == null)
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.send),
              label: const Text('Gửi bình luận'),
            )
          else
            MessageBox(
              'Bình luận đang chờ xác nhận. Thử lại dùng cùng mã và nội dung.',
              child: Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _send,
                    child: const Text('Thử gửi lại'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _pendingId = null;
                            _pendingBody = null;
                          }),
                    child: const Text('Cho phép sửa nội dung'),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 16),
        ..._comments.map((row) {
          final author = row['author'] is Map
              ? Map<String, dynamic>.from(row['author'])
              : <String, dynamic>{};
          return DataCard(
            children: [
              Text(
                value(author, 'displayName'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(value(row, 'body')),
              Text(displayTime(row['createdAt'])),
              if (row['canDelete'] == true)
                TextButton(
                  onPressed: _busy ? null : () => _delete(row),
                  child: const Text('Xóa bình luận'),
                ),
            ],
          );
        }),
        if (_counts != null && _comments.isEmpty && !_loading)
          const Text(
            'Chưa có bình luận. Chia sẻ quan sát hoặc câu hỏi của bạn.',
          ),
        if (_next != null && _comments.length < 100)
          TextButton(
            onPressed: _loading ? null : () => _load(more: true),
            child: const Text('Xem bình luận trước'),
          ),
      ],
    ),
  );
}
