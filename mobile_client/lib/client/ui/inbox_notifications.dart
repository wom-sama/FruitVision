import 'package:flutter/material.dart';

import '../inbox.dart';
import '../session.dart';
import 'chat.dart';
import 'components.dart';

class InboxNotificationsPage extends StatelessWidget {
  const InboxNotificationsPage({
    super.key,
    required this.controller,
    required this.inbox,
  });
  final SessionController controller;
  final InboxController inbox;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Thông báo tin nhắn')),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: inbox,
        builder: (context, _) => RefreshIndicator(
          onRefresh: inbox.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${inbox.unreadTotal} tin chưa đọc · ${inbox.unreadConversations} hội thoại',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (inbox.loading) const LinearProgressIndicator(),
              if (inbox.error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: MessageBox(
                    inbox.error!,
                    error: true,
                    child: TextButton(
                      onPressed: inbox.refresh,
                      child: const Text('Thử lại'),
                    ),
                  ),
                ),
              if (!inbox.loading && inbox.unreadTotal == 0)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Bạn đã đọc hết tin nhắn.'),
                ),
              for (final notification in inbox.notifications)
                InboxConversationTile(
                  row: notification.conversation,
                  onTap: () => openInboxConversation(
                    context,
                    controller: controller,
                    inbox: inbox,
                    row: notification.conversation,
                  ),
                ),
              if (inbox.unreadConversations > inbox.notifications.length)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Danh sách hiển thị các hội thoại gần đây. Tổng chưa đọc bao gồm cả hội thoại cũ hơn.',
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
