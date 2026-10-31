import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/secret_messaging.dart';
import 'package:fruitvision_client/client/secret_protocol.dart';
import 'package:fruitvision_client/client/ui/secret_chat.dart';
import 'package:fruitvision_client/client/ui/secret_scope.dart';
import 'package:fruitvision_client/client/ui/photo_viewer.dart';

import 'secret_ui_test.dart' show SafetyUiService;
import 'secret_messaging_test.dart' show seller;
import 'secret_protocol_test.dart'
    show
        peerUser,
        peerDevice,
        roomId,
        messageId,
        attachmentId;
import 'session_test.dart' show FakeApiTransport, MemorySessionVault;

Uint8List decodedPreview() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);

class VerifiedPhotoUiService extends SafetyUiService {
  VerifiedPhotoUiService(super.session) {
    confirmed = true;
  }
  final decrypted = Completer<Uint8List>();
  int verifiedLoads = 0;
  bool invalidSignature = false;
  @override
  Future<SecretMessagePage> messages(String id, {int? beforeSequence}) async =>
      SecretMessagePage(room, [
        SecretMessage(
          {
            'id': messageId,
            'senderUserId': peerUser,
            'senderDeviceId': peerDevice,
            'clientMessageId': messageId,
            'sequence': 1,
          },
          invalidSignature
              ? null
              : SecretPacket(
                  conversationId: roomId,
                  senderUserId: peerUser,
                  senderDeviceId: peerDevice,
                  clientMessageId: messageId,
                  text: '',
                  image: SecretImageMetadata(
                    attachmentId: attachmentId,
                    cipherHash: '0' * 64,
                    cipherBytes: 20,
                    plainBytes: 4,
                    nonce: base64Encode(Uint8List(24)),
                    key: base64Encode(Uint8List(32)),
                    width: 1,
                    height: 1,
                  ),
                ),
          invalidSignature ? 'Chữ ký không hợp lệ.' : null,
        ),
      ], null);
  // UI fake represents the existing service's completed pin/digest/MAC/decode gate.
  // Real cryptographic behavior is covered separately by secret_protocol_test.
  @override
  Future<Uint8List> image(String roomId, SecretImageMetadata metadata) {
    verifiedLoads++;
    return decrypted.future;
  }
}

SessionController session() =>
    SessionController(
        api: ApiClient(
          baseUrl: 'https://example.test',
          transport: FakeApiTransport((_) => const ApiReply(200, '{}')),
        ),
        vault: MemorySessionVault(),
      )
      ..loading = false
      ..user = Account.fromJson(seller());
Widget page(VerifiedPhotoUiService service) => SecretScope(
  messaging: service,
  child: MaterialApp(
    home: SecretChatPage(
      messaging: service,
      id: roomId,
      title: 'Hội thoại riêng',
    ),
  ),
);
Future<void> pendingFrame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  testWidgets(
    'verified secret image previews inline, zoom uses separate RAM and lock clears thumbnail bytes',
    (tester) async {
      final c = session(), service = VerifiedPhotoUiService(c);
      addTearDown(() {
        service.dispose();
        c.dispose();
      });
      await tester.pumpWidget(page(service));
      await pendingFrame(tester);
      expect(service.verifiedLoads, 1);
      expect(find.byType(Image), findsNothing);
      final bytes = decodedPreview();
      service.decrypted.complete(bytes);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      final resized =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(resized.width, lessThanOrEqualTo(512));
      expect(resized.height, lessThanOrEqualTo(512));
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      final viewer = tester.widget<PhotoViewerPage>(
        find.byType(PhotoViewerPage),
      );
      expect(viewer.secret, isTrue);
      expect(identical(viewer.bytes, bytes), isFalse);
      final zoomBytes = viewer.bytes;
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(zoomBytes.every((byte) => byte == 0), isTrue);
      expect(bytes.any((byte) => byte != 0), isTrue);
      service.lockMemory();
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(bytes.every((byte) => byte == 0), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'invalid signed packet never loads preview and late verified bytes are erased after disposal',
    (tester) async {
      final c = session(),
          rejected = VerifiedPhotoUiService(c)..invalidSignature = true;
      addTearDown(c.dispose);
      addTearDown(rejected.dispose);
      await tester.pumpWidget(page(rejected));
      await tester.pumpAndSettle();
      expect(rejected.verifiedLoads, 0);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      final late = VerifiedPhotoUiService(c);
      addTearDown(late.dispose);
      await tester.pumpWidget(page(late));
      await pendingFrame(tester);
      expect(late.verifiedLoads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      final bytes = decodedPreview();
      late.decrypted.complete(bytes);
      await tester.pump();
      expect(bytes.every((byte) => byte == 0), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
