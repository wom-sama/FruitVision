import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/biometrics.dart';
import 'package:fruitvision_client/client/session.dart';

import 'session_test.dart' show FakeApiTransport, MemorySessionVault;
import 'ui_test.dart' show profile;
import 'auth_email_test.dart' show emailChallenge;

class FakeBiometrics extends BiometricPlatform {
  FakeBiometrics() : super(supported: true);
  final calls = <(String, String, String)>[];
  String? signed;
  bool cancel = false;
  final key = const BiometricInfo(
    available: true,
    enrolled: true,
    deviceId: '11111111-1111-4111-8111-111111111111',
    publicKey: 'cHVibGljLWtleQ==',
    label: 'Test Android',
  );
  @override
  Future<BiometricInfo> info(String origin, String email) async {
    calls.add(('info', origin, email));
    return key;
  }

  @override
  Future<BiometricInfo> createKey(String origin, String email) async {
    calls.add(('createKey', origin, email));
    return key;
  }

  @override
  Future<String> sign(String origin, String email, String payload) async {
    calls.add(('sign', origin, email));
    signed = payload;
    if (cancel) throw PlatformException(code: 'BIOMETRIC_CANCELLED');
    return 'c2lnbmF0dXJl';
  }

  @override
  Future<void> deleteKey(String origin, String email) async {
    calls.add(('deleteKey', origin, email));
  }
}

Map<String, dynamic> normalSession() => {
  'accessToken': 'test-access',
  'refreshToken': 'test-refresh',
  'expiresIn': 900,
  'user': {...profile(UserRole.consumer), 'emailConfirmed': true},
};
ApiReply jsonReply(Object data) => ApiReply(200, jsonEncode(data));
void main() {
  test('biometric login signs exact literal challenge scoped to origin and normalized email', () async {
    const payload = '{ "nonce" : "unmodified", "value":"é" }';
    final native = FakeBiometrics(),
        transport = FakeApiTransport(
          (request) => jsonReply(
            request.uri.path.endsWith('/challenge')
                ? {
                    'challengeToken': 'one-use-challenge',
                    'payload': payload,
                    'expiresAt': '2026-10-30T23:00:00Z',
                  }
                : normalSession(),
          ),
        );
    final session = SessionController(
      api: ApiClient(baseUrl: 'https://example.test', transport: transport),
      vault: MemorySessionVault(),
      biometrics: native,
    );
    addTearDown(session.dispose);
    expect(await session.loginBiometric(' MINH@Example.test '), isTrue);
    expect(native.signed, payload);
    expect(
      native.calls,
      contains(('sign', 'https://example.test', 'minh@example.test')),
    );
    expect(session.signedIn, isTrue);
    expect(session.canEnrollBiometric, isFalse);
    expect(transport.requests.map((r) => r.uri.path), [
      '/api/v1/auth/biometric/challenge',
      '/api/v1/auth/biometric/login',
    ]);
    expect(transport.requests.last.body, {
      'challengeToken': 'one-use-challenge',
      'signature': 'c2lnbmF0dXJl',
    });
    expect(
      transport.requests.every((r) => !r.headers.containsKey('Authorization')),
      isTrue,
    );
  });
  test('cancelled native biometric prompt never sends login signature or grants session', () async {
    final native = FakeBiometrics()..cancel = true;
    final transport = FakeApiTransport(
      (_) =>
          jsonReply({'challengeToken': 'one-use', 'payload': 'exact payload'}),
    );
    final session = SessionController(
      api: ApiClient(baseUrl: 'https://example.test', transport: transport),
      vault: MemorySessionVault(),
      biometrics: native,
    );
    addTearDown(session.dispose);
    expect(await session.loginBiometric('minh@example.test'), isFalse);
    expect(transport.requests, hasLength(1));
    expect(session.signedIn, isFalse);
    expect(session.error, isNotEmpty);
  });
  test(
    'enrollment needs fresh password OTP and registers only the public key',
    () async {
      final native = FakeBiometrics(),
          transport = FakeApiTransport(
            (request) => jsonReply(
              request.uri.path.endsWith('/auth/login')
                  ? emailChallenge()
                  : request.uri.path.endsWith('/auth/otp/verify')
                  ? normalSession()
                  : {'id': 'server-device', 'deviceId': nativeDeviceId},
            ),
          );
      final session = SessionController(
        api: ApiClient(baseUrl: 'https://example.test', transport: transport),
        vault: MemorySessionVault(),
        biometrics: native,
      );
      addTearDown(session.dispose);
      session.user = Account.fromJson({
        ...profile(UserRole.consumer),
        'emailConfirmed': true,
      });
      expect(await session.enrollBiometric(), isFalse);
      expect(native.calls, isEmpty);
      expect(transport.requests, isEmpty);
      await session.login('minh@example.test', 'password');
      await session.completeMfa('123456');
      expect(await session.enrollBiometric(), isTrue);
      expect(transport.requests.last.body, {
        'deviceId': nativeDeviceId,
        'label': 'Test Android',
        'publicKey': 'cHVibGljLWtleQ==',
      });
      expect(
        native.calls,
        contains(('createKey', 'https://example.test', 'minh@example.test')),
      );
    },
  );
}

const nativeDeviceId = '11111111-1111-4111-8111-111111111111';
