import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/ui/components.dart';
import 'package:fruitvision_client/client/ui/community.dart';
import 'package:fruitvision_client/client/ui/role_applications.dart';
import 'package:fruitvision_client/client/ui/chat.dart';
import 'package:fruitvision_client/client/ui/mango_learning.dart';
import 'package:fruitvision_client/client/ui/moderation.dart';
import 'package:fruitvision_client/client/ui/realtime_scope.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/session.dart';

import 'ui_test.dart' as old;
import 'workflows_2_3_test.dart' show WorkflowTransport;
import 'mango_media_test.dart' show MangoTransport;
import 'ai_test.dart' show EventHub;

class QueueFeedbackTransport extends old.UiTransport {
  final first = Completer<ApiReply>();
  final queueUris = <Uri>[];
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/admin/role-applications')) {
      queueUris.add(uri);
      if (queueUris.length == 1) return first.future;
      return ApiReply(
        200,
        jsonEncode({
          'items': [
            {
              'id': 'application-one',
              'requestedRole': 'Producer',
              'status': 'Submitted',
              'organisationName': 'Vườn mẫu',
              'submittedAt': '2026-10-31T10:00:00Z',
              'createdAt': '2026-10-30T09:00:00Z',
              'applicant': {
                'id': 'applicant-one',
                'displayName': 'Nguyễn Thị Lan',
                'role': 'Consumer',
              },
            },
          ],
        }),
      );
    }
    return super.send(method, uri, headers, body);
  }
}

class InlinePhotoTransport extends old.UiTransport {
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async => uri.path.endsWith('/messages')
      ? ApiReply(
          200,
          jsonEncode({
            'items': [
              {
                'id': 'message-photo',
                'senderId': 'other',
                'text': '[Hình ảnh]',
                'createdAt': '2026-10-31T10:00:00Z',
                'sender': {
                  'id': 'other',
                  'displayName': 'Lan',
                  'role': 'Producer',
                },
                'image': {
                  'id': 'image-one',
                  'contentType': 'image/jpeg',
                  'width': 1,
                  'height': 1,
                  'sizeBytes': 80,
                },
              },
            ],
          }),
        )
      : super.send(method, uri, headers, body);
}

class InlineMedia implements MediaTransport {
  final downloads = <(Uri, Map<String, String>, int)>[];
  @override
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  ) async {
    downloads.add((uri, headers, maxBytes));
    return BinaryReply(
      200,
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      ),
    );
  }

  @override
  Future<ApiReply> upload(
    Uri uri,
    Map<String, String> headers,
    File file,
    UploadCancellation cancellation,
    void Function(int, int)? progress,
  ) => throw UnimplementedError();
  @override
  void close() {}
}

class SubmitFeedbackTransport extends WorkflowTransport {
  SubmitFeedbackTransport() {
    application = {
      ...application,
      'organisationName': 'Vườn xoài mẫu',
      'address': 'Đường Hoa số 10',
      'countryCode': 'VN',
      'provinceCode': '82',
      'phone': '0901234567',
      'products': ['MANGO'],
      'cultivatedAreaHa': 2.5,
      'revision': 3,
      'evidence': [
        {'id': 'proof-one', 'contentType': 'image/jpeg', 'sizeBytes': 1024},
      ],
    };
  }
  bool fail = true;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.contains('/role-applications/') &&
        (method == 'PUT' || uri.path.endsWith('/submit'))) {
      final data = jsonDecode(body!) as Map<String, dynamic>;
      mutations.add({'method': method, 'path': uri.path, ...data});
      if (uri.path.endsWith('/submit')) {
        if (fail) {
          return const ApiReply(
            503,
            '{"detail":"Chưa gửi được hồ sơ; hãy thử lại."}',
          );
        }
        application = {
          ...application,
          'status': 'Submitted',
          'revision': (application['revision'] as int) + 1,
          'submittedAt': '2026-10-31T10:00:00Z',
        };
      } else {
        application = {
          ...application,
          ...data,
          'revision': (application['revision'] as int) + 1,
        };
      }
      return ApiReply(200, jsonEncode(application));
    }
    return super.send(method, uri, headers, body);
  }
}

