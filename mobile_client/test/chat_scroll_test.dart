import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/ui/chat.dart';
import 'package:fruitvision_client/client/ui/realtime_scope.dart';
import 'package:fruitvision_client/client/vault.dart';

String messageId(int index) =>
    '00000000-0000-0000-0000-${index.toString().padLeft(12, '0')}';
Map<String, dynamic> message(int index, {String? text, bool own = false}) => {
  'id': messageId(index),
  'conversationId': 'thread-one',
  'senderId': own ? 'self' : 'other',
  'clientMessageId': 'fixture-message-$index',
  'text': text ?? 'Tin số $index\nNội dung trao đổi trong hội thoại.',
  'createdAt': DateTime.utc(2026, 10, 30, 10, index).toIso8601String(),
};

class ChatTransport implements ApiTransport {
  final latest = List.generate(20, (index) => message(index + 20));
  final readCursors = <String>[];
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/read')) {
      readCursors.add((jsonDecode(body!) as Map)['lastMessageId'] as String);
      return const ApiReply(200, '{"unreadCount":0}');
    }
    if (method == 'POST') {
      final draft = jsonDecode(body!) as Map<String, dynamic>;
      final sent = message(40, text: draft['text'] as String, own: true);
      latest.add(sent);
      return ApiReply(201, jsonEncode(sent));
    }
    final older = uri.queryParameters.containsKey('before');
    final items = older
        ? List.generate(20, message)
        : latest.skip(latest.length > 20 ? latest.length - 20 : 0).toList();
    return ApiReply(
      200,
      jsonEncode({
        'items': items.reversed.toList(),
        'next': older ? null : messageId(20),
      }),
    );
  }

  @override
  void close() {}
}

class ChatVault implements SessionVault {
  @override
  Future<Map<String, dynamic>?> read() async => null;
  @override
  Future<void> write(Map<String, dynamic> value) async {}
  @override
  Future<void> clear() async {}
}

class ChatEvents extends RealtimeClient {
  ChatEvents(ApiClient api) : super(api: api);
  final updates = StreamController<HubEvent>.broadcast();
  @override
  Stream<HubEvent> get events => updates.stream;
  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }
}

Future<(ChatTransport, ChatEvents)> openChat(
  WidgetTester tester, {
  ChatTransport? source,
  bool group = false,
}) async {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.4;
  final transport = source ?? ChatTransport();
  final c =
      SessionController(
          api: ApiClient(baseUrl: 'https://example.test', transport: transport),
          vault: ChatVault(),
        )
        ..loading = false
        ..user = const Account(
          id: 'self',
          displayName: 'Minh',
          email: 'm@example.test',
          role: UserRole.consumer,
          approvalStatus: ApprovalStatus.approved,
          region: 'Đồng Tháp',
          isActive: true,
        );
  final hub = ChatEvents(c.api);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    hub.dispose();
    c.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    RealtimeScope(
      client: hub,
      child: MaterialApp(
        home: ChatPage(
          controller: c,
          id: 'thread-one',
          title: 'Trao đổi',
          group: group,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (transport, hub);
}

Finder chatList() => find.byType(ListView);
void expectVisible(WidgetTester tester, String text) {
  expect(
    find.text(text),
    findsOneWidget,
    reason: 'The requested latest message must be rendered in the open thread.',
  );
  final viewport = tester.getRect(chatList());
  final bubble = tester.getRect(find.text(text));
  expect(bubble.top, greaterThanOrEqualTo(viewport.top));
  expect(bubble.bottom, lessThanOrEqualTo(viewport.bottom));
}

void main() {
  testWidgets(
    'group messages identify different senders by authorized name and business role',
    (tester) async {
      final source = ChatTransport();
      source.latest
        ..clear()
        ..addAll([
          {
            ...message(20, text: 'Tôi có nguồn xoài dự kiến.'),
            'senderId': 'producer-one',
            'sender': {
              'id': 'producer-one',
              'displayName': 'Vườn An Bình',
              'role': 'Producer',
            },
          },
          {
            ...message(21, text: 'Tôi muốn trao đổi nhu cầu thu mua.'),
            'senderId': 'trader-one',
            'sender': {
              'id': 'trader-one',
              'displayName': 'Thương lái Minh',
              'role': 'Trader',
            },
          },
        ]);
      await openChat(tester, source: source, group: true);
      expect(find.text('Vườn An Bình'), findsOneWidget);
      expect(find.text('Nhà sản xuất'), findsOneWidget);
      expect(find.text('Thương lái Minh'), findsOneWidget);
      expect(find.text('Thương lái'), findsOneWidget);
      expect(find.text('Thành viên'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'opening latest history shows newest message without a manual scroll',
    (tester) async {
      await openChat(tester);
      expectVisible(tester, 'Tin số 39\nNội dung trao đổi trong hội thoại.');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sending while near the bottom keeps the sent message visible', (
    tester,
  ) async {
    await openChat(tester);
    await tester.drag(chatList(), const Offset(0, -10000));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Tin mới tôi gửi');
    await tester.tap(find.byTooltip('Gửi tin nhắn'));
    await tester.pumpAndSettle();
    expectVisible(tester, 'Tin mới tôi gửi');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'incoming message preserves older reading position and offers a jump action',
    (tester) async {
      final (transport, hub) = await openChat(tester);
      expect(transport.readCursors, [messageId(39)]);
      await tester.drag(chatList(), const Offset(0, 10000));
      await tester.pumpAndSettle();
      const anchor = 'Tin số 20\nNội dung trao đổi trong hội thoại.';
      final before = tester.getTopLeft(find.text(anchor)).dy;
      transport.latest.add(message(40));
      hub.updates.add(
        HubEvent('MessageCreated', {
          'id': messageId(40),
          'conversationId': 'thread-one',
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(anchor)).dy, closeTo(before, 1));
      expect(transport.readCursors, [
        messageId(39),
      ], reason: 'Incoming newest is offscreen while reading older messages.');
      final jump = find.text('1 tin nhắn mới');
      expect(jump, findsOneWidget);
      expect(
        tester
            .getSize(
              find.ancestor(of: jump, matching: find.byType(FilledButton)),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expectVisible(tester, 'Tin số 40\nNội dung trao đổi trong hội thoại.');
      expect(transport.readCursors, [messageId(39), messageId(40)]);
      expect(find.text('1 tin nhắn mới'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'older pagination keeps the current message at the same viewport position',
    (tester) async {
      await openChat(tester);
      await tester.drag(chatList(), const Offset(0, 10000));
      await tester.pumpAndSettle();
      const anchor = 'Tin số 20\nNội dung trao đổi trong hội thoại.';
      final before = tester.getTopLeft(find.text(anchor)).dy;
      await tester.tap(find.text('Xem tin cũ hơn'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(anchor)).dy, closeTo(before, 1));
      expect(find.textContaining('tin nhắn mới'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
