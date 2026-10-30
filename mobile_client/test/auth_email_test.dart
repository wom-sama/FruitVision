import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';

import 'session_test.dart' show FakeApiTransport, MemorySessionVault;
import 'ui_test.dart'
    show profile, UiTransport, controller, narrowPhone, showTestApp;

Map<String, dynamic> emailChallenge() => {
  'requiresTwoFactor': true,
  'method': 'email',
  'challengeToken': 'email-challenge',
  'expiresIn': 600,
  'resendAfter': 60,
  'emailHint': 'm***@example.test',
  'mailSubject': 'Mã xác thực Chấm công',
  'user': {...profile(UserRole.consumer), 'emailConfirmed': false},
};
ApiReply reply(Object data) => ApiReply(200, jsonEncode(data));

class EmailUiTransport extends UiTransport {
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/auth/login')) return reply(emailChallenge());
    if (uri.path.endsWith('/auth/otp/verify')) {
      return reply({
        'accessToken': 'verified',
        'refreshToken': 'refresh',
        'expiresIn': 900,
        'user': {...profile(UserRole.consumer), 'emailConfirmed': true},
      });
    }
    return super.send(method, uri, headers, body);
  }
}

void main() {
  testWidgets(
    'email OTP disclosure and disabled resend remain usable at narrow text scale',
    (tester) async {
      narrowPhone(tester);
      final session = controller(EmailUiTransport());
      addTearDown(session.dispose);
      await showTestApp(tester, session);
      await tester.pumpAndSettle();
      expect(find.textContaining('Mã xác thực Chấm công'), findsNothing);
      await session.login('minh@example.test', 'Test-only-password!42');
      await tester.pumpAndSettle();
      expect(find.text('Xác thực email'), findsOneWidget);
      expect(find.textContaining('Mã xác thực Chấm công'), findsOneWidget);
      final resend = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Gửi lại sau 60 giây'),
      );
      expect(resend.onPressed, isNull);
      await tester.ensureVisible(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '123456');
      await tester.ensureVisible(find.text('Xác thực và đăng nhập'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác thực và đăng nhập'));
      await tester.pumpAndSettle();
      expect(session.signedIn, isTrue);
      expect(find.text('AI'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'email resend respects cooldown and adopts only the new server challenge',
    () async {
      final transport = FakeApiTransport(
        (request) => reply(
          request.uri.path.endsWith('/resend')
              ? {...emailChallenge(), 'challengeToken': 'new-challenge'}
              : emailChallenge(),
        ),
      );
      final session = SessionController(
        api: ApiClient(baseUrl: 'https://example.test', transport: transport),
        vault: MemorySessionVault(),
      );
      addTearDown(session.dispose);
      await session.login('minh@example.test', 'Test-only-password!42');
      expect(await session.resendEmailOtp(), isFalse);
      expect(transport.requests, hasLength(1));
      session.mfaResendAt = DateTime.now().subtract(const Duration(seconds: 1));
      expect(await session.resendEmailOtp(), isTrue);
      expect(transport.requests.last.body, {
        'challengeToken': 'email-challenge',
      });
      expect(session.mfaChallenge, 'new-challenge');
      expect(session.signedIn, isFalse);
      expect(session.mfaResendSeconds, greaterThan(0));
    },
  );
  test('registration enters email challenge without granting a session before verification', () async {
    final vault = MemorySessionVault();
    final transport = FakeApiTransport(
      (request) => reply(
        request.uri.path.endsWith('/auth/register')
            ? emailChallenge()
            : {
                'accessToken': 'verified-access',
                'refreshToken': 'verified-refresh',
                'expiresIn': 900,
                'user': {...profile(UserRole.consumer), 'emailConfirmed': true},
              },
      ),
    );
    final session = SessionController(
      api: ApiClient(baseUrl: 'https://example.test', transport: transport),
      vault: vault,
    );
    addTearDown(session.dispose);
    expect(
      await session.register(
        displayName: 'Minh',
        email: 'minh@example.test',
        password: 'Test-only-password!42',
        countryCode: 'VN',
        provinceCode: '82',
      ),
      isTrue,
    );
    expect(session.mfaChallenge, 'email-challenge');
    expect(session.signedIn, isFalse);
    expect(session.api.tokens, isNull);
    expect(vault.writes, isEmpty);
    expect(await session.completeMfa('123456'), isTrue);
    expect(transport.requests.last.uri.path, '/api/v1/auth/otp/verify');
    expect(session.user!.emailConfirmed, isTrue);
    expect(session.signedIn, isTrue);
  });
  test('password login email challenge uses email verification route and retains challenge after wrong code', () async {
    final transport = FakeApiTransport(
      (request) => request.uri.path.endsWith('/auth/login')
          ? reply(emailChallenge())
          : const ApiReply(400, '{"message":"Mã xác thực chưa đúng."}'),
    );
    final session = SessionController(
      api: ApiClient(baseUrl: 'https://example.test', transport: transport),
      vault: MemorySessionVault(),
    );
    addTearDown(session.dispose);
    await session.login('minh@example.test', 'Test-only-password!42');
    expect(await session.completeMfa('000000'), isFalse);
    expect(transport.requests.last.uri.path, '/api/v1/auth/otp/verify');
    expect(session.mfaChallenge, 'email-challenge');
    expect(session.signedIn, isFalse);
    expect(session.error, isNotEmpty);
  });
}
