import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/ui/moderation.dart';

import 'ui_test.dart' as old;

class StrictModerationTransport implements ApiTransport {
  StrictModerationTransport(this.article);
  final bool article;
  final calls = <(String, String, Map<String, dynamic>?)>[];
  String get collection => article ? 'articles' : 'branches';
  String get id => article ? 'article-one' : 'branch-one';
  int get revision => article ? 7 : 3;
  Map<String, dynamic> get detail => {
    'id': id,
    'revision': revision,
    'status': article ? 'AwaitingReview' : 'Pending',
    if (article) ...{
      'title': 'Bài xoài đang chờ duyệt',
      'body': 'Nội dung bài viết đầy đủ để quản trị kiểm tra.',
      'author': {'id': 'owner', 'displayName': 'Tác giả mẫu'},
    } else ...{
      'name': 'Chi nhánh mẫu đang chờ duyệt',
      'region': 'Đồng Tháp, Việt Nam',
      'street': 'Số 10 đường Hoa',
      'phone': '0901234567',
      'owner': {'id': 'owner', 'displayName': 'Chủ chi nhánh mẫu'},
    },
  };
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    final data = body == null ? null : jsonDecode(body) as Map<String, dynamic>;
    calls.add((method, uri.path, data));
    if (method == 'GET' && uri.path == '/api/v1/$collection/$id') {
      return ApiReply(200, jsonEncode(detail));
    }
    if (method == 'POST' &&
        uri.path == '/api/v1/admin/$collection/$id/review') {
      return ApiReply(
        200,
        jsonEncode({
          ...detail,
          'status': data!['status'],
          'revision': revision + 1,
        }),
      );
    }
    // There are intentionally no GET /admin/articles/{id} or /admin/branches/{id} routes.
    return const ApiReply(404, '{"detail":"Endpoint does not exist."}');
  }

  @override
  void close() {}
}

void main() {
  for (final article in [true, false]) {
    testWidgets(
      '${article ? 'Article' : 'Branch'} reads shared detail route and posts review only to admin route',
      (tester) async {
        final source = StrictModerationTransport(article),
            session =
                SessionController(
                    api: ApiClient(
                      baseUrl: 'https://example.test',
                      transport: source,
                    ),
                    vault: old.MemoryVault(),
                  )
                  ..loading = false
                  ..user = Account.fromJson(old.profile(UserRole.admin));
        addTearDown(session.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: ReviewDetailPage(
              controller: session,
              kind: article ? ReviewKind.articles : ReviewKind.branches,
              id: source.id,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            article
                ? 'Nội dung bài viết đầy đủ để quản trị kiểm tra.'
                : 'Số 10 đường Hoa',
          ),
          findsOneWidget,
        );
        expect(
          source.calls.single.$2,
          '/api/v1/${source.collection}/${source.id}',
        );
        final reason = find.widgetWithText(TextFormField, 'Lý do xét duyệt');
        await tester.scrollUntilVisible(
          reason,
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.enterText(reason, 'Thông tin phù hợp để chấp thuận.');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final approve = find.text(article ? 'Công bố' : 'Chấp thuận');
        await tester.ensureVisible(approve);
        await tester.pumpAndSettle();
        await tester.tap(approve);
        await tester.pumpAndSettle();
        final submitted = source.calls.singleWhere((call) => call.$1 == 'POST');
        expect(
          submitted.$2,
          '/api/v1/admin/${source.collection}/${source.id}/review',
        );
        expect(submitted.$3, {
          'status': article ? 'Published' : 'Approved',
          'reason': 'Thông tin phù hợp để chấp thuận.',
          'expectedRevision': source.revision,
        });
        expect(
          find.text(article ? 'Đã công bố' : 'Đã chấp thuận'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
