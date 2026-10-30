import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/app.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/vault.dart';
import 'package:fruitvision_client/client/ui/workspace.dart';

class UiSocket implements HubSocket {
  final input = StreamController<Object>();
  bool closed = false;
  @override
  Stream<Object> get messages => input.stream;
  @override
  void send(String message) {
    final json = jsonDecode(
      message.split(recordSeparator).first,
    ) as Map<String, dynamic>;
    if (json['protocol'] == 'json') {
      scheduleMicrotask(() {
        if (!closed) input.add('{}$recordSeparator');
      });
    }
  }

  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      await input.close();
    }
  }
}

FruitVisionApp testApp(SessionController c) => FruitVisionApp(
  controller: c,
  realtimeConnector: (_, _) async => UiSocket(),
);
Future<void> showTestApp(WidgetTester tester, SessionController c) async {
  await tester.pumpWidget(testApp(c));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class MemoryVault implements SessionVault {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> next) async {
    value = next;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

Map<String, dynamic> profile(UserRole role, {String approval = 'Approved'}) => {
  'id': 'account-${role.wire}',
  'displayName': 'Nguyễn Văn Minh',
  'email': 'minh@example.test',
  'role': role.wire,
  'approvalStatus': approval,
  'region': 'Đồng Tháp',
  'isActive': true,
  'reviewReason': approval == 'NeedsInformation'
      ? 'Bổ sung tên khu vực sản xuất.'
      : null,
};

class UiTransport implements ApiTransport {
  final calls = <String>[];
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    calls.add('$method ${uri.path}');
    final path = uri.path;
    Object data = {'items': <Object>[]};
    if (path.endsWith('/admin/stats')) {
      data = {
        'users': 7,
        'pendingApplications': 2,
        'posts': 8,
        'messages': 9,
        'activeSessions': 1,
      };
    } else if (path.endsWith('/ai/capabilities')) {
      data = {
        'aiReady': true,
        'modelName': 'Mô hình kiểm thử',
        'maxImageBytes': 12582912,
        'maxVideoBytes': 83886080,
      };
    } else if (path.endsWith('/auth/login')) {
      data = {'requiresTwoFactor': true, 'challengeToken': 'test-challenge'};
    } else if (path.endsWith('/auth/mfa/login')) {
      data = {
        'accessToken': 'test-access',
        'refreshToken': 'test-refresh',
        'expiresIn': 900,
        'user': profile(UserRole.admin),
      };
    }
    return ApiReply(200, jsonEncode(data));
  }

  @override
  void close() {}
}

SessionController controller(
  UiTransport transport, {
  UserRole? role,
  String approval = 'Approved',
}) =>
    SessionController(
        api: ApiClient(baseUrl: 'https://example.test', transport: transport),
        vault: MemoryVault(),
      )
      ..loading = false
      ..user = role == null
          ? null
          : Account.fromJson(profile(role, approval: approval));

void narrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.4;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

void main() {
  testWidgets(
    'forecast cards emphasize actual quantity and expand long content at narrow width',
    (tester) async {
      narrowPhone(tester);
      final body = List.filled(
        12,
        'Thông tin dự kiến từ nhà sản xuất, chưa xác nhận tồn kho.',
      ).join(' ');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                PostCard(
                  row: {
                    'title': 'Xoài dự kiến tại Đồng Tháp',
                    'body': body,
                    'productCode': 'mango',
                    'estimatedQuantityKg': 226.25,
                    'author': {
                      'displayName': 'Nhà sản xuất',
                      'region': 'Đồng Tháp',
                    },
                    'status': 'Published',
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('226.25'), findsOneWidget);
      final collapsed = tester.getSize(find.byType(Card)).height;
      await tester.ensureVisible(find.text('Đọc tiếp'));
      await tester.tap(find.text('Đọc tiếp'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Card)).height, greaterThan(collapsed));
      expect(find.text('Thu gọn'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final role in UserRole.values) {
    testWidgets('${role.wire}: role-specific navigation fits narrow screen', (
      tester,
    ) async {
      narrowPhone(tester);
      final transport = UiTransport();
      final c = controller(transport, role: role);
      addTearDown(c.dispose);
      await showTestApp(tester, c);
      await tester.pumpAndSettle();
      final labels = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((destination) => destination.label)
          .toList();
      final expected = switch (role) {
        UserRole.admin => ['Xét duyệt', 'Trao đổi', 'Tài khoản'],
        UserRole.producer ||
        UserRole.trader => ['AI xoài', 'Kiến thức', 'Trao đổi', 'Tài khoản'],
        UserRole.consumer => ['Học về xoài', 'Cộng đồng', 'Tài khoản'],
      };
      expect(labels, expected);
      if (role == UserRole.admin) {
        expect(
          transport.calls.where((call) => call.contains('/admin/applications')),
          isEmpty,
        );
        expect(find.text('Duyệt nâng vai trò'), findsOneWidget);
      }
      expect(find.text('Tạo tin dự kiến'), findsNothing);
      if (role == UserRole.producer || role == UserRole.trader) {
        expect(find.text('Chọn ảnh'), findsOneWidget);
        expect(find.text('Chọn video'), findsOneWidget);
        expect(find.text('Chụp ảnh'), findsOneWidget);
      } else {
        expect(find.text('AI'), findsNothing);
        expect(transport.calls.where((call) => call.contains('/ai/')), isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('auth and signup remain scrollable at 320px and text scale 1.4', (
    tester,
  ) async {
    narrowPhone(tester);
    final c = controller(UiTransport());
    addTearDown(c.dispose);
    await showTestApp(tester, c);
    await tester.pumpAndSettle();
    final signup = find.text('Chưa có tài khoản? Đăng ký');
    await tester.ensureVisible(signup);
    await tester.tap(signup);
    await tester.pumpAndSettle();
    expect(find.text('Xác nhận mật khẩu'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<UserRole>), findsNothing);
    expect(find.textContaining('Người tiêu dùng'), findsWidgets);
    final submit = find.text('Gửi đăng ký');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('Mật khẩu cần ít nhất 12 ký tự.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MFA login keeps user signed out until six-digit challenge completes',
    (tester) async {
      narrowPhone(tester);
      final transport = UiTransport();
      final c = controller(transport);
      addTearDown(c.dispose);
      await showTestApp(tester, c);
      await c.login('admin@example.test', 'a-password-used-only-in-test');
      await tester.pumpAndSettle();
      expect(c.signedIn, isFalse);
      expect(find.text('Mã xác thực'), findsOneWidget);
      expect(find.text('Mật khẩu'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.enterText(find.byType(TextFormField), '123456');
      final submit = find.text('Xác thực và đăng nhập');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(c.signedIn, isTrue);
      expect(c.user!.role, UserRole.admin);
      expect(
        transport.calls.where((p) => p.endsWith('/auth/mfa/login')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legacy needs-information profile exposes read-only reason', (
    tester,
  ) async {
    narrowPhone(tester);
    final c = controller(
      UiTransport(),
      role: UserRole.producer,
      approval: 'NeedsInformation',
    );
    addTearDown(c.dispose);
    await showTestApp(tester, c);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Bổ sung tên khu vực sản xuất.'),
      findsOneWidget,
    );
    expect(find.text('Bổ sung và gửi lại'), findsNothing);
    expect(find.text('Tạo tin dự kiến'), findsNothing);
    await tester.scrollUntilVisible(
      find.text(
        'Tài khoản cần được duyệt và đang hoạt động để dùng phân tích AI.',
      ),
      150,
    );
    expect(
      find.text(
        'Tài khoản cần được duyệt và đang hoạt động để dùng phân tích AI.',
      ),
      findsOneWidget,
    );
    expect(find.text('Chọn ảnh'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
