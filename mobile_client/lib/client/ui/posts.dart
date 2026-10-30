import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import 'chat.dart';
import 'components.dart';
import 'event_refresh.dart';
import 'visuals.dart';

String postStatusLabel(Object? status) => switch (status) {
  'AwaitingReview' => 'Chờ kiểm duyệt',
  'Published' => 'Đã công bố',
  'Rejected' => 'Bị từ chối',
  'Paused' => 'Tạm dừng',
  _ => status?.toString() ?? 'Chưa có trạng thái',
};
String productLabel(String code) => switch (code) {
  'mango' => 'Xoài',
  'orange' => 'Cam',
  'vegetable' => 'Rau ăn lá',
  _ => code,
};
String purposeLabel(Object? purpose) =>
    purpose == 'Demand' ? 'Nhu cầu thu mua' : 'Nguồn cung dự kiến';
String money(Object? input) {
  if (input is! num || !input.isFinite) return 'Chưa có dữ liệu';
  return input
      .toStringAsFixed(0)
      .replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (match) => '${match[1]}.',
      );
}

String askingPrice(Json post) {
  final low = post['priceMinVndPerKg'], high = post['priceMaxVndPerKg'];
  if (low == null && high == null) return 'Chưa có giá chào';
  if (low == null) return 'Đến ${money(high)} đ/kg';
  if (high == null) return 'Từ ${money(low)} đ/kg';
  return low == high
      ? '${money(low)} đ/kg'
      : '${money(low)}–${money(high)} đ/kg';
}

