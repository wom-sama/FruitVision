import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/ui/publishing.dart';

import 'ui_test.dart' as old;
import 'mango_media_test.dart' show MangoTransport;

class EngagementTransport extends MangoTransport {
  bool liked = false, failComment = true;
  final commentWrites = <Map<String, dynamic>>[];
  final likeWrites = <Map<String, dynamic>>[];
  final comments = <Map<String, dynamic>>[];
  Map<String, dynamic> get counts => {
    'articleId': 'article-one',
    'likeCount': liked ? 3 : 2,
    'commentCount': comments.length,
    'liked': liked,
  };
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/likes')) return ApiReply(200, jsonEncode(counts));
    if (uri.path.endsWith('/like') && method == 'PUT') {
      final data = jsonDecode(body!) as Map<String, dynamic>;
      likeWrites.add(data);
      liked = data['liked'] == true;
      return ApiReply(200, jsonEncode(counts));
    }
    if (uri.path.endsWith('/comments')) {
      if (method == 'POST') {
        final data = jsonDecode(body!) as Map<String, dynamic>;
        commentWrites.add(data);
        if (failComment) {
          return const ApiReply(
            503,
            '{"detail":"Bình luận chưa được xác nhận."}',
          );
        }
        final row = {
          'id': 'comment-one',
          'articleId': 'article-one',
          'clientCommentId': data['clientCommentId'],
          'body': data['body'],
          'createdAt': '2026-10-31T10:00:00Z',
          'author': {
            'id': 'account-Consumer',
            'displayName': 'Minh',
            'role': 'Consumer',
          },
          'canDelete': true,
        };
        if (comments.isEmpty) comments.add(row);
        return ApiReply(201, jsonEncode(row));
      }
      return ApiReply(
        200,
        jsonEncode({'items': comments, 'next': null, ...counts}),
      );
    }
    if (uri.path.endsWith('/comments/comment-one') && method == 'DELETE') {
      comments.clear();
      return const ApiReply(204, '');
    }
    return super.send(method, uri, headers, body);
  }
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'likes use desired server state and uncertain comment retries preserve one UUID and body',
    (tester) async {
      old.narrowPhone(tester);
      final source = EngagementTransport(),
          c = old.controller(source, role: UserRole.consumer);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ArticlePage(controller: c, id: 'article-one'),
        ),
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Thích · 2');
      expect(source.likeWrites.single, {'liked': true});
      expect(find.text('Đã thích · 3'), findsOneWidget);
      final field = find.widgetWithText(TextFormField, 'Viết bình luận');
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'Kinh nghiệm hữu ích về cách đọc kết quả.');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapText(tester, 'Gửi bình luận');
      expect(source.commentWrites, hasLength(1));
      final first = source.commentWrites.single;
      expect(
        first['clientCommentId'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(tester.widget<TextFormField>(field).enabled, isFalse);
      source.failComment = false;
      await tapText(tester, 'Thử gửi lại');
      expect(source.commentWrites, hasLength(2));
      expect(source.commentWrites[1], first);
      expect(source.comments, hasLength(1));
      expect(
        find.text('Kinh nghiệm hữu ích về cách đọc kết quả.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
