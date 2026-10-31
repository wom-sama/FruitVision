import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/ui/admin.dart';
import 'package:fruitvision_client/client/ui/chat.dart';
import 'package:fruitvision_client/client/ui/publishing.dart';
import 'package:fruitvision_client/client/ui/admin_appointments.dart';
import 'package:fruitvision_client/client/ui/new_message.dart';

import 'ui_test.dart' as fixtures;

class ManagementTransport extends fixtures.UiTransport {
  final writes = <(String, Uri, Map<String, dynamic>?)>[];
  bool stale = false, denyAppointment = false;
  final requestedPaths = <String>[];
  Completer<ApiReply>? pendingAppointment;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    requestedPaths.add(uri.path);
    if (uri.path.endsWith('/admin/admin-appointments') && denyAppointment) {
      writes.add((method, uri, jsonDecode(body!) as Map<String, dynamic>));
      return const ApiReply(403, '{"detail":"Không thể xác nhận thao tác."}');
    }
    if (method != 'GET') {
      writes.add((
        method,
        uri,
        body == null ? null : jsonDecode(body) as Map<String, dynamic>,
      ));
    }
    if (uri.path.endsWith('/admin/admin-appointments') &&
        pendingAppointment != null) {
      return pendingAppointment!.future;
    }
    if (uri.path.endsWith('/articles/article-one')) {
      if (method == 'DELETE') return ApiReply(stale ? 409 : 200, '{}');
      return ApiReply(
        200,
        jsonEncode({
          'id': 'article-one',
          'title': 'Bài của chính tôi',
          'body': 'Nội dung bài viết thử nghiệm.',
          'status': 'AwaitingReview',
          'revision': stale ? 8 : 7,
          'author': {'id': 'account-Consumer', 'displayName': 'Minh'},
        }),
      );
    }
    if (uri.path.endsWith('/admin/admin-candidates')) {
      return const ApiReply(
        200,
        '{"items":[{"id":"candidate-one","displayName":"Người được bổ nhiệm","email":"candidate@example.test","region":"Đồng Tháp"}]}',
      );
    }
    if (uri.path.endsWith('/contacts')) {
      return const ApiReply(
        200,
        '{"items":[{"id":"peer-one","displayName":"Lan sản xuất","role":"Producer"}]}',
      );
    }
    if (uri.path.endsWith('/conversations/direct')) {
      return const ApiReply(
        201,
        '{"id":"direct-one","title":"Cuộc trò chuyện riêng","kind":"Direct"}',
      );
    }
    if (uri.path.endsWith('/context')) {
      return const ApiReply(200, '{"kind":"Direct","secretEligible":false}');
    }
    return const ApiReply(
      200,
      '{"items":[],"summary":{"unreadTotal":0,"unreadConversations":0}}',
    );
  }
}

