import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/ui/ai.dart';
import 'package:fruitvision_client/client/ui/mango_learning.dart';
import 'package:fruitvision_client/client/ui/publishing.dart';
import 'package:fruitvision_client/client/ui/moderation.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/media.dart';

import 'ui_test.dart' as ui;
import 'workflows_2_3_test.dart' show enter;

class MangoTransport extends ui.UiTransport {
  final requests = <(String, Uri, Map<String, dynamic>?)>[];
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    final data = body == null ? null : jsonDecode(body) as Map<String, dynamic>;
    requests.add((method, uri, data));
    Object response = {'items': <Object>[]};
    if (uri.path.endsWith('/learning/mango')) {
      response = {
        'schemaVersion': 1,
        'productCode': 'mango',
        'title': 'Hiểu về xoài',
        'summary': 'Quan sát ảnh và hiểu giới hạn mô hình.',
        'modelScope': {
          'stages': [
            {
              'code': -1,
              'label': 'Chưa xác định',
              'description': 'Không đoán độ hư hoặc an toàn thực phẩm.',
            },
            {
              'code': 0,
              'label': 'Xanh / chưa chín',
              'description': 'Nhãn giai đoạn từ nguồn dữ liệu.',
            },
            {
              'code': 1,
              'label': 'Chín',
              'description': 'Không chứng nhận độ ngon.',
            },
          ],
        },
        'sections': [
          {
            'id': 'counts',
            'title': 'Đọc số đếm',
            'body': 'Số đếm không phải khối lượng.',
          },
        ],
        'limitations': ['Không chứng nhận an toàn thực phẩm.'],
      };
    } else if (uri.path.endsWith('/branches/mine')) {
      response = {
        'items': [
          {
            'id': 'approved-branch',
            'name': 'Chi nhánh mẫu',
            'status': 'Approved',
          },
          {
            'id': 'pending-branch',
            'name': 'Chưa được duyệt',
            'status': 'Pending',
          },
        ],
      };
    } else if (uri.path.endsWith('/articles') && method == 'POST') {
      response = {'id': 'article-new', ...data!};
    } else if (uri.path.contains('/articles/article-one/conversations')) {
      response = {
        'id': 'conversation-one',
        'title': 'Trao đổi về bài xoài',
        'articleId': 'article-one',
        'kind': 'Direct',
      };
    } else if (uri.path.endsWith('/articles/article-one')) {
      response = {
        'id': 'article-one',
        'title': 'Kinh nghiệm quan sát xoài',
        'body': 'Nội dung chuyên môn thực tế.',
        'status': 'Published',
        'audienceLane': 'Professional',
        'author': {'id': 'other-author', 'displayName': 'Vườn mẫu'},
      };
    }
    return ApiReply(200, jsonEncode(response));
  }
}

class PhotoTransport implements MediaTransport {
  final calls = <(Uri, Map<String, String>, int)>[];
  @override
  Future<ApiReply> upload(
    Uri uri,
    Map<String, String> headers,
    File file,
    UploadCancellation cancellation,
    void Function(int, int)? progress,
  ) async {
    calls.add((uri, headers, await file.length()));
    return const ApiReply(201, '{"id":"image-one"}');
  }

  @override
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  ) async {
    calls.add((uri, headers, maxBytes));
    return BinaryReply(200, Uint8List.fromList([255, 216, 255, 217]));
  }

  @override
  void close() {}
}

class DraftPhotoPicker extends NativeMediaPicker {
  DraftPhotoPicker(this.photo);
  final PickedMedia photo;
  int deletions = 0;
  @override
  Future<PickedMedia?> pick(String method) async => photo;
  @override
  Future<void> delete(PickedMedia media) async {
    deletions++;
  }
}

class RetryArticleTransport extends MangoTransport {
  int saves = 0;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    final response = await super.send(method, uri, headers, body);
    if (method == 'PUT' &&
        uri.path.endsWith('/articles/article-existing') &&
        ++saves == 1) {
      return const ApiReply(
        503,
        '{"detail":"Lưu bài chưa thành công; hãy thử lại."}',
      );
    }
    return response;
  }
}

