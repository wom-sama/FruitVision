import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';

import 'ui_test.dart' as old;

void main() {
  for (final role in UserRole.values) {
    testWidgets(
      '${role.wire}: visible inbox tab and role-correct account actions',
      (tester) async {
        old.narrowPhone(tester);
        final c = old.controller(old.UiTransport(), role: role);
        addTearDown(c.dispose);
        await old.showTestApp(tester, c);
        await tester.pumpAndSettle();
        final destinations = tester
            .widgetList<NavigationDestination>(
              find.byType(NavigationDestination),
            )
            .toList();
        expect(destinations.where((x) => x.label == 'Tin nhắn'), hasLength(1));
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .labelBehavior,
          NavigationDestinationLabelBehavior.alwaysShow,
        );
        await tester.tap(
          find.widgetWithText(NavigationDestination, 'Tài khoản'),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Kiểm tra cập nhật'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Hồ sơ nâng vai trò'), findsNothing);
        if (role == UserRole.consumer) {
          expect(find.text('Nâng vai trò kinh doanh'), findsOneWidget);
        } else {
          expect(find.text('Nâng vai trò kinh doanh'), findsNothing);
        }
        if (role == UserRole.producer) {
          expect(find.text('Cơ sở sản xuất'), findsOneWidget);
        }
        if (role == UserRole.trader) {
          expect(find.text('Cơ sở kinh doanh'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
