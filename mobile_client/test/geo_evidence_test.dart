import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/media.dart';
import 'package:fruitvision_client/client/ui/location_picker.dart';

import 'workflows_2_3_test.dart' show choose;

class GeoTransport implements ApiTransport {
  final delayed = Completer<ApiReply>();
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/countries')) {
      return const ApiReply(
        200,
        '{"items":[{"code":"VN","name":"Việt Nam"},{"code":"TH","name":"Thái Lan"}]}',
      );
    }
    if (uri.queryParameters['country'] == 'VN') return delayed.future;
    return const ApiReply(
      200,
      '{"items":[{"code":"TH-10","name":"Bangkok"}],"countryCode":"TH"}',
    );
  }

  @override
  void close() {}
}

class EvidenceTransport implements MediaTransport {
  final uploads = <Uri>[], downloadHeaders = <Map<String, String>>[];
  Map<String, String>? uploadHeaders;
  List<int>? uploaded;
  @override
  Future<ApiReply> upload(
    Uri uri,
    Map<String, String> headers,
    File file,
    UploadCancellation cancellation,
    void Function(int, int)? progress,
  ) async {
    uploads.add(uri);
    uploadHeaders = headers;
    uploaded = await file.readAsBytes();
    return const ApiReply(
      201,
      '{"id":"application-one","revision":2,"evidence":[]}',
    );
  }

  @override
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  ) async {
    expect(maxBytes, 5 * 1024 * 1024);
    downloadHeaders.add(headers);
    return BinaryReply(
      downloadHeaders.length == 1 ? 401 : 200,
      Uint8List.fromList([37, 80, 68, 70, 45]),
    );
  }

  @override
  void close() {}
}

class RefreshTransport implements ApiTransport {
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async => const ApiReply(
    200,
    '{"accessToken":"new-access","refreshToken":"new-refresh","expiresIn":900}',
  );
  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'latest country selection rejects delayed provinces from the previous country',
    (tester) async {
      final transport = GeoTransport(), form = GlobalKey<FormState>();
      final api = ApiClient(
        baseUrl: 'https://example.test',
        transport: transport,
      );
      addTearDown(api.close);
      LocationSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: form,
              child: CountryProvincePicker(
                api: api,
                onChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final country = find.widgetWithText(
        DropdownButtonFormField<String>,
        'Quốc gia',
      );
      await tester.tap(country);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Việt Nam').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(country);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Thái Lan').last);
      await tester.pumpAndSettle();
      transport.delayed.complete(
        const ApiReply(
          200,
          '{"items":[{"code":"VN-82","name":"Tỉnh cũ không được chọn"}]}',
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'Tỉnh / thành phố', 'Bangkok');
      expect(selected?.countryCode, 'TH');
      expect(selected?.provinceCode, 'TH-10');
      expect(selected?.region, 'Bangkok, Thái Lan');
      expect(form.currentState!.validate(), isTrue);
      expect(find.text('Tỉnh cũ không được chọn'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('evidence upload streams authorized raw file with revision and blocks oversized input', () async {
    final media = EvidenceTransport();
    final client = ApiClient(
      baseUrl: 'https://example.test',
      transport: RefreshTransport(),
      mediaTransport: media,
    );
    addTearDown(client.close);
    client.setTokens(
      TokenPair(
        'old-access',
        'refresh',
        DateTime.now().add(const Duration(minutes: 10)),
      ),
    );
    final directory = await Directory.systemTemp.createTemp('fv-proof-test-');
    final file = File('${directory.path}/proof.pdf');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
      await directory.delete();
    });
    await file.writeAsBytes([37, 80, 68, 70, 45]);
    await client.uploadEvidence(
      applicationId: 'application-one',
      category: 'ProductionEvidence',
      expectedRevision: 1,
      file: file,
      contentType: 'application/pdf',
    );
    expect(media.uploaded, [37, 80, 68, 70, 45]);
    expect(media.uploadHeaders!['Authorization'], 'Bearer old-access');
    expect(media.uploadHeaders!['Content-Type'], 'application/pdf');
    expect(media.uploads.single.queryParameters, {
      'category': 'ProductionEvidence',
      'expectedRevision': '1',
    });
    await file.writeAsBytes(Uint8List(5 * 1024 * 1024 + 1));
    await expectLater(
      client.uploadEvidence(
        applicationId: 'application-one',
        category: 'ProductionEvidence',
        expectedRevision: 2,
        file: file,
        contentType: 'application/pdf',
      ),
      throwsA(isA<ApiException>()),
    );
    expect(media.uploads, hasLength(1));
    final bytes = await client.evidenceBytes('application-one', 'evidence-one');
    expect(bytes, [37, 80, 68, 70, 45]);
    expect(media.downloadHeaders.map((h) => h['Authorization']), [
      'Bearer old-access',
      'Bearer new-access',
    ]);
  });
  test('proof viewer receives only a UUID cache path and MIME and temporary file is cleaned', () async {
    const channel = MethodChannel('vn.fruitvision/media');
    Map<dynamic, dynamic>? opened;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openEvidence');
          opened = call.arguments as Map;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final picker = NativeEvidencePicker();
    await picker.view(
      Uint8List.fromList(utf8.encode('%PDF-1.7')),
      'application/pdf',
    );
    expect(opened!.keys.toSet(), {'path', 'contentType'});
    final file = File(opened!['path'] as String);
    expect(
      file.parent.absolute.uri,
      Directory('${Directory.systemTemp.path}/fv_evidence').absolute.uri,
    );
    expect(
      file.uri.pathSegments.last,
      matches(RegExp(r'^[a-f0-9-]{36}\.pdf$')),
    );
    expect(await file.exists(), isTrue);
    await picker.dispose();
    expect(await file.exists(), isFalse);
  });
}