void main() {
  testWidgets('Admin home exposes password-confirmed appointment entry', (
    tester,
  ) async {
    final session = fixtures.controller(
      ManagementTransport(),
      role: UserRole.admin,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminPage(controller: session, header: const SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bổ nhiệm quản trị viên'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets('own article exposes explicit destructive confirmation', (
    tester,
  ) async {
    final source = ManagementTransport();
    final session = fixtures.controller(source, role: UserRole.consumer);
    await tester.pumpWidget(
      MaterialApp(
        home: ArticlePage(controller: session, id: 'article-one'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Xóa bài viết'), findsOneWidget);
    expect(source.writes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets('one inbox offers a discoverable new normal message action', (
    tester,
  ) async {
    final session = fixtures.controller(
      ManagementTransport(),
      role: UserRole.consumer,
    );
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
    expect(find.byTooltip('Tin nhắn mới'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets(
    'appointment requires explicit confirmation and clears raw password',
    (tester) async {
      final source = ManagementTransport();
      final actualSession = fixtures.controller(source, role: UserRole.admin);
      await tester.pumpWidget(
        MaterialApp(home: AdminAppointmentsPage(controller: actualSession)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Người được bổ nhiệm'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lý do bổ nhiệm'),
        'Phân công quản trị nội dung',
      );
      final password = find.widgetWithText(
        TextFormField,
        'Mật khẩu quản trị viên hiện tại',
      );
      await tester.enterText(password, ' raw exact password ');
      final submit = find.widgetWithText(
        FilledButton,
        'Bổ nhiệm quản trị viên',
      );
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(source.writes, isEmpty);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(password).controller!.text, isEmpty);
      await tester.enterText(password, ' raw exact password ');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận bổ nhiệm'));
      await tester.pumpAndSettle();
      expect(source.writes.single.$2.path, '/api/v1/admin/admin-appointments');
      expect(source.writes.single.$3, {
        'userId': 'candidate-one',
        'password': ' raw exact password ',
        'reason': 'Phân công quản trị nội dung',
      });
      expect(find.textContaining('Đã bổ nhiệm'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      actualSession.dispose();
    },
  );

  testWidgets('non Admin cannot load appointment candidates', (tester) async {
    final source = ManagementTransport();
    final session = fixtures.controller(source, role: UserRole.consumer);
    await tester.pumpWidget(
      MaterialApp(home: AdminAppointmentsPage(controller: session)),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Chỉ quản trị viên được sử dụng chức năng này.'),
      findsOneWidget,
    );
    expect(find.byType(TextFormField), findsNothing);
    expect(source.writes, isEmpty);
    expect(source.requestedPaths, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets(
    'contact choice creates a server normal Direct and opens that conversation',
    (tester) async {
      final source = ManagementTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(home: NewMessagePage(controller: session)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lan sản xuất'), findsOneWidget);
      await tester.tap(find.text('Lan sản xuất'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(tester.widget<ChatPage>(find.byType(ChatPage)).id, 'direct-one');
      expect(source.writes.single.$2.path, '/api/v1/conversations/direct');
      expect(source.writes.single.$3, {'userId': 'peer-one'});
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  for (final article in [true, false]) {
    testWidgets(
      '${article ? 'article' : 'branch'} deletion confirms, sends revision, and never retries stale delete',
      (tester) async {
        final source = ManagementTransport();
        final session = fixtures.controller(
          source,
          role: article ? UserRole.consumer : UserRole.producer,
        );
        var reloaded = 0, deleted = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: OwnPublicationDelete(
                controller: session,
                article: article,
                data: {
                  'id': 'article-one',
                  'revision': 7,
                  article ? 'author' : 'owner': {
                    'id': article ? 'account-Consumer' : 'account-Producer',
                  },
                },
                reload: () async {
                  reloaded++;
                },
                onDeleted: () async {
                  deleted++;
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text(article ? 'Xóa bài viết' : 'Xóa cơ sở'));
        await tester.pumpAndSettle();
        expect(source.writes, isEmpty);
        await tester.tap(find.text('Giữ lại'));
        await tester.pumpAndSettle();
        expect(source.writes, isEmpty);
        source.stale = article;
        await tester.tap(find.text(article ? 'Xóa bài viết' : 'Xóa cơ sở'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xác nhận xóa'));
        await tester.pumpAndSettle();
        expect(source.writes.single.$1, 'DELETE');
        expect(
          source.writes.single.$2.path,
          article
              ? '/api/v1/articles/article-one'
              : '/api/v1/branches/article-one',
        );
        expect(source.writes.single.$2.queryParameters, {
          'expectedRevision': '7',
        });
        expect(reloaded, article ? 1 : 0);
        expect(deleted, article ? 0 : 1);
        if (article) {
          expect(find.textContaining('Chưa thể xóa.'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      },
    );
  }
  testWidgets(
    'wrong reconfirmation password clears field and never retries or claims success',
    (tester) async {
      final source = ManagementTransport()..denyAppointment = true;
      final session = fixtures.controller(source, role: UserRole.admin);
      await tester.pumpWidget(
        MaterialApp(home: AdminAppointmentsPage(controller: session)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Người được bổ nhiệm'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lý do bổ nhiệm'),
        'Phân công quản trị',
      );
      final password = find.widgetWithText(
        TextFormField,
        'Mật khẩu quản trị viên hiện tại',
      );
      await tester.enterText(password, 'wrong password');
      final submit = find.widgetWithText(
        FilledButton,
        'Bổ nhiệm quản trị viên',
      );
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận bổ nhiệm'));
      await tester.pumpAndSettle();
      expect(source.writes.length, 1);
      expect(find.textContaining('Đã bổ nhiệm'), findsNothing);
      expect(find.text('Không thể xác nhận thao tác.'), findsOneWidget);
      expect(tester.widget<TextFormField>(password).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
  testWidgets(
    'disposed appointment clears password before network and completes safely',
    (tester) async {
      final source = ManagementTransport()
        ..pendingAppointment = Completer<ApiReply>();
      final session = fixtures.controller(source, role: UserRole.admin);
      await tester.pumpWidget(
        MaterialApp(home: AdminAppointmentsPage(controller: session)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Người được bổ nhiệm'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lý do bổ nhiệm'),
        'Phân công quản trị',
      );
      final password = find.widgetWithText(
        TextFormField,
        'Mật khẩu quản trị viên hiện tại',
      );
      await tester.enterText(password, ' exact transient password ');
      final submit = find.widgetWithText(
        FilledButton,
        'Bổ nhiệm quản trị viên',
      );
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận bổ nhiệm'));
      await tester.pump();
      final whilePending = tester
          .widget<TextFormField>(password)
          .controller!
          .text;
      await tester.pumpWidget(const SizedBox.shrink());
      source.pendingAppointment!.complete(const ApiReply(200, '{}'));
      await tester.pump();
      expect(whilePending, isEmpty);
      expect(
        source.writes.single.$3!['password'],
        ' exact transient password ',
      );
      expect(tester.takeException(), isNull);
      session.dispose();
    },
  );
}
