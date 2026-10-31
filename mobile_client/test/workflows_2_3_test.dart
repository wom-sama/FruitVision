import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/ui/role_applications.dart';

import 'ui_test.dart' as old;

class WorkflowTransport extends old.UiTransport {
  bool rejectSubmit = false;
  final mutations = <Map<String, dynamic>>[];
  Map<String, dynamic> application = {
    'id': 'application-one',
    'userId': 'account-Consumer',
    'requestedRole': 'Producer',
    'status': 'Draft',
    'revision': 1,
    'organisationName': '',
    'address': '',
    'countryCode': null,
    'provinceCode': null,
    'region': '',
    'phone': '',
    'products': <String>[],
    'cultivatedAreaHa': null,
    'evidence': <Object>[],
    'createdAt': '2026-10-30T10:00:00Z',
  };
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    final path = uri.path;
    if (path.endsWith('/ai/stats')) {
      return const ApiReply(
        200,
        '{"days":7,"scope":"own-jobs","timeZone":"UTC","asOf":"2026-10-30T10:00:00Z","counts":{"total":5,"completed":2,"failed":1,"queued":1,"running":1,"cancelled":0},"media":{"imageJobs":4,"videoJobs":1,"framesProcessed":1073},"jobsByDay":[]}',
      );
    }
    if (path.endsWith('/ai/guide')) {
      return const ApiReply(
        200,
        '{"schemaVersion":1,"executionLocation":"server","maxImageBytes":12582912,"maxVideoBytes":83886080,"maxVideoSeconds":120,"maxVideoWidth":1920,"maxVideoHeight":1080,"steps":["Chọn ảnh rõ nét."],"limitations":["Số đếm không phải khối lượng."]}',
      );
    }
    if (path.endsWith('/articles') ||
        path.endsWith('/branches') ||
        path.endsWith('/articles/mine') ||
        path.endsWith('/branches/mine')) {
      if (method == 'POST') {
        final data = jsonDecode(body!) as Map<String, dynamic>;
        mutations.add({'method': method, 'path': path, ...data});
        return ApiReply(
          201,
          jsonEncode({
            'id': 'created-one',
            'revision': 1,
            'status': 'Pending',
            ...data,
          }),
        );
      }
      return const ApiReply(200, '{"items":[]}');
    }
    if (path.contains('/role-applications')) {
      if (path.endsWith('/submit') && rejectSubmit) {
        return const ApiReply(400, '{"detail":"Cần kiểm tra chứng từ."}');
      }
      if (method == 'POST' || method == 'PUT') {
        final data = body == null
            ? <String, dynamic>{}
            : jsonDecode(body) as Map<String, dynamic>;
        mutations.add({'method': method, 'path': path, ...data});
        if (method == 'PUT') {
          application = {
            ...application,
            ...data,
            'revision': 2,
            'region': 'Đồng Tháp',
          };
        }
        if (path.endsWith('/review')) {
          application = {
            ...application,
            'status': data['status'],
            'revision': 4,
          };
        }
        return ApiReply(
          path.endsWith('role-applications') ? 201 : 200,
          jsonEncode(application),
        );
      }
      return ApiReply(
        200,
        jsonEncode(
          path.endsWith('role-applications')
              ? {
                  'items': [application],
                }
              : application,
        ),
      );
    }
    if (path.endsWith('/locations/countries')) {
      return const ApiReply(
        200,
        '{"items":[{"code":"VN","name":"Việt Nam"}],"stale":false}',
      );
    }
    if (path.endsWith('/locations/provinces')) {
      return const ApiReply(
        200,
        '{"items":[{"code":"82","name":"Đồng Tháp"}],"countryCode":"VN","stale":false}',
      );
    }
    if (path.endsWith('/catalog/products')) {
      return const ApiReply(
        200,
        '{"items":[{"code":"MANGO","name":"Xoài","unit":"kg"}]}',
      );
    }
    return super.send(method, uri, headers, body);
  }
}

Future<void> choose(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(DropdownButtonFormField<String>, label);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, value);
}

