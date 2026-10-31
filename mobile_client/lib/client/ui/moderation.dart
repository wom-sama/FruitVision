import 'package:flutter/material.dart';

import '../session.dart';
import '../models.dart';
import 'components.dart';
import 'event_refresh.dart';
import 'role_applications.dart';
import 'api_photo.dart';

String applicationStatus(Object? status) => switch (status) {
  'Draft' => 'Bản nháp · Chưa gửi',
  'All' => 'Tất cả trạng thái',
  'Submitted' => 'Đã gửi xét duyệt',
  'Pending' || 'AwaitingReview' => 'Chờ xét duyệt',
  'Approved' => 'Đã chấp thuận',
  'Published' => 'Đã công bố',
  'Rejected' => 'Từ chối',
  'NeedsInformation' => 'Cần bổ sung',
  'Paused' => 'Tạm dừng',
  _ => 'Đang cập nhật',
};

enum ReviewKind {
  roles('role-applications', 'Duyệt nâng vai trò', [
    'Submitted',
    'NeedsInformation',
    'Approved',
    'Rejected',
    'Draft',
    'All',
  ]),
  branches('branches', 'Duyệt cơ sở', [
    'Pending',
    'NeedsInformation',
    'Approved',
    'Rejected',
  ]),
  articles('articles', 'Duyệt bài cộng đồng', [
    'AwaitingReview',
    'Published',
    'Rejected',
    'Paused',
  ]),
  professionalArticles('articles', 'Duyệt bài chuyên môn', [
    'AwaitingReview',
    'Published',
    'Rejected',
    'Paused',
  ]);

  const ReviewKind(this.path, this.label, this.statuses);
  final String path, label;
  final List<String> statuses;
  bool get isArticle => this == articles || this == professionalArticles;
  String get laneQuery => isArticle
      ? '&lane=${this == professionalArticles ? 'Professional' : 'Community'}'
      : '';
}

class ReviewListPage extends StatefulWidget {
  const ReviewListPage({
    super.key,
    required this.controller,
    required this.kind,
  });
  final SessionController controller;
  final ReviewKind kind;
  @override
  State<ReviewListPage> createState() => _ReviewListPageState();
}

class _ReviewListPageState extends State<ReviewListPage> {
  late String _status = widget.kind.statuses.first;
  final _list = GlobalKey<ApiListState>();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.kind.label)),
    body: SafeArea(
      child: LiveApiList(
        listKey: _list,
        api: widget.controller.api,
        path:
            '/admin/${widget.kind.path}?limit=20${_status == 'All' ? '' : '&status=$_status'}${widget.kind.laneQuery}',
        targets: const {
          'RoleApplicationChanged',
          'BranchChanged',
          'ArticleChanged',
        },
        empty: 'Không có hồ sơ trong trạng thái này.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.kind == ReviewKind.roles)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Danh sách chờ chỉ gồm hồ sơ đã bấm Gửi xét duyệt thành công. Lưu nháp hoặc thêm chứng từ chưa chuyển hồ sơ cho quản trị.',
                ),
              ),
            TextButton.icon(
              onPressed: () => _list.currentState?.reload(),
              icon: const Icon(Icons.refresh),
              label: const Text('Tải lại danh sách'),
            ),
            DropdownButtonFormField<String>(
              initialValue: _status,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Trạng thái'),
              items: widget.kind.statuses
                  .map(
                    (s) => DropdownMenuItem(
                      value: s,
                      child: Text(applicationStatus(s)),
                    ),
                  )
                  .toList(),
              onChanged: (s) {
                if (s != null) setState(() => _status = s);
              },
            ),
          ],
        ),
        itemBuilder: (row) => DataCard(
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => widget.kind == ReviewKind.roles
                    ? RoleApplicationPage(
                        controller: widget.controller,
                        id: value(row, 'id'),
                        admin: true,
                      )
                    : ReviewDetailPage(
                        controller: widget.controller,
                        kind: widget.kind,
                        id: value(row, 'id'),
                      ),
              ),
            );
            _list.currentState?.reload();
          },
          children: [
            if (row['applicant'] is Map)
              Text(
                value(
                  Map<String, dynamic>.from(row['applicant']),
                  'displayName',
                ),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            Text(
              widget.kind == ReviewKind.roles
                  ? roleName(row['requestedRole'])
                  : value(row, widget.kind.isArticle ? 'title' : 'name'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (value(row, 'organisationName').isNotEmpty)
              Text(value(row, 'organisationName')),
            Text(applicationStatus(row['status'])),
            Text(displayTime(row['submittedAt'] ?? row['createdAt'])),
          ],
        ),
      ),
    ),
  );
}

