import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/app.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/vault.dart';

class FlowVault implements SessionVault {
  @override
  Future<Map<String, dynamic>?> read() async => null;
  @override
  Future<void> write(Map<String, dynamic> value) async {}
  @override
  Future<void> clear() async {}
}

class FlowTransport implements ApiTransport {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  bool conflict = false;
  String postStatus = 'AwaitingReview';
  int revision = 1;
  bool joined = false, groupOpen = true;
  bool groupOwned = false;
  String groupTitle = 'Nhóm xoài Đồng Tháp';
  Map<String, dynamic> get post => {
    'id': 'post-one',
    'title': 'Xoài Đồng Tháp vụ mới',
    'body': 'Thông tin đầy đủ về lô nông sản dự kiến; liên hệ để trao đổi, chưa có tồn kho xác nhận.',
    'productCode': 'mango',
    'status': postStatus,
    'sourceType': 'Forecast',
    'estimatedQuantityKg': 150,
    'region': 'Đồng Tháp',
    'purpose': 'Supply',
    'availableOn': '2026-11-15',
    'priceMinVndPerKg': 20000,
    'priceMaxVndPerKg': 25000,
    'revision': revision,
    'createdAt': '2026-10-30T10:00:00Z',
    'author': {
      'id': 'producer-one',
      'displayName': 'Nhà vườn Đồng Tháp',
      'region': 'Đồng Tháp',
    },
  };
  Map<String, dynamic> get group => {
    'id': 'group-one',
    'title': groupTitle,
    'kind': 'Group',
    'ownerId': groupOwned ? 'consumer-one' : 'producer-one',
    'region': 'Đồng Tháp',
    'productCode': 'mango',
    'isOpen': groupOpen,
    'createdAt': '2026-10-30T10:00:00Z',
    'memberCount': joined ? 2 : 1,
    'isMember': joined,
    'currentRole': groupOwned
        ? 'Owner'
        : joined
        ? 'Member'
        : 'NonMember',
  };
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    final path = uri.path.replaceFirst('/api/v1', '');
    final json = body == null ? null : jsonDecode(body) as Map<String, dynamic>;
    calls.add((method, path, json));
    Object result = {'items': <Object>[]};
    if (path == '/catalog/products') {
      result = {
        'items': [
          {'code': 'mango', 'name': 'Xoài'},
        ],
      };
    }
    if (path == '/ai/capabilities') {
      result = {
        'aiReady': false,
        'message': 'AI chưa mở trong ca kiểm thử nghiệp vụ.',
      };
    }
    if (path == '/posts' || path == '/admin/posts' || path == '/me/posts') {
      result = {
        'items': [post],
      };
    }
    if (path == '/posts/post-one') result = post;
    if (path == '/admin/posts/post-one/review') {
      if (conflict) {
        conflict = false;
        revision = 2;
        postStatus = 'Published';
        return const ApiReply(
          409,
          '{"detail":"Tin đã được xét duyệt ở phiên khác."}',
        );
      }
      revision++;
      postStatus = json!['status'] as String;
      result = post;
    }
    if (path == '/posts/post-one/conversations') {
      result = {
        'id': 'direct-one',
        'title': 'Trao đổi về xoài Đồng Tháp',
        'postId': 'post-one',
        'kind': 'Direct',
      };
    }
    if (path == '/community/groups') {
      result = {
        'items': [group],
      };
    }
    if (path == '/community/groups' && method == 'POST') {
      groupOwned = true;
      joined = true;
      groupTitle = json!['title'] as String;
      result = group;
    }
    if (path == '/community/groups/group-one') result = group;
    if (path == '/community/groups/group-one/join') {
      joined = true;
      result = group;
    }
    if (path == '/community/groups/group-one/leave') {
      joined = false;
      result = group;
    }
    if (path == '/community/groups/group-one/close') {
      groupOpen = false;
      result = group;
    }
    if (path == '/market/summary') {
      result = {
        'region': 'Đồng Tháp',
        'productCode': 'mango',
        'asOf': '2026-10-30T10:00:00Z',
        'source': 'Giá chào trong tin đã công bố',
        'isForecast': false,
        'items': [
          {
            'productCode': 'mango',
            'productName': 'Xoài',
            'region': 'Đồng Tháp',
            'supplyEstimatedKg': 150,
            'demandEstimatedKg': 200,
            'supplyPostCount': 1,
            'demandPostCount': 2,
            'contributorCount': 2,
            'referencePriceVndPerKg': null,
            'priceMinVndPerKg': null,
            'priceMaxVndPerKg': null,
            'priceSampleCount': 0,
            'lastUpdated': '2026-10-30T10:00:00Z',
          },
        ],
        'limitations': [
          'Chỉ phản ánh tin đã công bố, không phải giá thị trường chính thức.',
        ],
      };
    }
    return ApiReply(method == 'POST' ? 201 : 200, jsonEncode(result));
  }

  @override
  void close() {}
}

