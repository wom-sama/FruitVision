import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';

import 'session_test.dart' show FakeApiTransport, MemorySessionVault;

const _retired =
    'https://tips-differential-relating-validity.trycloudflare.com';
const _current = 'https://vip-certainly-broke-lease.trycloudflare.com';

TokenPair _tokens() => TokenPair(
  'retired-access',
  'retired-refresh',
  DateTime.now().toUtc().add(const Duration(hours: 1)),
);

Map<String, dynamic> _profile() => {
  'id': 'test-consumer',
  'displayName': 'Test Consumer',
  'email': 'test@example.test',
  'role': 'Consumer',
  'approvalStatus': 'Approved',
  'isActive': true,
};

void main() {
  test(
    'retired origin discards its session and challenge without HTTP',
    () async {
      final vault = MemorySessionVault(
        initial: {'baseUrl': _retired, 'tokens': _tokens().toJson()},
      );
      final transport = FakeApiTransport((_) {
        fail('An origin migration must not transmit old credentials.');
      });
      final api = ApiClient(transport: transport)..setTokens(_tokens());
      final session = SessionController(api: api, vault: vault)
        ..mfaChallenge = 'retired-challenge'
        ..mfaMethod = 'email'
        ..mfaEmailHint = 't***@example.test';
      addTearDown(session.dispose);

      expect(await session.initialize(), isTrue);
      expect(api.baseUrl, _current);
      expect(api.tokens, isNull);
      expect(session.signedIn, isFalse);
      expect(session.mfaChallenge, isNull);
      expect(session.mfaEmailHint, isNull);
      expect(session.notice, contains('đăng nhập lại'));
      expect(transport.requests, isEmpty);
      expect(vault.value, {'baseUrl': _current});
      expect(vault.writes, hasLength(1));
      expect(session.loading, isFalse);

      // A second startup must not repeat migration or create a network request.
      expect(await session.initialize(), isTrue);
      expect(vault.writes, hasLength(1));
      expect(transport.requests, isEmpty);
    },
  );

  test('custom and other tunnel origins retain their own session', () async {
    for (final origin in [
      'https://custom.example.test',
      'https://another-tunnel.trycloudflare.com',
      'https://tips-differential-relating-validity.trycloudflare.com.example.test',
    ]) {
      final pair = _tokens();
      final vault = MemorySessionVault(
        initial: {'baseUrl': origin, 'tokens': pair.toJson()},
      );
      final transport = FakeApiTransport((request) {
        expect(request.uri.origin, origin);
        expect(request.uri.path, '/api/v1/auth/me');
        expect(request.headers['Authorization'], 'Bearer retired-access');
        return ApiReply(200, jsonEncode(_profile()));
      });
      final session = SessionController(
        api: ApiClient(transport: transport),
        vault: vault,
      );
      addTearDown(session.dispose);

      expect(await session.initialize(), isTrue);
      expect(session.api.baseUrl, origin);
      expect(session.api.tokens?.refreshToken, pair.refreshToken);
      expect(session.signedIn, isTrue);
      expect(session.notice, isNull);
      expect(transport.requests, hasLength(1));
      expect(vault.writes, isEmpty);
    }
  });

  test(
    'current origin restores normally without dropping its session',
    () async {
      final pair = _tokens();
      final vault = MemorySessionVault(
        initial: {'baseUrl': _current, 'tokens': pair.toJson()},
      );
      final transport = FakeApiTransport((request) {
        expect(request.uri.origin, _current);
        expect(request.uri.path, '/api/v1/auth/me');
        expect(request.headers['Authorization'], 'Bearer retired-access');
        return ApiReply(200, jsonEncode(_profile()));
      });
      final session = SessionController(
        api: ApiClient(transport: transport),
        vault: vault,
      );
      addTearDown(session.dispose);

      expect(await session.initialize(), isTrue);
      expect(session.signedIn, isTrue);
      expect(session.api.tokens?.refreshToken, pair.refreshToken);
      expect(transport.requests, hasLength(1));
      expect(vault.writes, isEmpty);
      expect(session.notice, isNull);
    },
  );

  test(
    'fresh installation uses the current compiled origin without HTTP',
    () async {
      final vault = MemorySessionVault();
      final transport = FakeApiTransport((_) {
        fail('A fresh installation must wait for explicit sign in.');
      });
      final session = SessionController(
        api: ApiClient(transport: transport),
        vault: vault,
      );
      addTearDown(session.dispose);

      expect(defaultApiUrl, _current);
      expect(await session.initialize(), isTrue);
      expect(session.api.baseUrl, _current);
      expect(session.api.tokens, isNull);
      expect(session.signedIn, isFalse);
      expect(transport.requests, isEmpty);
      expect(vault.writes, isEmpty);
    },
  );
}