String availableDate(Object? value) {
  final date = DateTime.tryParse(value?.toString() ?? '');
  return date == null
      ? 'Chưa ghi ngày dự kiến'
      : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
}

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({super.key, required this.controller, required this.id});
  final SessionController controller;
  final String id;
  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();
  Json? _post;
  String? _error, _notice;
  bool _loading = true, _busy = false, _pending = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load({bool preserveError = false}) async {
    if (_busy) {
      _pending = true;
      return;
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      if (!preserveError) _error = null;
    });
    try {
      final post = await widget.controller.api.get(
        '/posts/${Uri.encodeComponent(widget.id)}',
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (_post == null ||
            ((post['revision'] as num?) ?? 0) >=
                ((_post!['revision'] as num?) ?? 0)) {
          _post = post;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = errorText(e);
        });
      }
    }
  }

  Future<void> _review(String status) async {
    if (_busy || !_form.currentState!.validate()) return;
    final revision = (_post?['revision'] as num?)?.toInt();
    if (revision == null || revision < 1) {
      setState(
        () => _error = 'Cần cập nhật phiên bản tin trước khi xét duyệt.',
      );
      return;
    }
    ++_generation;
    setState(() {
      _busy = true;
      _loading = false;
      _error = null;
      _notice = null;
    });
    try {
      final post = await widget.controller.api.post(
        '/admin/posts/${Uri.encodeComponent(widget.id)}/review',
        {
          'status': status,
          'reason': _reason.text.trim(),
          'expectedRevision': revision,
        },
      );
      if (!mounted) return;
      setState(() {
        _post = post;
        _busy = false;
        _notice = 'Đã cập nhật: ${postStatusLabel(post['status'])}.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
      if (e is ApiException && e.status == 409) {
        await _load(preserveError: true);
      }
    } finally {
      if (mounted && _pending) {
        _pending = false;
        await _load(preserveError: true);
      }
    }
  }

  Future<void> _contact() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final conversation = await widget.controller.api.post(
        '/posts/${Uri.encodeComponent(widget.id)}/conversations',
        {},
      );
      final id = value(conversation, 'id');
      if (id.isEmpty) {
        throw const ApiException('Máy chủ chưa trả về hội thoại. Hãy thử lại.');
      }
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            controller: widget.controller,
            id: id,
            title: value(conversation, 'title', 'Trao đổi về nông sản'),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.controller.user!;
    final post = _post;
    final author = post?['author'] is Map
        ? Map<String, dynamic>.from(post!['author'] as Map)
        : <String, dynamic>{};
    final own = author['id'] == user.id;
    final admin = user.isAdmin && user.isApproved;
    final canContact =
        user.isApproved &&
        !user.isAdmin &&
        !own &&
        post?['status'] == 'Published';
    return EventRefresh(
      targets: const {'PostChanged', 'PublishedPostChanged'},
      matches: (event) =>
          event.data['id'] == widget.id || event.data['postId'] == widget.id,
      onRefresh: _load,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chi tiết tin'),
          actions: [
            IconButton(
              tooltip: 'Cập nhật tin',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_loading) const LinearProgressIndicator(),
                  if (_error != null) ...[
                    MessageBox(_error!, error: true),
                    const SizedBox(height: 12),
                  ],
                  if (_notice != null) ...[
                    MessageBox(_notice!),
                    const SizedBox(height: 12),
                  ],
                  if (post != null) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusPill(postStatusLabel(post['status'])),
                        StatusPill(purposeLabel(post['purpose']), color: blue),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SectionTitle(
                      value(post, 'title'),
                      subtitle:
                          '${value(author, 'displayName')} · ${value(post, 'region', value(author, 'region'))}',
                    ),
                    DataCard(
                      children: [
                        Text(
                          '${value(post, 'estimatedQuantityKg')} kg dự kiến',
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: ink,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Nông sản: ${productLabel(value(post, 'productCode'))}',
                        ),
                        Text(
                          'Ngày dự kiến: ${availableDate(post['availableOn'])}',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Giá chào: ${askingPrice(post)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Số lượng là dự kiến. Giá do người đăng chào, chưa phải giá giao dịch hay tồn kho.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    if (canContact) ...[
                      FilledButton.icon(
                        onPressed: _busy ? null : _contact,
                        icon: const Icon(Icons.forum_outlined),
                        label: Text(
                          _busy ? 'Đang mở hội thoại…' : 'Liên hệ người đăng',
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (!user.isApproved)
                      const MessageBox(
                        'Hồ sơ cần được duyệt để liên hệ người đăng.',
                      ),
                    Text(
                      value(post, 'body'),
                      style: const TextStyle(height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Đăng lúc ${displayTime(post['createdAt'])}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if ((own || admin) &&
                        value(post, 'reviewReason').isNotEmpty) ...[
                      const SizedBox(height: 16),
                      MessageBox('Lý do xét duyệt: ${post['reviewReason']}'),
                    ],
                    if (admin) ...[
                      const Divider(height: 32),
                      const SectionTitle(
                        'Xét duyệt tin',
                        subtitle: 'Mỗi thao tác lưu lý do và kiểm tra phiên bản mới nhất trên máy chủ.',
                      ),
                      TextFormField(
                        controller: _reason,
                        enabled: !_busy,
                        minLines: 3,
                        maxLines: 5,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                          labelText: 'Lý do xét duyệt',
                        ),
                        validator: (text) => requiredText(text, min: 3),
                      ),
                      if (post['status'] == 'AwaitingReview' ||
                          post['status'] == 'Paused') ...[
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _busy || _loading
                              ? null
                              : () => _review('Published'),
                          child: const Text('Công bố tin'),
                        ),
                      ],
                      if (post['status'] == 'AwaitingReview') ...[
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: _busy || _loading
                              ? null
                              : () => _review('Rejected'),
                          child: const Text('Từ chối tin'),
                        ),
                      ],
                      if (post['status'] == 'Published') ...[
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: _busy || _loading
                              ? null
                              : () => _review('Paused'),
                          child: const Text('Tạm dừng tin'),
                        ),
                      ],
                      if (!{
                        'AwaitingReview',
                        'Published',
                        'Paused',
                      }.contains(post['status']))
                        const MessageBox(
                          'Tin này không có bước xét duyệt tiếp theo trong quy trình hiện tại.',
                        ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AdminPostsPage extends StatefulWidget {
  const AdminPostsPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<AdminPostsPage> createState() => _AdminPostsPageState();
}

class _AdminPostsPageState extends State<AdminPostsPage> {
  String _status = 'AwaitingReview';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Duyệt tin nông sản')),
    body: SafeArea(
      child: LiveApiList(
        api: widget.controller.api,
        path: '/admin/posts?status=$_status&limit=20',
        targets: const {'PostChanged'},
        empty: 'Chưa có tin trong trạng thái này.',
        header: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: DropdownButtonFormField<String>(
            initialValue: _status,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Trạng thái tin'),
            items: ['AwaitingReview', 'Published', 'Rejected', 'Paused']
                .map(
                  (status) => DropdownMenuItem(
                    value: status,
                    child: Text(postStatusLabel(status)),
                  ),
                )
                .toList(),
            onChanged: (status) {
              if (status != null) setState(() => _status = status);
            },
          ),
        ),
        itemBuilder: (post) =>
            PostCard(row: post, own: true, controller: widget.controller),
      ),
    ),
  );
}

class PostCard extends StatefulWidget {
  const PostCard({
    super.key,
    required this.row,
    this.own = false,
    this.controller,
  });
  final Json row;
  final SessionController? controller;
  final bool own;
  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final author = row['author'] is Map
        ? Map<String, dynamic>.from(row['author'] as Map)
        : <String, dynamic>{};
    final code = value(row, 'productCode');
    final (category, icon) = switch (code) {
      'mango' => ('Xoài', Icons.spa_outlined),
      'orange' => ('Cam', Icons.circle_outlined),
      'vegetable' => ('Rau ăn lá', Icons.grass_outlined),
      'banana' => ('Chuối', Icons.eco_outlined),
      'dragon-fruit' ||
      'dragonfruit' => ('Thanh long', Icons.local_florist_outlined),
      'leafy-vegetable' ||
      'leafy_vegetable' ||
      'vegetable_leafy' => ('Rau ăn lá', Icons.grass_outlined),
      '' => ('Tin dự kiến', Icons.edit_note),
      _ => (code, Icons.eco_outlined),
    };
    final status = switch (value(row, 'status')) {
      'Published' => 'Đã công bố',
      'AwaitingReview' => 'Chờ kiểm duyệt',
      'Rejected' => 'Chưa được công bố',
      'Paused' => 'Tạm dừng',
      final other => other,
    };
    return DataCard(
      onTap: widget.controller == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PostDetailPage(
                  controller: widget.controller!,
                  id: value(row, 'id'),
                ),
              ),
            ),
      children: [
        Row(
          children: [
            IconBadge(icon, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF146347),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!widget.own)
                    Text(
                      value(row, 'region', value(author, 'region')),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF526860),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.own)
              Flexible(
                child: StatusPill(
                  status,
                  color: status == 'Đã công bố'
                      ? const Color(0xFF146347)
                      : blue,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            StatusPill(
              purposeLabel(row['purpose']),
              color: row['purpose'] == 'Demand'
                  ? blue
                  : const Color(0xFF146347),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          value(row, 'title'),
          maxLines: _expanded ? null : 2,
          overflow: _expanded ? null : TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 17,
            height: 1.3,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
        if (!widget.own) ...[
          const SizedBox(height: 6),
          Text(
            value(author, 'displayName'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xFF526860)),
          ),
        ],
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F6F2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Semantics(
            label: 'Dự kiến: ${value(row, 'estimatedQuantityKg')} kg',
            excludeSemantics: true,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  value(row, 'estimatedQuantityKg'),
                  style: const TextStyle(
                    fontSize: 26,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
                const Text(
                  'kg dự kiến',
                  style: TextStyle(fontSize: 12, color: Color(0xFF526860)),
                ),
              ],
            ),
          ),
        ),
        if (value(row, 'body').isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            value(row, 'body'),
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            label: Text(_expanded ? 'Thu gọn' : 'Đọc tiếp'),
          ),
        ],
        if (row['priceMinVndPerKg'] != null || row['priceMaxVndPerKg'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              'Giá chào: ${askingPrice(row)}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        if (!widget.own)
          const Text(
            'Chưa xác nhận tồn kho · Chưa thể đặt hàng',
            style: TextStyle(fontSize: 11, color: Color(0xFF526860)),
          ),
      ],
    );
  }
}