void main() {
  testWidgets(
    'confirmed image upload is reused when article save fails and user retries',
    (tester) async {
      await tester.runAsync(() async {
        Future<void> waitFor(bool Function() condition) async {
          for (var i = 0; i < 200 && !condition(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(condition(), isTrue);
        }

        final folder = await Directory.systemTemp.createTemp(
          'fv-article-retry-',
        );
        final photoFile = await File('${folder.path}/image.jpg')
            .writeAsBytes([255, 216, 255, 217]);
        final picker = DraftPhotoPicker(
          PickedMedia(
            path: photoFile.path,
            name: 'Ảnh chuẩn hóa.jpg',
            bytes: 4,
            mediaType: 'image',
            contentType: 'image/jpeg',
          ),
        );
        addTearDown(() async {
          await photoFile.delete();
          await folder.delete();
        });
        final source = RetryArticleTransport(),
            media = PhotoTransport(),
            api = ApiClient(
              baseUrl: 'https://example.test',
              transport: source,
              mediaTransport: media,
            );
        api.setTokens(
          TokenPair(
            'access',
            'refresh',
            DateTime.now().add(const Duration(minutes: 10)),
          ),
        );
        final c = SessionController(api: api, vault: ui.MemoryVault())
          ..loading = false
          ..user = Account.fromJson(ui.profile(UserRole.consumer));
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: PublicationEditor(
              controller: c,
              article: true,
              picker: picker,
              initial: {
                'id': 'article-existing',
                'title': 'Quan sát xoài trong vườn',
                'body': 'Chia sẻ kinh nghiệm quan sát tại vườn.',
                'audienceLane': 'Community',
                'revision': 2,
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Chọn ảnh bài viết'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Chọn ảnh bài viết'));
        await tester.pump();
        await waitFor(() => find.text('Gửi xét duyệt').evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        var expectedSaves = 0;
        Future<void> save() async {
          await tester.ensureVisible(find.text('Gửi xét duyệt'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Gửi xét duyệt'));
          expectedSaves++;
          await tester.pump();
          await waitFor(() => source.saves == expectedSaves);
          await waitFor(() => find.text('Đang gửi…').evaluate().isEmpty);
          await tester.pumpAndSettle();
        }

        await save();
        expect(media.calls, hasLength(1));
        expect(source.saves, 1);
        await save();
        expect(source.saves, 2);
        expect(
          media.calls,
          hasLength(1),
          reason: 'A confirmed owned image must be reused, rather than uploaded again after article failure.',
        );
        final saved = source.requests.where((r) => r.$1 == 'PUT').toList();
        expect(saved.every((r) => r.$3!['imageId'] == 'image-one'), isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );
  testWidgets(
    'Consumer learns real mango stages with text zoom and never requests AI',
    (tester) async {
      ui.narrowPhone(tester);
      final source = MangoTransport(),
          c = ui.controller(MangoTransport(), role: UserRole.consumer);
      // Use the same observed transport for all content requests.
      final session =
          SessionController(
              api: ApiClient(
                baseUrl: 'https://example.test',
                transport: source,
              ),
              vault: ui.MemoryVault(),
            )
            ..loading = false
            ..user = c.user;
      addTearDown(c.dispose);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangoLearningPage(
              controller: session,
              header: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hiểu về xoài'), findsOneWidget);
      await tester.tap(find.byTooltip('Phóng to chữ'));
      await tester.pumpAndSettle();
      expect(find.text('120%'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Chưa xác định'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Chưa xác định'), findsOneWidget);
      expect(source.requests.single.$2.path, '/api/v1/learning/mango');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final mango in [false, true]) {
    testWidgets(
      '${mango ? 'new mango' : 'archival'} counts retain their actual recorded scope',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AiResultCard(
                  mediaType: 'image',
                  result: {
                    if (mango) 'scope': 'predicted-mango-only',
                    'maxVisibleCount': 3,
                    'gradeCounts': {'Chín': 2, 'Chưa xác định': 1},
                    'objects': <Object>[],
                    'limitations': <String>[],
                  },
                ),
              ),
            ),
          ),
        );
        expect(find.text('3'), findsOneWidget);
        expect(
          find.text('Xoài dự đoán trong ảnh'),
          mango ? findsOneWidget : findsNothing,
        );
        expect(
          find.textContaining('Kết quả lưu trước bộ lọc xoài'),
          mango ? findsNothing : findsOneWidget,
        );
        expect(find.text('Xoài hư, không ăn được'), findsNothing);
        expect(find.text('Chưa xác định'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Professional article sends explicit approved branch and retains its current image on edit',
    (tester) async {
      ui.narrowPhone(tester);
      final source = MangoTransport();
      final c = ui.controller(source, role: UserRole.trader);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PublicationEditor(
            controller: c,
            article: true,
            initial: {
              'id': 'article-existing',
              'title': 'Chia sẻ quan sát xoài',
              'body': 'Kinh nghiệm quan sát trong vườn mẫu.',
              'audienceLane': 'Professional',
              'branchId': 'approved-branch',
              'revision': 4,
              'image': {'id': 'retained-image'},
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chưa được duyệt'), findsNothing);
      await enter(tester, 'Tiêu đề bài viết', 'Chia sẻ quan sát xoài mới');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Gửi xét duyệt'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Gửi xét duyệt'));
      await tester.pumpAndSettle();
      expect(find.text('Gửi xét duyệt').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Gửi xét duyệt'));
      await tester.pumpAndSettle();
      final saved = source.requests.singleWhere((r) => r.$1 == 'PUT').$3!;
      expect(saved['branchId'], 'approved-branch');
      expect(saved['imageId'], 'retained-image');
      expect(saved['expectedRevision'], 4);
      expect(saved.containsKey('estimatedQuantityKg'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'article contact opens server-derived normal conversation without fake local parties',
    (tester) async {
      final source = MangoTransport(),
          c = ui.controller(MangoTransport(), role: UserRole.consumer);
      final session =
          SessionController(
              api: ApiClient(
                baseUrl: 'https://example.test',
                transport: source,
              ),
              vault: ui.MemoryVault(),
            )
            ..loading = false
            ..user = c.user;
      addTearDown(c.dispose);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ArticlePage(controller: session, id: 'article-one'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trao đổi với tác giả'));
      await tester.pumpAndSettle();
      expect(
        source.requests.singleWhere((r) => r.$1 == 'POST').$2.path,
        '/api/v1/articles/article-one/conversations',
      );
      expect(source.requests.singleWhere((r) => r.$1 == 'POST').$3, isEmpty);
      expect(find.text('Trao đổi về bài xoài'), findsOneWidget);
      expect(find.byTooltip('Gửi tin nhắn'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('ordinary image APIs stream authenticated files to one origin with stable message id and bounded downloads', () async {
    final folder = await Directory.systemTemp.createTemp('fv-photo-api-test-'),
        media = PhotoTransport();
    final file = await File('${folder.path}/photo.jpg')
        .writeAsBytes([255, 216, 255, 217]);
    addTearDown(() async {
      await file.delete();
      await folder.delete();
    });
    final api = ApiClient(
      baseUrl: 'https://example.test',
      transport: MangoTransport(),
      mediaTransport: media,
    );
    addTearDown(api.close);
    api.setTokens(
      TokenPair(
        'access',
        'refresh',
        DateTime.now().add(const Duration(minutes: 10)),
      ),
    );
    await api.uploadArticleImage(file, 'image/jpeg');
    await api.sendChatImage(
      'conversation-one',
      'client_same_123',
      file,
      'image/jpeg',
    );
    await api.articleImageBytes('article-one');
    await api.chatImageBytes('conversation-one', 'image-one');
    expect(media.calls.map((c) => c.$1.host).toSet(), {'example.test'});
    expect(
      media.calls.every((c) => c.$2['Authorization'] == 'Bearer access'),
      isTrue,
    );
    expect(
      media.calls[1].$1.queryParameters['clientMessageId'],
      'client_same_123',
    );
    expect(media.calls[2].$3, 5 * 1024 * 1024);
    final oversized = await file.open(mode: FileMode.write);
    await oversized.truncate(5 * 1024 * 1024 + 1);
    await oversized.close();
    await expectLater(
      api.sendChatImage(
        'conversation-one',
        'client_same_123',
        file,
        'image/jpeg',
      ),
      throwsA(isA<ApiException>()),
    );
    expect(media.calls, hasLength(4));
  });
  test(
    'professional moderation uses separate backend lane on the shared endpoint',
    () {
      expect(ReviewKind.professionalArticles.path, 'articles');
      expect(ReviewKind.professionalArticles.laneQuery, '&lane=Professional');
      expect(ReviewKind.articles.laneQuery, '&lane=Community');
    },
  );
}
