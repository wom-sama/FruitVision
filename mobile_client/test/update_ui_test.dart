import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/app.dart';
import 'package:fruitvision_client/client/models.dart';
import 'package:fruitvision_client/client/ui/update_page.dart';
import 'package:fruitvision_client/client/ui/workspace.dart';
import 'package:fruitvision_client/client/updates.dart';

import 'ui_test.dart' as existing;
import 'updates_test.dart'
    show FakeUpdatePlatform, FakeManifestClient, buildInfo, manifest;

Future<void> clean(WidgetTester tester, UpdateController updater) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  updater.dispose();
}

void main() {
  testWidgets(
    'startup optional prompt can defer and controller ticks never recheck',
    (tester) async {
      final native = FakeUpdatePlatform(), client = FakeManifestClient();
      final updater = UpdateController(platform: native, client: client);
      final session = existing.controller(existing.UiTransport());
      await tester.pumpWidget(
        FruitVisionApp(controller: session, updates: updater),
      );
      await tester.pumpAndSettle();
      expect(find.text('Có bản cập nhật 2.2.1'), findsOneWidget);
      expect(find.text('Bản cập nhật để kiểm thử.'), findsOneWidget);
      await tester.tap(find.text('Để sau'));
      await tester.pumpAndSettle();
      expect(find.text('Đăng nhập'), findsWidgets);
      session.cancelMfa();
      await tester.pumpAndSettle();
      expect(client.requests, hasLength(1));
      expect(native.downloads, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      await clean(tester, updater);
      session.dispose();
    },
  );

  for (final offline in [false, true]) {
    testWidgets(
      'startup ${offline ? 'offline' : 'unpublished'} leaves sign-in usable',
      (tester) async {
        final client = FakeManifestClient()
          ..fail = offline
          ..value = {
            'schemaVersion': 1,
            'updateServiceEnabled': false,
            'available': false,
          };
        final updater = UpdateController(
          platform: FakeUpdatePlatform(),
          client: client,
        );
        final session = existing.controller(existing.UiTransport());
        await tester.pumpWidget(
          FruitVisionApp(controller: session, updates: updater),
        );
        await tester.pumpAndSettle();
        expect(find.text('Đăng nhập'), findsWidgets);
        expect(find.byType(AlertDialog), findsNothing);
        expect(updater.mandatory, isFalse);
        await clean(tester, updater);
        session.dispose();
      },
    );
  }

  testWidgets(
    'mandatory startup stays gated after cancelling download on narrow text-scaled screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final native = FakeUpdatePlatform()
        ..pending = Completer<DownloadedUpdate>();
      final updater = UpdateController(
        platform: native,
        client: FakeManifestClient()..value = manifest(mandatory: true),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: UpdateStartupGate(
            updater: updater,
            baseUrl: 'https://first.test',
            child: const Text('Sign-in must stay gated'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sign-in must stay gated'), findsNothing);
      expect(find.text('Để sau'), findsNothing);
      await tester.ensureVisible(find.text('Tải bản cập nhật'));
      await tester.tap(find.text('Tải bản cập nhật'));
      await tester.pump();
      await tester.ensureVisible(find.text('Hủy tải'));
      await tester.tap(find.text('Hủy tải'));
      await tester.pumpAndSettle();
      expect(updater.mandatory, isTrue);
      expect(find.text('Sign-in must stay gated'), findsNothing);
      expect(find.text('Tải bản cập nhật'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await clean(tester, updater);
    },
  );

  testWidgets(
    'manual account entry checks and permission requires a second explicit install action',
    (tester) async {
      final native = FakeUpdatePlatform(), client = FakeManifestClient();
      final updater = UpdateController(platform: native, client: client);
      final session = existing.controller(
        existing.UiTransport(),
        role: UserRole.consumer,
      );
      await tester.pumpWidget(
        UpdateScope(
          updater: updater,
          child: MaterialApp(
            home: Scaffold(
              body: AccountPage(
                controller: session,
                header: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Kiểm tra cập nhật'));
      await tester.tap(find.text('Kiểm tra cập nhật'));
      await tester.pumpAndSettle();
      expect(client.requests, hasLength(1));
      expect(find.text('Cập nhật ứng dụng'), findsOneWidget);
      await tester.ensureVisible(find.text('Tải bản cập nhật'));
      await tester.tap(find.text('Tải bản cập nhật'));
      await tester.pumpAndSettle();
      expect(native.installCalls, 0);
      await tester.ensureVisible(find.text('Cho phép cài đặt'));
      await tester.tap(find.text('Cho phép cài đặt'));
      await tester.pumpAndSettle();
      expect(native.permissionCalls, 1);
      expect(native.installCalls, 0);
      native.value = buildInfo(allowed: true);
      await tester.ensureVisible(find.text('Tôi đã cho phép · Kiểm tra lại'));
      await tester.tap(find.text('Tôi đã cho phép · Kiểm tra lại'));
      await tester.pumpAndSettle();
      expect(native.installCalls, 0);
      await tester.ensureVisible(find.text('Cài bản cập nhật'));
      await tester.tap(find.text('Cài bản cập nhật'));
      await tester.pumpAndSettle();
      expect(native.installCalls, 1);
      expect(updater.status, UpdateStatus.installerOpened);
      expect(updater.release, isNotNull);
      expect(native.deleted, isEmpty);
      expect(
        find.text('Android đã mở trình cài đặt. Bạn cần tự xác nhận việc cài.'),
        findsOneWidget,
      );
      await clean(tester, updater);
      session.dispose();
    },
  );
}
