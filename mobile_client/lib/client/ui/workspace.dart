import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../inbox.dart';
import '../realtime.dart';
import 'admin.dart';
import 'ai.dart';
import 'chat.dart';
import 'components.dart';
import 'forms.dart';
import 'realtime_scope.dart';
import 'visuals.dart';
import 'posts.dart';
import 'event_refresh.dart';
import 'mango_learning.dart';
import 'update_page.dart';
import 'role_applications.dart';
import 'publishing.dart';
import 'security.dart';
import 'inbox_notifications.dart';
import 'profile.dart';
export 'posts.dart' show PostCard;

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.controller});
  final SessionController controller;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final _notificationMessenger = GlobalKey<ScaffoldMessengerState>();
  int _tab = 0;
  UserRole? _lastRole;
  InboxController? _inbox;
  RealtimeClient? _inboxHub;
  String? _inboxIdentity;
  int _lastUnread = 0;
  bool _hadInbox = false;

  void _configureInbox() {
    final c = widget.controller;
    final hub = RealtimeScope.maybeOf(context);
    final identity = '${c.api.baseUrl}:${c.user?.id}:${c.user?.role.wire}';
    if (_inbox != null && identity == _inboxIdentity && hub == _inboxHub) {
      return;
    }
    _inbox?.removeListener(_inboxChanged);
    _inbox?.dispose();
    _inboxIdentity = identity;
    _inboxHub = hub;
    _lastUnread = 0;
    _hadInbox = false;
    _inbox = InboxController(session: c, realtime: hub)
      ..addListener(_inboxChanged);
  }

  void _inboxChanged() {
    if (!mounted) return;
    final inbox = _inbox!;
    final newMessage =
        _hadInbox &&
        !inbox.loading &&
        inbox.error == null &&
        inbox.unreadTotal > _lastUnread;
    if (!inbox.loading && inbox.error == null) {
      _hadInbox = true;
      _lastUnread = inbox.unreadTotal;
    }
    setState(() {});
    if (newMessage && ModalRoute.of(context)?.isCurrent == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        final messenger = _notificationMessenger.currentState;
        if (messenger == null) return;
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            showCloseIcon: true,
            content: const Text('Bạn có tin nhắn mới'),
            action: SnackBarAction(
              label: 'Xem',
              onPressed: () {
                if (mounted) {
                  setState(
                    () =>
                        _tab = widget.controller.user?.isAdmin == true ? 1 : 2,
                  );
                }
              },
            ),
          ),
        );
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureInbox();
  }

  @override
  void dispose() {
    _inbox?.removeListener(_inboxChanged);
    _inbox?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, user = c.user!;
    _configureInbox();
    final seller =
        user.role == UserRole.producer || user.role == UserRole.trader;
    final admin = user.isAdmin;
    if (_lastRole != user.role) {
      _tab = 0;
      _lastRole = user.role;
    }
    final entries = <(String, IconData)>[
      if (admin)
        ('Xét duyệt', Icons.fact_check_outlined)
      else if (seller)
        ('AI xoài', Icons.auto_awesome_outlined)
      else
        ('Học về xoài', Icons.menu_book_outlined),
      if (seller) ('Kiến thức', Icons.menu_book_outlined),
      if (user.role == UserRole.consumer) ('Cộng đồng', Icons.groups_outlined),
      ('Tin nhắn', Icons.chat_bubble_outline),
      ('Tài khoản', Icons.person_outline),
    ];
    final tab = _tab.clamp(0, entries.length - 1);
    final status = ProfileBanner(controller: c);
    final conversations = user.isApproved
        ? ConversationList(
            controller: c,
            header: const SizedBox.shrink(),
            inbox: _inbox,
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              status,
              const MessageBox(
                'Tài khoản cần được duyệt và đang hoạt động để dùng hội thoại.',
              ),
            ],
          );
    final pages = <Widget>[
      if (admin)
        AdminPage(controller: c, header: status)
      else if (seller)
        AiPage(controller: c, header: status)
      else
        MangoLearningPage(controller: c, header: status),
      if (seller) MangoLearningPage(controller: c, header: status),
      if (user.role == UserRole.consumer)
        ArticlesPage(controller: c, embedded: true, header: status),
      conversations,
      AccountPage(controller: c, header: status),
    ];
    return ScaffoldMessenger(
      key: _notificationMessenger,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('FruitVision · Xoài'),
          actions: [
            if (user.isApproved)
              IconButton(
                tooltip: 'Tin nhắn chưa đọc',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        InboxNotificationsPage(controller: c, inbox: _inbox!),
                  ),
                ),
                icon: Badge.count(
                  count: _inbox?.unreadTotal ?? 0,
                  isLabelVisible: (_inbox?.unreadTotal ?? 0) > 0,
                  child: const Icon(Icons.notifications_none),
                ),
              ),
            if (!user.isAdmin && user.isApproved)
              IconButton(
                tooltip: user.canSell
                    ? 'Viết bài chuyên môn'
                    : 'Viết bài cộng đồng',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        PublicationEditor(controller: c, article: true),
                  ),
                ),
                icon: const Icon(Icons.edit_square),
              ),
            IconButton(
              tooltip: 'Làm mới hồ sơ',
              onPressed: c.busy ? null : c.refreshProfile,
              icon: const Icon(Icons.sync),
            ),
          ],
        ),
        body: SafeArea(
          child: KeyedSubtree(
            key: ValueKey('${user.role.wire}:${user.isApproved}'),
            child: IndexedStack(index: tab, children: pages),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (index) => setState(() => _tab = index),
          destinations: entries
              .map(
                (entry) => NavigationDestination(
                  icon: entry.$1 == 'Tin nhắn'
                      ? Badge.count(
                          count: _inbox?.unreadTotal ?? 0,
                          isLabelVisible: (_inbox?.unreadTotal ?? 0) > 0,
                          child: Icon(entry.$2),
                        )
                      : Icon(entry.$2),
                  label: entry.$1,
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class ProfileBanner extends StatelessWidget {
  const ProfileBanner({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) {
    final user = controller.user!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFFE1EEE7),
                child: Text(
                  user.displayName.isEmpty
                      ? '?'
                      : user.displayName.substring(0, 1),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      user.role.label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF526860),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (user.isApproved) const RealtimeStatus(compact: true),
          const SizedBox(height: 8),
          if (!user.isApproved)
            MessageBox(
              '${user.isActive ? user.approvalStatus.label : 'Tài khoản đã bị khóa'}\n'
              '${user.reviewReason?.isNotEmpty == true
                  ? user.reviewReason
                  : user.isActive
                  ? 'Bạn vẫn có thể xem tin công khai. Quản trị sẽ xét duyệt hồ sơ của bạn.'
                  : 'Liên hệ quản trị để được hỗ trợ.'}',
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: controller.busy
                        ? null
                        : controller.refreshProfile,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Cập nhật hồ sơ'),
                  ),
                ],
              ),
            ),
          if (controller.error != null) ...[
            const SizedBox(height: 8),
            MessageBox(controller.error!, error: true),
          ],
          if (controller.notice != null) ...[
            const SizedBox(height: 8),
            MessageBox(controller.notice!),
          ],
        ],
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.controller, this.header});
  final SessionController controller;
  final Widget? header;
  @override
  Widget build(BuildContext context) => ApiList(
    api: controller.api,
    path: '/history?limit=20',
    cursor: 'before',
    empty: 'Chưa có hoạt động được ghi nhận.',
    header: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [?header, const SectionTitle('Lịch sử cá nhân')],
    ),
    itemBuilder: (row) => DataCard(
      children: [
        Text(
          value(row, 'title'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(value(row, 'body')),
        const SizedBox(height: 8),
        Text(displayTime(row['createdAt'])),
        if (row['isDemo'] == true) const Text('Dữ liệu mẫu của máy chủ'),
      ],
    ),
  );
}

