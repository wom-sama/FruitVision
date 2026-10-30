import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/media.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/ui/face_photo.dart';

import 'session_test.dart' show FakeApiTransport, MemorySessionVault;
import 'auth_email_test.dart' show emailChallenge;
import 'biometrics_test.dart' show normalSession;
import 'ui_test.dart' show narrowPhone;

class FacePicker extends NativeMediaPicker {
  FacePicker(this.photo);
  final PickedMedia photo;
  final methods = <String>[];
  int deleted = 0;
  @override
  Future<PickedMedia?> pick(String method) async {
    methods.add(method);
    return photo;
  }

  @override
  Future<void> delete(PickedMedia photo) async {
    deleted++;
  }
}

void main() {
  late Directory folder;
  late File file;
  late PickedMedia photo;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('fv-face-test-');
    file = await File('${folder.path}/face.jpg')
        .writeAsBytes([255, 216, 255, 224, 0]);
    photo = PickedMedia(
      path: file.path,
      name: 'selfie.jpg',
      bytes: 5,
      mediaType: 'image',
      contentType: 'image/jpeg',
    );
  });
  tearDown(() async {
    if (await file.exists()) await file.delete();
    await folder.delete();
  });
  testWidgets(
    'face photo stays on device until explicit send then returns to email verification',
    (tester) async {
      narrowPhone(tester);
      await tester.runAsync(() async {
        await file.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );
      });
      final chosen = PickedMedia(
            path: file.path,
            name: 'face.png',
            bytes: 68,
            mediaType: 'image',
            contentType: 'image/png',
          ),
          picker = FacePicker(
            PickedMedia(
              path: file.path,
              name: 'face.png',
              bytes: 68,
              mediaType: 'image',
              contentType: 'image/png',
            ),
          );
      final transport = FakeApiTransport(
        (request) => ApiReply(
          200,
          jsonEncode(
            request.uri.path.endsWith('/auth/methods')
                ? {'faceReady': true, 'emailOtpReady': true}
                : emailChallenge(),
          ),
        ),
      );
      final session = SessionController(
        api: ApiClient(baseUrl: 'https://example.test', transport: transport),
        vault: MemorySessionVault(),
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AnimatedBuilder(
            animation: session,
            builder: (context, _) => Scaffold(
              body: Column(
                children: [
                  Text(
                    session.mfaChallenge == null
                        ? 'Chưa có mã email'
                        : 'Đã chuyển sang mã email',
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FacePhotoPage(
                          controller: session,
                          enroll: false,
                          email: 'minh@example.test',
                          picker: picker,
                        ),
                      ),
                    ),
                    child: const Text('Mở đối chiếu ảnh'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mở đối chiếu ảnh'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('chưa có kiểm tra người thật'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('Chụp ảnh khuôn mặt'), 180);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Chụp ảnh khuôn mặt'));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(picker.methods, ['captureFace']);
      expect(find.text(chosen.name), findsOneWidget);
      expect(
        transport.requests.where(
          (r) => r.uri.path.endsWith('/auth/face/login'),
        ),
        isEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('Gửi ảnh và nhận mã email'),
        180,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Gửi ảnh và nhận mã email'));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(session.signedIn, isFalse);
      expect(session.mfaMethod, 'email');
      expect(find.text('Đã chuyển sang mã email'), findsOneWidget);
      expect(picker.deleted, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('face login sends opt-in image only to face endpoint then requires email OTP without session', () async {
    final transport = FakeApiTransport(
      (_) => ApiReply(200, jsonEncode(emailChallenge())),
    );
    final session = SessionController(
      api: ApiClient(baseUrl: 'https://example.test', transport: transport),
      vault: MemorySessionVault(),
    );
    addTearDown(session.dispose);
    expect(await session.loginFace(' Minh@Example.test ', photo), isTrue);
    expect(session.signedIn, isFalse);
    expect(session.mfaChallenge, 'email-challenge');
    final request = transport.requests.single;
    expect(request.uri.path, '/api/v1/auth/face/login');
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(request.body, {
      'email': 'minh@example.test',
      'imageBase64': base64Encode([255, 216, 255, 224, 0]),
    });
  });
  test('face-only token response and oversized gallery image never grant a session', () async {
    final transport = FakeApiTransport(
      (_) => ApiReply(200, jsonEncode(normalSession())),
    );
    final session = SessionController(
      api: ApiClient(baseUrl: 'https://example.test', transport: transport),
      vault: MemorySessionVault(),
    );
    addTearDown(session.dispose);
    expect(await session.loginFace('minh@example.test', photo), isFalse);
    expect(session.signedIn, isFalse);
    expect(session.api.tokens, isNull);
    await file.writeAsBytes(Uint8List(2 * 1024 * 1024 + 1));
    expect(await session.loginFace('minh@example.test', photo), isFalse);
    expect(transport.requests, hasLength(1));
  });
  test(
    'face plus email OTP never counts as fresh password authentication',
    () async {
      final transport = FakeApiTransport(
        (request) => ApiReply(
          200,
          jsonEncode(
            request.uri.path.endsWith('/auth/otp/verify')
                ? normalSession()
                : emailChallenge(),
          ),
        ),
      );
      final session = SessionController(
        api: ApiClient(baseUrl: 'https://example.test', transport: transport),
        vault: MemorySessionVault(),
      );
      addTearDown(session.dispose);
      expect(await session.loginFace('minh@example.test', photo), isTrue);
      expect(await session.completeMfa('123456'), isTrue);
      expect(session.signedIn, isTrue);
      expect(session.canEnrollBiometric, isFalse);
      expect(await session.enrollFace(photo), isFalse);
      expect(
        transport.requests.where(
          (r) => r.uri.path.endsWith('/auth/face/enroll'),
        ),
        isEmpty,
      );
    },
  );
  test('face enrollment requires fresh password OTP and stays on authenticated endpoint', () async {
    final transport = FakeApiTransport(
      (request) => ApiReply(
        200,
        jsonEncode(
          request.uri.path.endsWith('/auth/login')
              ? emailChallenge()
              : request.uri.path.endsWith('/auth/otp/verify')
              ? normalSession()
              : {'enrolled': true, 'ready': true, 'livenessVerified': false},
        ),
      ),
    );
    final session = SessionController(
      api: ApiClient(baseUrl: 'https://example.test', transport: transport),
      vault: MemorySessionVault(),
    );
    addTearDown(session.dispose);
    expect(await session.enrollFace(photo), isFalse);
    expect(transport.requests, isEmpty);
    await session.login('minh@example.test', 'password');
    await session.completeMfa('123456');
    expect(await session.enrollFace(photo), isTrue);
    expect(transport.requests.last.uri.path, '/api/v1/auth/face/enroll');
    expect(
      transport.requests.last.headers['Authorization'],
      'Bearer test-access',
    );
    expect(transport.requests.last.body!.keys, ['imageBase64']);
  });
}
