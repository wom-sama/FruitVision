import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/secret_messaging.dart';
import 'package:fruitvision_client/client/ui/chat.dart';
import 'package:fruitvision_client/client/ui/secret_chat.dart';
import 'package:fruitvision_client/client/ui/publishing.dart';
import 'package:fruitvision_client/client/ui/realtime_scope.dart';
import 'package:fruitvision_client/client/ui/secret_scope.dart';

import 'article_engagement_test.dart' show EngagementTransport;
import 'ai_test.dart' show EventHub;
import 'ui_test.dart' as old;

class PublicationEventTransport extends EngagementTransport {
  String status = 'AwaitingReview';
  int details = 0;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path == '/api/v1/articles/article-one') {
      details++;
      return ApiReply(
        200,
        jsonEncode({
          'id': 'article-one',
          'title': 'Bài chờ công bố',
          'body': 'Nội dung chờ quản trị công bố.',
          'status': status,
          'author': {'id': 'account-Consumer', 'displayName': 'Minh'},
        }),
      );
    }
    return super.send(method, uri, headers, body);
  }
}

class DirectContextTransport extends old.UiTransport {
  DirectContextTransport(this.peerRole, this.eligible);
  final String peerRole;
  final bool eligible;
  int contexts = 0;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path == '/api/v1/conversations/direct-one/context') {
      contexts++;
      return ApiReply(
        200,
        jsonEncode({
          'kind': 'Direct',
          'title': 'Trao đổi bài xoài',
          'peer': {
            'id': 'peer-one',
            'displayName': 'Nguyễn Thị Lan',
            'role': peerRole,
            'email': 'must-not-display@example.test',
          },
          'secretEligible': eligible,
        }),
      );
    }
    if (uri.path.endsWith('/messages')) {
      return const ApiReply(200, '{"items":[]}');
    }
    return const ApiReply(404, '{}');
  }
}

void main() {
  testWidgets(
    'actual PublishedArticleChanged id reloads detail and reveals newly published engagement',
    (tester) async {
      final source = PublicationEventTransport(),
          c = old.controller(source, role: UserRole.consumer),
          hub = EventHub(c.api);
      addTearDown(() {
        hub.dispose();
        c.dispose();
      });
      await tester.pumpWidget(
        RealtimeScope(
          client: hub,
          child: MaterialApp(
            home: ArticlePage(controller: c, id: 'article-one'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.details, 1);
      expect(find.text('Thích · 2'), findsNothing);
      hub.updates.add(
        const HubEvent('PublishedArticleChanged', {'id': 'other-article'}),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(source.details, 1);
      source.status = 'Published';
      hub.updates.add(
        const HubEvent('PublishedArticleChanged', {
          'id': 'article-one',
          'status': 'Published',
          'revision': 2,
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(source.details, 2);
      expect(find.text('Thích · 2'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Viết bình luận'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final eligible in [true, false]) {
    testWidgets(
      'Direct context ${eligible ? 'Seller' : 'Consumer'} peer controls identity and server E2EE eligibility',
      (tester) async {
        final source = DirectContextTransport(
              eligible ? 'Trader' : 'Consumer',
              eligible,
            ),
            c = old.controller(source, role: UserRole.producer),
            secrets = SecretMessaging(session: c);
        addTearDown(() {
          secrets.dispose();
          c.dispose();
        });
        await tester.pumpWidget(
          SecretScope(
            messaging: secrets,
            child: MaterialApp(
              home: ChatPage(
                controller: c,
                id: 'direct-one',
                title: 'Trao đổi bài xoài',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(source.contexts, 1);
        expect(find.text('Nguyễn Thị Lan'), findsOneWidget);
        expect(
          find.textContaining(eligible ? 'Thương lái' : 'Người tiêu dùng'),
          findsWidgets,
        );
        expect(
          find.byType(OpenSecretRoomButton),
          eligible ? findsOneWidget : findsNothing,
        );
        expect(find.textContaining('must-not-display'), findsNothing);
        expect(find.byTooltip('Gửi tin nhắn'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