class AccountPage extends StatelessWidget {
  const AccountPage({
    super.key,
    required this.controller,
    required this.header,
  });
  final SessionController controller;
  final Widget header;
  @override
  Widget build(BuildContext context) {
    final user = controller.user!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        header,
        const SectionTitle('Tài khoản'),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => OwnProfilePage(controller: controller),
            ),
          ),
          icon: const Icon(Icons.manage_accounts_outlined),
          label: const Text('Hồ sơ & quyền riêng tư'),
        ),
        DataCard(
          children: [
            Text(
              user.displayName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(user.email),
            Text(user.role.label),
            Text(user.region),
            const SizedBox(height: 12),
            Text('Hồ sơ: ${user.approvalStatus.label}'),
            Text(
              user.twoFactorEnabled
                  ? 'Xác thực: ứng dụng đã đăng ký cho tài khoản cũ'
                  : 'Xác thực đăng nhập: mật khẩu và mã email',
            ),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SecurityPage(controller: controller),
            ),
          ),
          icon: const Icon(Icons.security_outlined),
          label: const Text('Bảo mật tài khoản'),
        ),
        const SizedBox(height: 8),
        if (user.role == UserRole.consumer && user.isApproved) ...[
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RoleApplicationsPage(controller: controller),
              ),
            ),
            icon: const Icon(Icons.assignment_ind_outlined),
            label: Text(
              user.role == UserRole.consumer
                  ? 'Nâng vai trò kinh doanh'
                  : 'Hồ sơ nâng vai trò',
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (user.canSell) ...[
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BranchesPage(controller: controller),
              ),
            ),
            icon: const Icon(Icons.storefront_outlined),
            label: Text(businessPlaceLabel(user.role)),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            title: const Text('Công cụ nghiệp vụ trước đây'),
            children: [
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OwnPostsPage(controller: controller),
                  ),
                ),
                icon: const Icon(Icons.edit_note),
                label: const Text('Tin dự kiến của tôi'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ],
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Lịch sử cá nhân')),
                body: SafeArea(child: HistoryPage(controller: controller)),
              ),
            ),
          ),
          icon: const Icon(Icons.history),
          label: const Text('Lịch sử cá nhân'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => UpdatePage(
                updater: UpdateScope.maybeOf(context),
                baseUrl: controller.api.baseUrl,
              ),
            ),
          ),
          icon: const Icon(Icons.system_update_alt),
          label: const Text('Kiểm tra cập nhật'),
        ),
        const SizedBox(height: 8),
        if (user.isAdmin)
          OutlinedButton.icon(
            onPressed: controller.busy
                ? null
                : () => openServerSettings(context, controller),
            icon: const Icon(Icons.dns_outlined),
            label: const Text('Cài đặt máy chủ'),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: controller.busy ? null : controller.logout,
          icon: const Icon(Icons.logout),
          label: Text(controller.busy ? 'Đang xử lý…' : 'Đăng xuất'),
        ),
      ],
    );
  }
}

class OwnPostsPage extends StatefulWidget {
  const OwnPostsPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<OwnPostsPage> createState() => _OwnPostsPageState();
}

class _OwnPostsPageState extends State<OwnPostsPage> {
  final _list = GlobalKey<ApiListState>();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Tin dự kiến của tôi')),
    body: SafeArea(
      child: LiveApiList(
        listKey: _list,
        api: widget.controller.api,
        path: '/me/posts?limit=20',
        targets: const {'PostChanged'},
        header: SectionTitle(
          'Theo dõi tin đã gửi',
          action: FilledButton.icon(
            onPressed: () async {
              final changed = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => ForecastForm(controller: widget.controller),
                ),
              );
              if (mounted && changed == true) _list.currentState?.reload();
            },
            icon: const Icon(Icons.add),
            label: const Text('Tạo tin dự kiến'),
          ),
        ),
        itemBuilder: (row) =>
            PostCard(row: row, own: true, controller: widget.controller),
      ),
    ),
  );
}
