import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/ui/chat.dart';
import 'package:fruitvision_client/client/ui/profile.dart';
import 'package:fruitvision_client/client/ui/workspace.dart';

import 'profile_test.dart' show ProfileTransport;
import 'ui_test.dart' as fixtures;

class ConsumerProfileTransport extends ProfileTransport {
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) {
    if (uri.path.endsWith('/profiles/peer-one')) {
      return Future.value(
        const ApiReply(
          200,
          '{"id":"peer-one","displayName":"Bạn cộng đồng","role":"Consumer","roleDetails":{"role":"Consumer","approvalStatus":"Approved","establishmentName":null}}',
        ),
      );
    }
    return super.send(method, uri, headers, body);
  }
}

class NotificationTransport extends ProfileTransport {
  int unread = 0;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) {
    if (method == 'GET' && uri.path.endsWith('/conversations')) {
      return Future.value(
        ApiReply(
          200,
          '{"items":[],"summary":{"unreadTotal":$unread,"unreadConversations":$unread}}',
        ),
      );
    }
    return super.send(method, uri, headers, body);
  }
}

void main() {
  testWidgets('public profile hides an empty reviewed establishment section', (
    tester,
  ) async {
    final source = ConsumerProfileTransport();
    final session = fixtures.controller(source, role: UserRole.producer);
    await tester.pumpWidget(
      MaterialApp(
        home: UserProfilePage(controller: session, userId: 'peer-one'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bạn cộng đồng'), findsOneWidget);
    expect(find.text('Người tiêu dùng'), findsOneWidget);
    expect(find.text('Thông tin vai trò đã xét duyệt'), findsNothing);
    expect(source.writes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets(
    'same peer Direct inbox rows distinguish article, post and generic context at narrow scale',
    (tester) async {
      fixtures.narrowPhone(tester);
      final base = <String, dynamic>{
        'kind': 'Direct',
        'peer': {
          'id': 'same-peer',
          'displayName': 'Bạn cộng đồng',
          'role': 'Consumer',
        },
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                InboxConversationTile(
                  row: {
                    ...base,
                    'id': 'article-chat',
                    'title': 'Kinh nghiệm chăm sóc xoài',
                    'articleId': 'article-one',
                  },
                  onTap: () {},
                ),
                InboxConversationTile(
                  row: {
                    ...base,
                    'id': 'post-chat',
                    'title': 'Tin xoài đã công bố',
                    'postId': 'post-one',
                  },
                  onTap: () {},
                ),
                InboxConversationTile(
                  row: {
                    ...base,
                    'id': 'generic-chat',
                    'title': 'Cuộc trò chuyện riêng',
                  },
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bài viết · Kinh nghiệm chăm sóc xoài'), findsOneWidget);
      expect(find.text('Tin nông sản · Tin xoài đã công bố'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Nhắn tin riêng'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Nhắn tin riêng'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'foreground inbox notification stays on Workspace and cannot cover a pushed profile route',
    (tester) async {
      final source = NotificationTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(home: Workspace(controller: session)),
      );
      await tester.pumpAndSettle();
      final inbox = tester
          .widget<ConversationList>(
            find.byType(ConversationList, skipOffstage: false),
          )
          .inbox!;
      source.unread = 1;
      await inbox.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Bạn có tin nhắn mới'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is NavigationDestination && widget.label == 'Tài khoản',
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Hồ sơ & quyền riêng tư'));
      await tester.pumpAndSettle();
      expect(find.byType(OwnProfilePage), findsOneWidget);
      expect(find.text('Bạn có tin nhắn mới'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
}