void main() {
  testWidgets(
    'long role form keeps validation mounted and retains successful save revision when submission fails',
    (tester) async {
      old.narrowPhone(tester);
      final transport = WorkflowTransport()..rejectSubmit = true;
      transport.application = {
        ...transport.application,
        'organisationName': 'Vườn thử nghiệm',
        'address': 'Đường Hoa số 10',
        'countryCode': 'VN',
        'provinceCode': '82',
        'phone': '0901234567',
        'products': ['MANGO'],
        'cultivatedAreaHa': 2.5,
        'evidence': List.generate(
          4,
          (i) => {
            'id': 'proof-$i',
            'contentType': 'application/pdf',
            'sizeBytes': 1024,
          },
        ),
      };
      final session = old.controller(transport, role: UserRole.consumer);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RoleApplicationPage(controller: session, id: 'application-one'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Gửi xét duyệt'),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gửi xét duyệt'));
      await tester.pumpAndSettle();
      expect(find.text('Cần kiểm tra chứng từ.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Lưu bản nháp'),
        -220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lưu bản nháp'));
      await tester.pumpAndSettle();
      expect(
        transport.mutations
            .where((m) => m['method'] == 'PUT')
            .map((m) => m['expectedRevision']),
        [1, 2],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Seller AI guide and statistics display only actual own-job counts',
    (tester) async {
      final session = old.controller(
        WorkflowTransport(),
        role: UserRole.producer,
      );
      addTearDown(session.dispose);
      await old.showTestApp(tester, session);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is NavigationDestination && w.label == 'AI xoài',
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Thống kê & hướng dẫn AI'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thống kê & hướng dẫn AI'));
      await tester.pumpAndSettle();
      expect(find.text('Tổng tác vụ'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('1073'), 160);
      await tester.pumpAndSettle();
      expect(find.text('1073'), findsOneWidget);
      expect(find.textContaining('không phải số quả'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Consumer publishes community article without business fields', (
    tester,
  ) async {
    final transport = WorkflowTransport();
    final session = old.controller(transport, role: UserRole.consumer);
    addTearDown(session.dispose);
    await old.showTestApp(tester, session);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is NavigationDestination && w.label == 'Cộng đồng',
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Viết bài cộng đồng'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Viết bài cộng đồng'));
    await tester.pumpAndSettle();
    await enter(tester, 'Tiêu đề bài viết', 'Chăm sóc xoài trong mùa mưa');
    await enter(
      tester,
      'Nội dung bài viết',
      'Chia sẻ kinh nghiệm chăm sóc cây trong mùa mưa.',
    );
    await tester.ensureVisible(find.text('Gửi xét duyệt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gửi xét duyệt'));
    await tester.pumpAndSettle();
    expect(transport.mutations.single, {
      'method': 'POST',
      'path': '/api/v1/articles',
      'title': 'Chăm sóc xoài trong mùa mưa',
      'body': 'Chia sẻ kinh nghiệm chăm sóc cây trong mùa mưa.',
      'imageId': null,
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Seller registers real branch with directory codes before business publishing',
    (tester) async {
      old.narrowPhone(tester);
      final transport = WorkflowTransport();
      final session = old.controller(transport, role: UserRole.trader);
      addTearDown(session.dispose);
      await old.showTestApp(tester, session);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Cơ sở kinh doanh'), 180);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cơ sở kinh doanh'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đăng ký cơ sở kinh doanh'));
      await tester.pumpAndSettle();
      await enter(tester, 'Tên cơ sở', 'Điểm thu mua Sa Đéc');
      await choose(tester, 'Quốc gia', 'Việt Nam');
      await choose(tester, 'Tỉnh / thành phố', 'Đồng Tháp');
      await enter(tester, 'Địa chỉ đường / số nhà', 'Số 20, đường Hoa');
      await enter(tester, 'Số điện thoại liên hệ', '0901234567');
      await tester.ensureVisible(find.text('Gửi xét duyệt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gửi xét duyệt'));
      await tester.pumpAndSettle();
      final saved = transport.mutations.single;
      expect(saved['path'], '/api/v1/branches');
      expect(saved['countryCode'], 'VN');
      expect(saved['provinceCode'], '82');
      expect(saved.containsKey('region'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Consumer creates role-specific Producer profile using trusted country and province codes',
    (tester) async {
      old.narrowPhone(tester);
      final transport = WorkflowTransport();
      final session = old.controller(transport, role: UserRole.consumer);
      session.user = Account.fromJson({
        ...old.profile(UserRole.consumer),
        'emailConfirmed': true,
      });
      addTearDown(session.dispose);
      await old.showTestApp(tester, session);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Nâng vai trò kinh doanh'),
        180,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nâng vai trò kinh doanh'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Đăng ký Nhà sản xuất'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đăng ký Nhà sản xuất'));
      await tester.pumpAndSettle();
      await enter(tester, 'Đơn vị / hộ kinh doanh', 'Vườn xoài thử nghiệm');
      await enter(tester, 'Địa chỉ liên hệ', 'Số 10, đường Hoa');
      await choose(tester, 'Quốc gia', 'Việt Nam');
      await choose(tester, 'Tỉnh / thành phố', 'Đồng Tháp');
      await enter(tester, 'Số điện thoại', '0901234567');
      await enter(tester, 'Diện tích canh tác (ha)', '2.5');
      await tester.ensureVisible(find.text('Xoài'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xoài'));
      await tester.ensureVisible(find.text('Lưu bản nháp'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lưu bản nháp'));
      await tester.pumpAndSettle();
      final saved = transport.mutations.singleWhere(
        (call) => call['method'] == 'PUT',
      );
      expect(saved['countryCode'], 'VN');
      expect(saved['provinceCode'], '82');
      expect(saved.containsKey('region'), isFalse);
      expect(saved['cultivatedAreaHa'], 2.5);
      expect(saved['products'], ['MANGO']);
      expect(saved['expectedRevision'], 1);
      expect(saved['taxCode'], isNull);
      expect(saved['businessRegistrationNumber'], isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Admin reviews role application with current revision and reason',
    (tester) async {
      final transport = WorkflowTransport()
        ..application['status'] = 'Submitted'
        ..application['revision'] = 3;
      final session = old.controller(transport, role: UserRole.admin);
      addTearDown(session.dispose);
      await old.showTestApp(tester, session);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Duyệt nâng vai trò'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duyệt nâng vai trò'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nhà sản xuất').last);
      await tester.pumpAndSettle();
      await enter(tester, 'Lý do xét duyệt', 'Hồ sơ và chứng từ phù hợp');
      await tester.ensureVisible(find.text('Chấp thuận'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chấp thuận'));
      await tester.pumpAndSettle();
      final review = transport.mutations.singleWhere(
        (call) => (call['path'] as String).endsWith('/review'),
      );
      expect(review['status'], 'Approved');
      expect(review['expectedRevision'], 3);
      expect(review['reason'], 'Hồ sơ và chứng từ phù hợp');
      expect(tester.takeException(), isNull);
    },
  );
}
