import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/ui/role_applications.dart';
import 'package:fruitvision_client/client/ui/photo_viewer.dart';

import 'ui_test.dart' as fixtures;
import 'workflows_2_3_test.dart' show WorkflowTransport;
import 'feedback_test.dart' show InlineMedia;

class EvidenceMedia extends InlineMedia {
  EvidenceMedia(this.mime, {this.status = 200});
  final String mime;
  final int status;
  @override
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  ) async {
    if (mime == 'image/png' && status == 200) {
      return super.download(uri, headers, maxBytes);
    }
    downloads.add((uri, headers, maxBytes));
    return BinaryReply(
      status,
      status == 200
          ? base64Decode(
              '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDQooor5o4D/9k=',
            )
          : Uint8List.fromList(
              utf8.encode('{"detail":"Chứng từ không còn khả dụng."}'),
            ),
    );
  }
}

void main() {
  for (final mime in ['image/png', 'image/jpeg']) {
    testWidgets(
      'authenticated $mime evidence opens and zooms in app when Android has no external viewer',
      (tester) async {
        final source = WorkflowTransport();
        source.application = {
          ...source.application,
          'status': 'Submitted',
          'revision': 3,
          'evidence': [
            {
              'id': 'proof-one',
              'contentType': mime,
              'sizeBytes': mime == 'image/png' ? 68 : 632,
            },
          ],
        };
        final media = EvidenceMedia(mime);
        final api = ApiClient(
          baseUrl: 'https://example.test',
          transport: source,
          mediaTransport: media,
        );
        final session =
            SessionController(api: api, vault: fixtures.MemoryVault())
              ..loading = false
              ..user = Account.fromJson(fixtures.profile(UserRole.admin));
        api.setTokens(
          TokenPair(
            'a' * 43,
            'b' * 43,
            DateTime.now().add(const Duration(minutes: 10)),
          ),
        );
        var externalCalls = 0;
        const channel = MethodChannel('vn.fruitvision/media');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'openEvidence') {
              externalCalls++;
              throw PlatformException(
                code: 'NO_VIEWER',
                message: 'No external image viewer installed',
              );
            }
            return null;
          },
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
          session.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: RoleApplicationPage(
              controller: session,
              id: 'application-one',
              admin: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Xem chứng từ'),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Xem chứng từ'));
        await tester.pumpAndSettle();
        expect(find.text('Ảnh minh chứng'), findsOneWidget);
        expect(find.byType(PhotoViewerPage), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
        expect(externalCalls, 0);
        expect(
          media.downloads.single.$1.path,
          '/api/v1/admin/role-applications/application-one/evidence/proof-one',
        );
        expect(
          media.downloads.single.$2['Authorization'],
          'Bearer ${'a' * 43}',
        );
        expect(media.downloads.single.$3, 5 * 1024 * 1024);
        expect(tester.takeException(), isNull);
        final privateBytes = tester
            .widget<PhotoViewerPage>(find.byType(PhotoViewerPage))
            .bytes;
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Xem chứng từ'), findsOneWidget);
        expect(privateBytes.every((byte) => byte == 0), isTrue);
      },
    );
  }
  testWidgets(
    'binary evidence API400 is shown without opening image or native viewer',
    (tester) async {
      final source = WorkflowTransport();
      source.application = {
        ...source.application,
        'status': 'Submitted',
        'evidence': [
          {'id': 'proof-one', 'contentType': 'image/png', 'sizeBytes': 68},
        ],
      };
      final media = EvidenceMedia('image/png', status: 400);
      final api = ApiClient(
        baseUrl: 'https://example.test',
        transport: source,
        mediaTransport: media,
      );
      final session = SessionController(api: api, vault: fixtures.MemoryVault())
        ..loading = false
        ..user = Account.fromJson(fixtures.profile(UserRole.admin));
      api.setTokens(
        TokenPair(
          'a' * 43,
          'b' * 43,
          DateTime.now().add(const Duration(minutes: 10)),
        ),
      );
      var nativeCalls = 0;
      const channel = MethodChannel('vn.fruitvision/media');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'openEvidence') nativeCalls++;
        return null;
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RoleApplicationPage(
            controller: session,
            id: 'application-one',
            admin: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Xem chứng từ'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Xem chứng từ'));
      await tester.pumpAndSettle();
      expect(find.text('Chứng từ không còn khả dụng.'), findsOneWidget);
      expect(find.byType(PhotoViewerPage), findsNothing);
      expect(nativeCalls, 0);
      expect(media.downloads.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
