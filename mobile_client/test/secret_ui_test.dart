import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/secret_messaging.dart';
import 'package:fruitvision_client/client/secret_protocol.dart';
import 'package:fruitvision_client/client/ui/secret_chat.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/ui/realtime_scope.dart';

import 'realtime_test.dart' show TestSocket;

import 'session_test.dart' show FakeApiTransport, MemorySessionVault;
import 'secret_protocol_test.dart'
    show ownUser, peerUser, ownDevice, peerDevice, roomId;
import 'secret_messaging_test.dart' show seller;
import 'ui_test.dart' show narrowPhone;

class SafetyUiService extends SecretMessaging {
  SafetyUiService(SessionController session) : super(session: session);
  bool confirmed = false;
  int confirmations = 0;
  final hash = '0123456789abcdef' * 4;
  SecretRoom get room => SecretRoom(
    id: roomId,
    bundles: [
      SecretBundle(
        userId: ownUser,
        deviceId: ownDevice,
        version: 1,
        encryptionKey: Uint8List(32),
        signingKey: Uint8List(32),
      ),
      SecretBundle(
        userId: peerUser,
        deviceId: peerDevice,
        version: 1,
        encryptionKey: Uint8List(32),
        signingKey: Uint8List(32),
      ),
    ],
    fingerprint: hash,
    verified: confirmed,
    changed: false,
  );
  @override
  Future<SecretMessagePage> messages(String id, {int? beforeSequence}) async =>
      SecretMessagePage(room, [], null);
  @override
  Future<void> confirmRoom(String id, String expectedFingerprint) async {
    expect(expectedFingerprint, hash);
    confirmed = true;
    confirmations++;
  }
}

void main() {
  testWidgets(
    'SecretConversationCreated passes the hub allowlist and refreshes an empty room inbox once',
    (tester) async {
      var created = false, calls = 0;
      final api = ApiClient(
        baseUrl: 'https://example.test',
        transport: FakeApiTransport((request) {
          if (request.uri.path.endsWith('/secret/conversations')) calls++;
          return ApiReply(
            200,
            jsonEncode({
              'items': created
                  ? [
                      {'id': roomId, 'lastActivityAt': '2026-10-31T00:00:00Z'},
                    ]
                  : <Object>[],
            }),
          );
        }),
      );
      api.setTokens(
        TokenPair(
          'access',
          'refresh',
          DateTime.now().add(const Duration(minutes: 10)),
        ),
      );
      final session = SessionController(api: api, vault: MemorySessionVault())
        ..loading = false
        ..user = Account.fromJson(seller());
      final secrets = SafetyUiService(session),
          socket = TestSocket(),
          hub = RealtimeClient(api: api, connector: (_, _) async => socket);
      var disposed = false;
      void cleanup() {
        if (disposed) {
          return;
        }
        disposed = true;
        hub.dispose();
        secrets.dispose();
        session.dispose();
      }

      addTearDown(cleanup);
      hub.start('secret-inbox');
      await tester.pump();
      expect(hub.state, HubConnectionState.connected);
      await tester.pumpWidget(
        RealtimeScope(
          client: hub,
          child: MaterialApp(home: SecretInboxPage(messaging: secrets)),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      created = true;
      socket.event('SecretConversationCreated', {
        'eventId': 'event-one',
        'id': roomId,
      });
      socket.event('SecretConversationCreated', {
        'eventId': 'event-one',
        'id': roomId,
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.scrollUntilVisible(
      find.text('Chat riêng 55555555'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
    expect(find.text('Chat riêng 55555555'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      cleanup();
      await tester.pump();
      expect(socket.closed, isTrue);
    },
  );
  testWidgets(
    'narrow secret room requires full safety comparison and clears decrypted drafts on lock',
    (tester) async {
      narrowPhone(tester);
      final session =
          SessionController(
              api: ApiClient(
                baseUrl: 'https://example.test',
                transport: FakeApiTransport((_) => const ApiReply(200, '{}')),
              ),
              vault: MemorySessionVault(),
            )
            ..loading = false
            ..user = Account.fromJson(seller());
      final secrets = SafetyUiService(session);
      addTearDown(() {
        secrets.dispose();
        session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SecretChatPage(
            messaging: secrets,
            id: roomId,
            title: 'Phòng riêng của hai người',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text(fullSafetyCode(secrets.hash)), findsOneWidget);
      final confirm = find.widgetWithText(FilledButton, 'Xác nhận mã đã khớp');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final comparison = find.byType(CheckboxListTile);
      await tester.ensureVisible(comparison);
      await tester.pumpAndSettle();
      await tester.tap(comparison);
      await tester.pumpAndSettle();
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      expect(confirm.hitTestable(), findsOneWidget);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(secrets.confirmations, 1);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      await tester.enterText(
        find.byType(TextField),
        'Bản nháp chỉ ở trong bộ nhớ',
      );
      secrets.lockMemory();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text('Bản nháp chỉ ở trong bộ nhớ'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
