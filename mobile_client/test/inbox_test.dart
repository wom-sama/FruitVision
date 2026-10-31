import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/inbox.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/ui/chat.dart';

import 'ui_test.dart' as fixtures;
import 'ai_test.dart' show EventHub;

class DelayedInboxTransport extends InboxTransport {
  final pending = Completer<ApiReply>();
  int fetches = 0;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) {
    if (method == 'GET' && uri.path.endsWith('/conversations')) {
      fetches++;
      if (fetches == 1) return pending.future;
    }
    return super.send(method, uri, headers, body);
  }
}

class InboxTransport extends fixtures.UiTransport {
  final reads = <Map<String, dynamic>>[];
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/read')) {
      reads.add(jsonDecode(body!) as Map<String, dynamic>);
      return const ApiReply(200, '{"unreadCount":0}');
    }
    if (uri.path.endsWith('/context')) {
      return const ApiReply(200, '{"kind":"Direct","secretEligible":false}');
    }
    if (uri.path.endsWith('/messages')) {
      return const ApiReply(
        200,
        '{"items":[{"id":"00000000-0000-0000-0000-000000000001","senderId":"peer","text":"Chào bạn","createdAt":"2026-10-31T10:00:00Z"}]}',
      );
    }
    return ApiReply(
      200,
      jsonEncode({
        'items': [
          {
            'id': 'direct-one',
            'title': 'Bài chia sẻ về xoài',
            'kind': 'Direct',
            'peer': {
              'id': 'peer',
              'displayName': 'Lan Nguyễn',
              'role': 'Producer',
            },
            'lastActivityAt': '2026-10-31T10:00:00Z',
            'lastMessage': {
              'kind': 'text',
              'text': 'Chào bạn',
              'senderName': 'Lan',
            },
            'unreadCount': 3,
            'lastMessageEncrypted': false,
          },
        ],
        'summary': {'unreadTotal': 12, 'unreadConversations': 4},
      }),
    );
  }
}

void main() {
  testWidgets(
    'inbox shows peer, preview and server unread without reading it',
    (tester) async {
      fixtures.narrowPhone(tester);
      final source = InboxTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationList(
              controller: session,
              header: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lan Nguyễn'), findsOneWidget);
      expect(find.text('Lan: Chào bạn'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(source.reads, isEmpty);
      expect(find.text('Chat riêng đã mã hóa đầu cuối'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets('visible newest normal message acknowledges its actual cursor', (
    tester,
  ) async {
    final source = InboxTransport();
    final session = fixtures.controller(source, role: UserRole.consumer);
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(controller: session, id: 'direct-one', title: 'Lan'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Chào bạn'), findsOneWidget);
    expect(source.reads, [
      {'lastMessageId': '00000000-0000-0000-0000-000000000001'},
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets('event during stale fetch coalesces a trailing server snapshot', (
    tester,
  ) async {
    final source = DelayedInboxTransport();
    final session = fixtures.controller(source, role: UserRole.consumer);
    final hub = EventHub(session.api);
    final inbox = InboxController(session: session, realtime: hub);
    expect(source.fetches, 1);
    hub.updates.add(
      const HubEvent('MessageCreated', {'conversationId': 'direct-one'}),
    );
    hub.updates.add(const HubEvent('InboxChanged', {}));
    await tester.pump();
    source.pending.complete(
      const ApiReply(
        200,
        '{"items":[],"summary":{"unreadTotal":0,"unreadConversations":0}}',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(source.fetches, 2);
    expect(inbox.entries.single['id'], 'direct-one');
    expect(inbox.unreadTotal, 12);
    expect(inbox.unreadConversations, 4);
    inbox.dispose();
    hub.dispose();
    session.dispose();
  });

  testWidgets('logout clears unread and discards a pending old-account reply', (
    tester,
  ) async {
    final source = DelayedInboxTransport();
    final session = fixtures.controller(source, role: UserRole.consumer);
    final inbox = InboxController(session: session);
    await session.logout();
    source.pending.complete(
      const ApiReply(
        200,
        '{"items":[{"id":"old"}],"summary":{"unreadTotal":99,"unreadConversations":1}}',
      ),
    );
    await tester.pump();
    expect(inbox.entries, isEmpty);
    expect(inbox.unreadTotal, 0);
    expect(inbox.loading, isFalse);
    inbox.dispose();
    session.dispose();
  });

  testWidgets(
    'read receipt uses supplied real cursor and refreshes global authority',
    (tester) async {
      final source = InboxTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      final inbox = InboxController(session: session);
      await tester.pump();
      await inbox.markRead('direct-one', lastMessageId: 'actual-id');
      expect(source.reads.single, {'lastMessageId': 'actual-id'});
      expect(inbox.unreadTotal, 12);
      inbox.dispose();
      session.dispose();
    },
  );
}
