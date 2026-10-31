import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/ui/workspace.dart';
import 'package:fruitvision_client/client/ui/chat.dart';
import 'package:fruitvision_client/client/ui/new_message.dart';
import 'package:fruitvision_client/client/ui/profile.dart';

import 'ui_test.dart' as fixtures;

class ProfileTransport extends fixtures.UiTransport {
  final writes = <(String, Uri, Map<String, dynamic>?)>[];
  bool blocked = true;
  final own = <String, dynamic>{
    ...fixtures.profile(UserRole.consumer),
    'bio': 'Chia sẻ kinh nghiệm về xoài',
    'gender': 'Unknown',
    'phone': '',
    'showGender': false,
    'showPhone': false,
    'showRegion': true,
    'roleDetails': {
      'establishmentName': 'Đơn vị đã duyệt',
      'taxCode': 'PRIVATE-TAX',
    },
  };
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (method != 'GET') {
      writes.add((
        method,
        uri,
        body == null ? null : jsonDecode(body) as Map<String, dynamic>,
      ));
    }
    if (uri.path.endsWith('/profile')) {
      if (method == 'PUT') {
        own.addAll(jsonDecode(body!) as Map<String, dynamic>);
      }
      return ApiReply(200, jsonEncode(own));
    }
    if (uri.path.endsWith('/me')) return ApiReply(200, jsonEncode(own));
    if (uri.path.endsWith('/profile/blocked')) {
      return ApiReply(
        200,
        jsonEncode({
          'items': blocked
              ? [
                  {
                    'id': 'peer-one',
                    'displayName': 'Lan Nguyễn',
                    'role': 'Producer',
                  },
                ]
              : [],
        }),
      );
    }
    if (uri.path.endsWith('/profiles/peer-one/block')) {
      blocked = method == 'PUT';
      return const ApiReply(200, '{}');
    }
    if (uri.path.endsWith('/profiles/peer-one')) {
      return const ApiReply(
        200,
        '{"id":"peer-one","displayName":"Lan Nguyễn","role":"Producer","bio":"Kinh nghiệm về xoài","email":"private@example.test"}',
      );
    }
    if (uri.path.endsWith('/contacts')) {
      return const ApiReply(
        200,
        '{"items":[{"id":"peer-one","displayName":"Lan Nguyễn","role":"Producer"}]}',
      );
    }
    if (uri.path.endsWith('/context')) {
      return const ApiReply(
        200,
        '{"kind":"Direct","title":"Lan","peer":{"id":"peer-one","displayName":"Lan Nguyễn","role":"Producer"},"secretEligible":false}',
      );
    }
    return const ApiReply(200, '{"items":[]}');
  }
}

void main() {
  testWidgets('account exposes personal profile and privacy editing', (
    tester,
  ) async {
    final session = fixtures.controller(
      ProfileTransport(),
      role: UserRole.consumer,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPage(
            controller: session,
            header: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hồ sơ & quyền riêng tư'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets('chat exposes verified peer profile without inferring identity', (
    tester,
  ) async {
    final session = fixtures.controller(
      ProfileTransport(),
      role: UserRole.consumer,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(controller: session, id: 'direct-one', title: 'Lan'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Xem hồ sơ người trao đổi'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets('normal contact list offers profile separately from messaging', (
    tester,
  ) async {
    final session = fixtures.controller(
      ProfileTransport(),
      role: UserRole.consumer,
    );
    await tester.pumpWidget(
      MaterialApp(home: NewMessagePage(controller: session)),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Xem hồ sơ Lan Nguyễn'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });
  testWidgets(
    'private editing sends only self-editable fields and keeps reviewed role data read only',
    (tester) async {
      fixtures.narrowPhone(tester);
      final source = ProfileTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(home: OwnProfilePage(controller: session)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('minh@example.test'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Tên hiển thị'),
        'Tên mới của tôi',
      );
      await tester.scrollUntilVisible(
        find.byType(DropdownButtonFormField<String>),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Lưu hồ sơ'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lưu hồ sơ'));
      await tester.pumpAndSettle();
      final save = source.writes.single;
      expect(save.$1, 'PUT');
      expect(save.$2.path, '/api/v1/profile');
      expect(save.$3, {
        'displayName': 'Tên mới của tôi',
        'bio': 'Chia sẻ kinh nghiệm về xoài',
        'phone': '',
        'gender': 'Unknown',
        'showGender': false,
        'showPhone': false,
        'showRegion': true,
      });
      expect(find.text('Đã lưu hồ sơ và quyền riêng tư.'), findsOneWidget);
      expect(source.writes.single.$3!.keys, isNot(contains('role')));
      expect(source.writes.single.$3!.keys, isNot(contains('region')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets(
    'public profile never renders private email or missing privacy-controlled fields',
    (tester) async {
      final source = ProfileTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(
          home: UserProfilePage(controller: session, userId: 'peer-one'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lan Nguyễn'), findsOneWidget);
      expect(find.textContaining('private@example.test'), findsNothing);
      expect(find.textContaining('Điện thoại:'), findsNothing);
      expect(find.textContaining('Khu vực:'), findsNothing);
      expect(find.textContaining('PRIVATE-TAX'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets(
    'block requires explicit confirmation, uses the target ID, and returns to previous screen',
    (tester) async {
      final source = ProfileTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) => UserProfilePage(
                      controller: session,
                      userId: 'peer-one',
                    ),
                  ),
                ),
                child: const Text('Mở hồ sơ'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mở hồ sơ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chặn người dùng'));
      await tester.pumpAndSettle();
      expect(source.writes, isEmpty);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(source.writes, isEmpty);
      await tester.tap(find.text('Chặn người dùng'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận chặn'));
      await tester.pumpAndSettle();
      expect(source.writes.single.$1, 'PUT');
      expect(source.writes.single.$2.path, '/api/v1/profiles/peer-one/block');
      expect(source.writes.single.$3, isEmpty);
      expect(find.text('Mở hồ sơ'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets(
    'blocked list offers explicit unblock and reloads server result',
    (tester) async {
      final source = ProfileTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(home: BlockedProfilesPage(controller: session)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lan Nguyễn'), findsOneWidget);
      await tester.tap(find.text('Bỏ chặn'));
      await tester.pumpAndSettle();
      expect(source.writes, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Bỏ chặn'));
      await tester.pumpAndSettle();
      expect(source.writes.single.$1, 'DELETE');
      expect(source.writes.single.$2.path, '/api/v1/profiles/peer-one/block');
      expect(find.text('Bạn chưa chặn người dùng nào.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
  testWidgets(
    'blocking verified chat peer disables future direct sending and keeps history UI',
    (tester) async {
      final source = ProfileTransport();
      final session = fixtures.controller(source, role: UserRole.consumer);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(controller: session, id: 'direct-one', title: 'Lan'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Xem hồ sơ người trao đổi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chặn người dùng'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận chặn'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.textContaining('Bạn đã chặn người này.'), findsOneWidget);
      expect(find.text('Nhóm đã đóng và chưa có tin nhắn.'), findsNothing);
      expect(source.writes.single.$2.path, '/api/v1/profiles/peer-one/block');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
}
