import 'package:flutter/material.dart';

import '../session.dart';
import 'components.dart';
import 'posts.dart';
import 'moderation.dart';
import 'admin_appointments.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.controller, required this.header});
  final SessionController controller;
  final Widget header;
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  Json? _stats;
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stats = await widget.controller.api.get('/admin/stats');
      if (mounted) setState(() => _stats = stats);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _loadStats,
    child: ListView(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        widget.header,
        if (widget.controller.user?.isAdmin == true)
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    AdminAppointmentsPage(controller: widget.controller),
              ),
            ),
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: const Text('Bổ nhiệm quản trị viên'),
          ),
        const SectionTitle(
          'Xét duyệt hoạt động',
          subtitle: 'Hồ sơ nâng vai trò, cơ sở hoạt động, bài chuyên môn và bài cộng đồng.',
        ),
        for (final kind in ReviewKind.values) ...[
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    ReviewListPage(controller: widget.controller, kind: kind),
              ),
            ),
            icon: Icon(
              kind == ReviewKind.roles
                  ? Icons.assignment_ind_outlined
                  : kind == ReviewKind.branches
                  ? Icons.storefront_outlined
                  : Icons.article_outlined,
            ),
            label: Text(kind.label),
          ),
          const SizedBox(height: 8),
        ],
        ExpansionTile(
          title: const Text('Nghiệp vụ trước đây'),
          children: [
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AdminPostsPage(controller: widget.controller),
                ),
              ),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Duyệt tin nông sản'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        DataCard(
          children: [
            Text(
              'Số liệu máy chủ',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) MessageBox(_error!, error: true),
            if (_stats != null) ...[
              Text('Tài khoản: ${_stats!['users']}'),
              Text('Tin kinh doanh: ${_stats!['posts']}'),
              Text('Tin nhắn: ${_stats!['messages']}'),
              Text('Phiên đang hoạt động: ${_stats!['activeSessions']}'),
            ],
            TextButton.icon(
              onPressed: _loading ? null : _loadStats,
              icon: const Icon(Icons.refresh),
              label: const Text('Cập nhật số liệu'),
            ),
          ],
        ),
      ],
    ),
  );
}
