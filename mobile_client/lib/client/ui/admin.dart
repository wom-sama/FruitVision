import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import 'components.dart';
import 'posts.dart';
import 'event_refresh.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.controller, required this.header});
  final SessionController controller;
  final Widget header;
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final _list = GlobalKey<ApiListState>();
  Json? _stats;
  String? _statsError;
  ApprovalStatus? _filter = ApprovalStatus.pending;
  bool _statsLoading = true;
  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() {
      _statsLoading = true;
      _statsError = null;
    });
    try {
      final stats = await widget.controller.api.get('/admin/stats');
      if (mounted) {
        setState(() {
          _stats = stats;
          _statsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statsError = errorText(e);
          _statsLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => LiveApiList(
    listKey: _list,
    api: widget.controller.api,
    targets: const {'PostChanged'},
    path:
        '/admin/applications?limit=50${_filter == null ? '' : '&status=${_filter!.wire}'}',
    empty: 'Không có hồ sơ trong trạng thái này.',
    header: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header,
        const SectionTitle(
          'Quản trị hồ sơ',
          subtitle: 'Xét duyệt thông tin và quản lý trạng thái tài khoản.',
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AdminPostsPage(controller: widget.controller),
            ),
          ),
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Duyệt tin nông sản'),
        ),
        const SizedBox(height: 16),
        DataCard(
          children: [
            Text(
              'Số liệu máy chủ',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_statsLoading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            if (_statsError != null) MessageBox(_statsError!, error: true),
            if (_stats != null) ...[
              const SizedBox(height: 8),
              Text(
                'Tài khoản: ${_stats!['users']} · Chờ duyệt: ${_stats!['pendingApplications']}',
              ),
              Text(
                'Tin dự kiến: ${_stats!['posts']} · Tin nhắn: ${_stats!['messages']}',
              ),
              Text('Phiên đang hoạt động: ${_stats!['activeSessions']}'),
            ],
            TextButton.icon(
              onPressed: _statsLoading ? null : _loadStats,
              icon: const Icon(Icons.refresh),
              label: const Text('Cập nhật số liệu'),
            ),
          ],
        ),
        DropdownButtonFormField<String>(
          initialValue: _filter?.wire ?? 'all',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Trạng thái hồ sơ'),
          items: [
            const DropdownMenuItem(value: 'all', child: Text('Tất cả hồ sơ')),
            ...ApprovalStatus.values.map(
              (s) => DropdownMenuItem(value: s.wire, child: Text(s.label)),
            ),
          ],
          onChanged: (v) => setState(
            () => _filter = v == 'all' ? null : ApprovalStatus.parse(v!),
          ),
        ),
        const SizedBox(height: 16),
      ],
    ),
    itemBuilder: (row) {
      final account = Account.fromJson(row);
      return DataCard(
        onTap: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => ApplicationPage(
                controller: widget.controller,
                account: account,
              ),
            ),
          );
          if (mounted && changed == true) {
            _list.currentState?.reload();
            _loadStats();
          }
        },
        children: [
          Text(
            account.displayName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text('${account.role.label} · ${account.region}'),
          Text(account.email),
          const SizedBox(height: 8),
          Text(
            '${account.approvalStatus.label}${account.isActive ? '' : ' · Đã khóa'}',
          ),
          const SizedBox(height: 8),
          const Text('Xem hồ sơ và xét duyệt →'),
        ],
      );
    },
  );
}

class ApplicationPage extends StatefulWidget {
  const ApplicationPage({
    super.key,
    required this.controller,
    required this.account,
  });
  final SessionController controller;
  final Account account;
  @override
  State<ApplicationPage> createState() => _ApplicationPageState();
}

class _ApplicationPageState extends State<ApplicationPage> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _act(String status, {bool accountStatus = false}) async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = Uri.encodeComponent(widget.account.id);
      await widget.controller.api.post(
        accountStatus
            ? '/admin/users/$id/status'
            : '/admin/applications/$id/review',
        accountStatus
            ? {
                'isActive': !widget.account.isActive,
                'reason': _reason.text.trim(),
              }
            : {'status': status, 'reason': _reason.text.trim()},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã cập nhật hồ sơ trên máy chủ.')),
      );
      Navigator.of(context).pop(true);
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
    final account = widget.account;
    return Scaffold(
      appBar: AppBar(title: const Text('Chi tiết hồ sơ')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionTitle(
                  account.displayName,
                  subtitle:
                      '${account.role.label} · ${account.approvalStatus.label}',
                ),
                DataCard(
                  children: [
                    Text(account.email),
                    const SizedBox(height: 8),
                    Text('Khu vực: ${account.region}'),
                    Text(
                      'Hoạt động: ${account.isActive ? 'Đang hoạt động' : 'Đã khóa'}',
                    ),
                    if (account.reviewReason != null) ...[
                      const SizedBox(height: 12),
                      Text('Lý do trước: ${account.reviewReason}'),
                    ],
                  ],
                ),
                if (_error != null) ...[
                  MessageBox(_error!, error: true),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _reason,
                  enabled: !_busy,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    labelText: 'Lý do / hướng dẫn cho người dùng',
                  ),
                  validator: (v) => requiredText(v, min: 3),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _act('Approved'),
                  icon: const Icon(Icons.check),
                  label: const Text('Phê duyệt hồ sơ'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : () => _act('NeedsInformation'),
                  child: const Text('Yêu cầu bổ sung'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : () => _act('Rejected'),
                  child: const Text('Từ chối hồ sơ'),
                ),
                const SizedBox(height: 24),
                const Divider(),
                TextButton.icon(
                  onPressed: _busy ? null : () => _act('', accountStatus: true),
                  icon: Icon(
                    account.isActive ? Icons.lock_outline : Icons.lock_open,
                  ),
                  label: Text(
                    account.isActive
                        ? 'Khóa tài khoản theo lý do trên'
                        : 'Mở khóa tài khoản theo lý do trên',
                  ),
                ),
                if (_busy) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
