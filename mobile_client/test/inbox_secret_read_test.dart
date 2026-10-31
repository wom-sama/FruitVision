import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/ui/secret_chat.dart';
import 'package:fruitvision_client/client/ui/secret_scope.dart';

import 'secret_photo_test.dart' show VerifiedPhotoUiService, decodedPreview;
import 'secret_messaging_test.dart' show seller;
import 'secret_protocol_test.dart' show roomId;
import 'session_test.dart' show FakeApiTransport, MemorySessionVault;

void main() {
  for (final invalid in [false, true]) {
    testWidgets(
      invalid
          ? 'invalid secret signature never acknowledges or loads an image'
          : 'secret image is read only after verified decryption and visible display',
      (tester) async {
        final transport = FakeApiTransport((_) => const ApiReply(200, '{}'));
        final session =
            SessionController(
                api: ApiClient(
                  baseUrl: 'https://example.test',
                  transport: transport,
                ),
                vault: MemorySessionVault(),
              )
              ..loading = false
              ..user = Account.fromJson(seller());
        final service = VerifiedPhotoUiService(session)
          ..invalidSignature = invalid;
        await tester.pumpWidget(
          SecretScope(
            messaging: service,
            child: MaterialApp(
              home: SecretChatPage(
                messaging: service,
                id: roomId,
                title: 'Lan',
                directConversationId: 'direct-one',
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          transport.requests.where(
            (request) => request.uri.path.endsWith('/read'),
          ),
          isEmpty,
        );
        if (invalid) {
          expect(service.verifiedLoads, 0);
        } else {
          service.decrypted.complete(decodedPreview());
          await tester.pumpAndSettle();
          expect(find.byType(Image), findsOneWidget);
          final receipt = transport.requests
              .where((request) => request.uri.path.endsWith('/read'))
              .single;
          expect(receipt.uri.path, '/api/v1/conversations/direct-one/read');
          expect(receipt.body, {'lastSecretSequence': 1});
        }
        await tester.pumpWidget(const SizedBox.shrink());
        service.dispose();
        session.dispose();
      },
    );
  }
}