void main() {
  testWidgets(
    'Admin submitted queue uses modern endpoint, displays applicant and survives an older empty response',
    (tester) async {
      final source = QueueFeedbackTransport(),
          c = old.controller(source, role: UserRole.admin),
          hub = EventHub(c.api);
      addTearDown(() {
        hub.dispose();
        c.dispose();
      });
      await tester.pumpWidget(
        RealtimeScope(
          client: hub,
          child: MaterialApp(
            home: ReviewListPage(controller: c, kind: ReviewKind.roles),
          ),
        ),
      );
      await tester.pump();
      expect(source.queueUris.single.path, '/api/v1/admin/role-applications');
      expect(source.queueUris.single.queryParameters['status'], 'Submitted');
      hub.updates.add(
        const HubEvent('RoleApplicationChanged', {
          'id': 'application-one',
          'status': 'Submitted',
          'revision': 4,
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(source.queueUris, hasLength(2));
      expect(find.text('Nguyễn Thị Lan'), findsOneWidget);
      source.first.complete(const ApiReply(200, '{"items":[]}'));
      await tester.pumpAndSettle();
      expect(find.text('Nguyễn Thị Lan'), findsOneWidget);
      expect(find.text('Không có hồ sơ trong trạng thái này.'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'normal chat renders an authenticated bounded inline image and opens zoom',
    (tester) async {
      final media = InlineMedia(),
          api = ApiClient(
            baseUrl: 'https://example.test',
            transport: InlinePhotoTransport(),
            mediaTransport: media,
          );
      api.setTokens(
        TokenPair(
          'access',
          'refresh',
          DateTime.now().add(const Duration(minutes: 10)),
        ),
      );
      final c = SessionController(api: api, vault: old.MemoryVault())
        ..loading = false
        ..user = Account.fromJson(old.profile(UserRole.consumer));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            controller: c,
            id: 'conversation-one',
            title: 'Hội thoại ảnh',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(media.downloads, hasLength(1));
      expect(
        media.downloads.single.$1.path,
        '/api/v1/conversations/conversation-one/images/image-one',
      );
      expect(media.downloads.single.$2['Authorization'], 'Bearer access');
      expect(media.downloads.single.$3, 5 * 1024 * 1024);
      final provider =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(provider.width, lessThanOrEqualTo(512));
      expect(provider.height, lessThanOrEqualTo(512));
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'mango lessons expose a source-bound comprehension checklist and quiz without inference',
    (tester) async {
      old.narrowPhone(tester);
      final source = MangoTransport(),
          c = old.controller(source, role: UserRole.consumer);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangoLearningPage(
              controller: c,
              header: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Tự kiểm tra cách hiểu'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tự kiểm tra cách hiểu'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chưa xác định'), findsWidgets);
      expect(find.text('Chưa đủ tin cậy để gán giai đoạn.'), findsOneWidget);
      expect(source.requests.where((r) => r.$2.path.contains('/ai/')), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Draft with uploaded proof has a visible submit action and only successful submit announces sent',
    (tester) async {
      old.narrowPhone(tester);
      final source = SubmitFeedbackTransport(),
          session = old.controller(
            SubmitFeedbackTransport(),
            role: UserRole.consumer,
          );
      final c =
          SessionController(
              api: ApiClient(
                baseUrl: 'https://example.test',
                transport: source,
              ),
              vault: old.MemoryVault(),
            )
            ..loading = false
            ..user = session.user;
      addTearDown(c.dispose);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RoleApplicationPage(controller: c, id: 'application-one'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Bản nháp · Chưa gửi'), findsOneWidget);
      final send = find.widgetWithText(FilledButton, 'Gửi xét duyệt');
      expect(send.hitTestable(), findsOneWidget);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(source.mutations.last['expectedRevision'], 4);
      expect(source.application['status'], 'Draft');
      expect(find.textContaining('Đã gửi xét duyệt.'), findsNothing);
      expect(find.textContaining('Máy chủ tạm thời không sẵn sàng'), findsOneWidget);
      source.fail = false;
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(source.mutations.last['expectedRevision'], 5);
      expect(source.application['status'], 'Submitted');
      expect(find.textContaining('Đã gửi xét duyệt.'), findsOneWidget);
      expect(find.text('Gửi xét duyệt'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'server configuration is absent at sign in and for ordinary accounts',
    (tester) async {
      final signedOut = old.controller(old.UiTransport());
      addTearDown(signedOut.dispose);
      await old.showTestApp(tester, signedOut);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cài đặt máy chủ'), findsNothing);
      for (final role in [
        UserRole.consumer,
        UserRole.producer,
        UserRole.trader,
      ]) {
        final c = old.controller(old.UiTransport(), role: role);
        await tester.pumpWidget(old.testApp(c));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(NavigationDestination).last);
        await tester.pumpAndSettle();
        expect(find.text('Cài đặt máy chủ'), findsNothing);
        expect(find.textContaining('https://example.test'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      }
    },
  );
  testWidgets('only Admin sees group creation and server operator controls', (
    tester,
  ) async {
    for (final role in UserRole.values) {
      final c = old.controller(old.UiTransport(), role: role);
      await tester.pumpWidget(MaterialApp(home: CommunityPage(controller: c)));
      await tester.pumpAndSettle();
      expect(
        find.text('Tạo nhóm'),
        role == UserRole.admin ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    }
  });
  testWidgets(
    'non Admin direct server settings route exposes no address or URL field',
    (tester) async {
      final c = old.controller(old.UiTransport(), role: UserRole.consumer);
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: ServerSettings(controller: c)));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      expect(find.textContaining('example.test'), findsNothing);
    },
  );
  test('ordinary API errors hide URLs and connection internals but retain validation instructions', () {
    expect(
      errorText(
        const ApiException(
          'Không kết nối https://private.example/api/v1/users: SocketException',
        ),
      ),
      isNot(contains('private.example')),
    );
    expect(
      errorText(
        const ApiException(
          'Không kết nối https://private.example/api/v1/users: SocketException',
        ),
      ),
      isNot(contains('SocketException')),
    );
    expect(
      errorText(const ApiException('Cần ít nhất một chứng từ.')),
      'Cần ít nhất một chứng từ.',
    );
  });
}