class ReviewActions extends StatefulWidget {
  const ReviewActions({
    super.key,
    required this.controller,
    required this.path,
    required this.data,
    required this.onUpdated,
    required this.reload,
    this.business = false,
  });
  final SessionController controller;
  final String path;
  final Json data;
  final ValueChanged<Json> onUpdated;
  final Future<void> Function() reload;
  final bool business;
  @override
  State<ReviewActions> createState() => _ReviewActionsState();
}

class _ReviewActionsState extends State<ReviewActions> {
  final _reason = TextEditingController(), _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _review(String status) async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.controller.api.post(
        '${widget.path}/review',
        {
          'status': status,
          'reason': _reason.text.trim(),
          'expectedRevision': widget.data['revision'],
        },
      );
      if (mounted) {
        widget.onUpdated(updated);
        _reason.clear();
      }
    } catch (e) {
      if (e is ApiException && e.status == 409) await widget.reload();
      if (mounted) {
        setState(
          () => _error = e is ApiException && e.status == 409
              ? 'Hồ sơ đã thay đổi. Đã tải lại; hãy kiểm tra trước khi xét duyệt.'
              : errorText(e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        const SectionTitle('Quyết định xét duyệt'),
        if (_error != null) MessageBox(_error!, error: true),
        TextFormField(
          controller: _reason,
          enabled: !_busy,
          minLines: 2,
          maxLines: 5,
          maxLength: 1000,
          decoration: const InputDecoration(labelText: 'Lý do xét duyệt'),
          validator: (v) => requiredText(v, min: 3),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _review(widget.business ? 'Published' : 'Approved'),
          child: Text(widget.business ? 'Công bố' : 'Chấp thuận'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _review(widget.business ? 'Paused' : 'NeedsInformation'),
          child: Text(widget.business ? 'Tạm dừng' : 'Yêu cầu bổ sung'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : () => _review('Rejected'),
          child: const Text('Từ chối'),
        ),
      ],
    ),
  );
}

class ReviewDetailPage extends StatefulWidget {
  const ReviewDetailPage({
    super.key,
    required this.controller,
    required this.kind,
    required this.id,
  });
  final SessionController controller;
  final ReviewKind kind;
  final String id;
  @override
  State<ReviewDetailPage> createState() => _ReviewDetailPageState();
}

class _ReviewDetailPageState extends State<ReviewDetailPage> {
  Json? _data;
  String? _error;
  String get path =>
      '/admin/${widget.kind.path}/${Uri.encodeComponent(widget.id)}';
  String get detailPath =>
      '/${widget.kind.path}/${Uri.encodeComponent(widget.id)}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.controller.api.get(detailPath);
      if (mounted) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.kind.label)),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) MessageBox(_error!, error: true),
          if (_data == null && _error == null) const LinearProgressIndicator(),
          if (_data case final data?) ...[
            SectionTitle(value(data, widget.kind.isArticle ? 'title' : 'name')),
            Text(applicationStatus(data['status'])),
            const SizedBox(height: 16),
            if (data['image'] is Map && widget.kind.isArticle)
              ApiPhoto(
                load: () => widget.controller.api.articleImageBytes(widget.id),
              ),
            if (widget.kind.isArticle)
              Text(value(data, 'body'))
            else ...[
              Text(value(data, 'region')),
              Text(value(data, 'street')),
              Text(value(data, 'phone')),
            ],
            if (data['author'] is Map)
              Text(
                value(Map<String, dynamic>.from(data['author']), 'displayName'),
              ),
            if (data['owner'] is Map)
              Text(
                value(Map<String, dynamic>.from(data['owner']), 'displayName'),
              ),
            Text(displayTime(data['createdAt'])),
            if (value(data, 'reviewReason').isNotEmpty)
              MessageBox(value(data, 'reviewReason')),
            ReviewActions(
              controller: widget.controller,
              path: path,
              data: data,
              onUpdated: (next) => setState(() => _data = next),
              reload: _load,
              business: widget.kind.isArticle,
            ),
          ],
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Tải lại hồ sơ'),
          ),
        ],
      ),
    ),
  );
}