Future<FlowTransport> showFlow(
  WidgetTester tester,
  UserRole role, {
  bool conflict = false,
  FlowTransport? source,
}) async {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.4;
  final transport = (source ?? FlowTransport())..conflict = conflict;
  if (role != UserRole.admin) transport.postStatus = 'Published';
  final c =
      SessionController(
          api: ApiClient(baseUrl: 'https://example.test', transport: transport),
          vault: FlowVault(),
        )
        ..loading = false
        ..user = Account(
          id: '${role.wire.toLowerCase()}-one',
          displayName: 'Người dùng',
          email: 'u@example.test',
          role: role,
          approvalStatus: ApprovalStatus.approved,
          region: 'Đồng Tháp',
          isActive: true,
        );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    c.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(FruitVisionApp(controller: c));
  await tester.pumpAndSettle();
  return transport;
}

Future<void> reveal(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      180,
      maxScrolls: 20,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String label) async {
  await reveal(tester, label);
  final finder = find.text(label);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Admin reviews real post with revision and reloads a conflicting server snapshot',
    (tester) async {
      final transport = await showFlow(tester, UserRole.admin, conflict: true);
      await press(tester, 'Duyệt tin nông sản');
      await press(tester, 'Xoài Đồng Tháp vụ mới');
      await tester.enterText(
        find.byType(TextFormField).last,
        'Đủ thông tin để công bố.',
      );
      await press(tester, 'Công bố tin');
      expect(
        transport.calls
            .where((call) => call.$2.endsWith('/review'))
            .single
            .$3!['expectedRevision'],
        1,
      );
      expect(find.textContaining('Tin đã được xét duyệt'), findsOneWidget);
      expect(find.text('Đã công bố'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Consumer contact derives conversation on server and opens actual chat',
    (tester) async {
      final transport = await showFlow(tester, UserRole.consumer);
      await press(tester, 'Xoài Đồng Tháp vụ mới');
      await press(tester, 'Liên hệ người đăng');
      final call = transport.calls
          .where((call) => call.$2 == '/posts/post-one/conversations')
          .single;
      expect(call.$3, isEmpty);
      expect(find.byTooltip('Gửi tin nhắn'), findsOneWidget);
      expect(find.text('Trao đổi về xoài Đồng Tháp'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Consumer market route uses actual asking samples and never turns absent price into zero',
    (tester) async {
      await showFlow(tester, UserRole.consumer);
      await press(tester, 'Giá & nguồn cung');
      expect(
        find.textContaining('không phải giá thị trường chính thức'),
        findsWidgets,
      );
      await reveal(tester, 'Chưa đủ dữ liệu giá');
      expect(find.text('Chưa đủ dữ liệu giá'), findsOneWidget);
      expect(find.text('0 đ/kg'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Community join calls group endpoint before opening group messages',
    (tester) async {
      final transport = await showFlow(tester, UserRole.consumer);
      await tester.tap(find.byType(NavigationDestination).at(2));
      await tester.pumpAndSettle();
      await press(tester, 'Nhóm cộng đồng');
      await press(tester, 'Nhóm xoài Đồng Tháp');
      await press(tester, 'Tham gia và trò chuyện');
      expect(
        transport.calls.any(
          (call) =>
              call.$1 == 'POST' &&
              call.$2 == '/community/groups/group-one/join',
        ),
        isTrue,
      );
      expect(
        transport.calls.any(
          (call) =>
              call.$1 == 'GET' &&
              call.$2 == '/conversations/group-one/messages',
        ),
        isTrue,
      );
      expect(find.byTooltip('Gửi tin nhắn'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await press(tester, 'Rời nhóm');
      expect(transport.joined, isFalse);
      expect(find.text('Tham gia và trò chuyện'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Community owner creates and closes a real group; closed chat is read only',
    (tester) async {
      final transport = await showFlow(tester, UserRole.consumer);
      await tester.tap(find.byType(NavigationDestination).at(2));
      await tester.pumpAndSettle();
      await press(tester, 'Nhóm cộng đồng');
      await press(tester, 'Tạo nhóm');
      await tester.enterText(
        find.byType(TextFormField).first,
        'Nhóm trao đổi do tôi tạo',
      );
      await press(tester, 'Tạo nhóm cộng đồng');
      expect(
        transport.calls
            .where(
              (call) => call.$1 == 'POST' && call.$2 == '/community/groups',
            )
            .single
            .$3!['title'],
        'Nhóm trao đổi do tôi tạo',
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Rời nhóm'),
            )
            .onPressed,
        isNull,
      );
      await press(tester, 'Đóng nhóm');
      await tester.tap(find.widgetWithText(FilledButton, 'Đóng nhóm'));
      await tester.pumpAndSettle();
      expect(find.text('Đã đóng'), findsOneWidget);
      await press(tester, 'Mở hội thoại nhóm');
      expect(find.text('Nhóm đã đóng; chỉ xem lịch sử'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await press(tester, 'Rời nhóm');
      expect(transport.joined, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'market latest search wins when an older request completes afterward; failed query can retry',
    (tester) async {
      final source = MarketRaceTransport();
      await showFlow(tester, UserRole.consumer, source: source);
      await press(tester, 'Giá & nguồn cung');
      await tester.enterText(find.byType(TextField).first, 'Đợt cũ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'Đợt mới');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      source.old.complete(
        ApiReply(200, jsonEncode(marketSnapshot('Đợt cũ', 'Xoài dữ liệu cũ'))),
      );
      await tester.pumpAndSettle();
      await reveal(tester, 'Xoài dữ liệu mới');
      expect(find.text('Xoài dữ liệu mới'), findsOneWidget);
      expect(find.text('Xoài dữ liệu cũ'), findsNothing);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -180,
        maxScrolls: 20,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Đợt lỗi');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('Thử lại'), findsOneWidget);
      await press(tester, 'Thử lại');
      await reveal(tester, 'Xoài sau thử lại');
      expect(find.text('Xoài sau thử lại'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final role in [UserRole.producer, UserRole.trader]) {
    testWidgets(
      '${role.wire} submits intended purpose with paired asking prices',
      (tester) async {
        final transport = await showFlow(tester, role);
        if (role == UserRole.trader) await press(tester, 'Tin dự kiến của tôi');
        await press(tester, 'Tạo tin dự kiến');
        if (role == UserRole.trader) {
          expect(find.text('Nhu cầu thu mua'), findsOneWidget);
        } else {
          expect(find.text('Nhu cầu thu mua'), findsNothing);
        }
        final product = find.byType(DropdownButtonFormField<String>).first;
        await tester.ensureVisible(product);
        await tester.pumpAndSettle();
        await tester.tap(product);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xoài').last);
        await tester.pumpAndSettle();
        Future<void> fill(String label, String text) async {
          final field = find.ancestor(
            of: find.text(label),
            matching: find.byType(TextFormField),
          );
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          await tester.enterText(field, text);
        }

        await fill('Tiêu đề', 'Xoài dự kiến theo nhu cầu trao đổi');
        await fill('Số lượng dự kiến (kg)', '20');
        await fill(
          'Mô tả / thời gian dự kiến',
          'Thông tin về số lượng dự kiến và thời gian cần trao đổi.',
        );
        await fill('Giá chào tối thiểu (đ/kg, tùy chọn)', '20000');
        await press(tester, 'Gửi kiểm duyệt');
        expect(
          transport.calls.where(
            (call) => call.$1 == 'POST' && call.$2 == '/posts',
          ),
          isEmpty,
        );
        expect(
          find.text('Điền cả hai giá chào hoặc để trống cả hai.'),
          findsWidgets,
        );
        await fill('Giá chào tối đa (đ/kg, tùy chọn)', '25000');
        await press(tester, 'Gửi kiểm duyệt');
        final body = transport.calls
            .where((call) => call.$1 == 'POST' && call.$2 == '/posts')
            .single
            .$3!;
        expect(body['purpose'], role == UserRole.trader ? 'Demand' : 'Supply');
        expect(body['priceMinVndPerKg'], 20000);
        expect(body['priceMaxVndPerKg'], 25000);
        expect(body['region'], 'Đồng Tháp');
        expect(body.containsKey('authorId'), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Map<String, dynamic> marketSnapshot(String region, String name) => {
  'region': region,
  'productCode': 'mango',
  'asOf': '2026-10-30T10:00:00Z',
  'source': 'Giá chào trong tin đã công bố',
  'isForecast': false,
  'items': [
    {
      'productCode': 'mango',
      'productName': name,
      'region': region,
      'supplyEstimatedKg': 150,
      'demandEstimatedKg': 200,
      'supplyPostCount': 1,
      'demandPostCount': 2,
      'contributorCount': 2,
      'referencePriceVndPerKg': 24000,
      'priceMinVndPerKg': 20000,
      'priceMaxVndPerKg': 25000,
      'priceSampleCount': 3,
      'lastUpdated': '2026-10-30T10:00:00Z',
    },
  ],
  'limitations': <String>[],
};

class MarketRaceTransport extends FlowTransport {
  final old = Completer<ApiReply>();
  bool fail = true;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/market/summary')) {
      final region = uri.queryParameters['region'];
      if (region == 'Đợt cũ') return old.future;
      if (region == 'Đợt mới') {
        return ApiReply(
          200,
          jsonEncode(marketSnapshot('Đợt mới', 'Xoài dữ liệu mới')),
        );
      }
      if (region == 'Đợt lỗi') {
        if (fail) {
          fail = false;
          return const ApiReply(503, '{}');
        }
        return ApiReply(
          200,
          jsonEncode(marketSnapshot('Đợt lỗi', 'Xoài sau thử lại')),
        );
      }
    }
    return super.send(method, uri, headers, body);
  }
}
