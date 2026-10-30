import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/vault.dart';

const _origin = 'https://fruitvision.example';
const _secondOrigin = 'https://another-fruitvision.example';
const _password = 'Only-a-test-password-42!';

class RecordedRequest {
  RecordedRequest(
    this.method,
    this.uri,
    Map<String, String> headers,
    String? body,
  ) : headers = Map.of(headers),
      body = body == null ? null : jsonDecode(body) as Map<String, dynamic>;

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic>? body;
}

class FakeApiTransport implements ApiTransport {
  FakeApiTransport(this.respond);

  final FutureOr<ApiReply> Function(RecordedRequest request) respond;
  final requests = <RecordedRequest>[];
  bool closed = false;

  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    final request = RecordedRequest(method, uri, headers, body);
    requests.add(request);
    return await respond(request);
  }

  @override
  void close() => closed = true;
}

class MemorySessionVault implements SessionVault {
  MemorySessionVault({Map<String, dynamic>? initial})
    : value = initial == null ? null : _copy(initial);

  Map<String, dynamic>? value;
  final writes = <Map<String, dynamic>>[];
  Future<void> Function(Map<String, dynamic> value)? beforeWrite;

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>?> read() async =>
      value == null ? null : _copy(value!);

  @override
  Future<void> write(Map<String, dynamic> next) async {
    final snapshot = _copy(next);
    await beforeWrite?.call(snapshot);
    value = snapshot;
    writes.add(_copy(snapshot));
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

Map<String, dynamic> _profile({
  String role = 'Producer',
  String status = 'Pending',
  bool active = true,
}) => {
  'id': 'test-account',
  'displayName': 'Test account',
  'email': 'test@example.test',
  'role': role,
  'approvalStatus': status,
  'region': 'Đồng Tháp',
  'isActive': active,
  'reviewReason': status == 'NeedsInformation' ? 'Add information' : null,
  'twoFactorEnabled': false,
};

Map<String, dynamic> _sessionResponse({
  String access = 'initial-access',
  String refresh = 'initial-refresh',
  Map<String, dynamic>? user,
}) => {
  'accessToken': access,
  'refreshToken': refresh,
  'expiresIn': 900,
  'user': user ?? _profile(),
};

ApiReply _jsonReply(int status, Map<String, dynamic> body) =>
    ApiReply(status, jsonEncode(body));

Matcher _apiStatus(int status) =>
    isA<ApiException>().having((error) => error.status, 'status', status);

void main() {
  test('MFA challenge stays signed out until verification succeeds', () async {
    final vault = MemorySessionVault();
    final transport = FakeApiTransport((request) {
      expect(request.headers.containsKey('Authorization'), isFalse);
      if (request.uri.path.endsWith('/auth/login')) {
        return _jsonReply(200, {
          'requiresTwoFactor': true,
          'challengeToken': 'test-mfa-challenge',
          'expiresIn': 300,
        });
      }
      expect(request.uri.path, '/api/v1/auth/mfa/login');
      expect(request.body, {
        'challengeToken': 'test-mfa-challenge',
        'code': '123456',
      });
      return _jsonReply(200, _sessionResponse());
    });
    final controller = SessionController(
      api: ApiClient(baseUrl: _origin, transport: transport),
      vault: vault,
    );
    addTearDown(controller.dispose);

    expect(await controller.login('test@example.test', _password), isTrue);
    expect(controller.mfaChallenge, 'test-mfa-challenge');
    expect(controller.signedIn, isFalse);
    expect(controller.user, isNull);
    expect(controller.api.tokens, isNull);
    expect(vault.writes, isEmpty);

    expect(await controller.completeMfa(' 123456 '), isTrue);
    expect(controller.signedIn, isTrue);
    expect(controller.mfaChallenge, isNull);
    expect(vault.value!['tokens'], controller.api.tokens!.toJson());
    expect(jsonEncode(vault.writes), isNot(contains(_password)));
    expect(jsonEncode(vault.writes), isNot(contains('challengeToken')));
  });

  test(
    'login and refresh persist both rotated tokens before protected retry',
    () async {
      final vault = MemorySessionVault();
      final transport = FakeApiTransport((request) {
        if (request.uri.path.endsWith('/auth/login')) {
          expect(request.body!['email'], 'test@example.test');
          return _jsonReply(200, _sessionResponse());
        }
        if (request.uri.path.endsWith('/auth/refresh')) {
          expect(request.body, {'refreshToken': 'initial-refresh'});
          expect(request.headers.containsKey('Authorization'), isFalse);
          return _jsonReply(
            200,
            _sessionResponse(
              access: 'rotated-access',
              refresh: 'rotated-refresh',
            ),
          );
        }
        if (request.headers['Authorization'] == 'Bearer initial-access') {
          return const ApiReply(401, '');
        }
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        expect(
          (vault.value!['tokens'] as Map)['accessToken'],
          'rotated-access',
        );
        expect(
          (vault.value!['tokens'] as Map)['refreshToken'],
          'rotated-refresh',
        );
        return _jsonReply(200, _profile(status: 'Approved'));
      });
      final controller = SessionController(
        api: ApiClient(baseUrl: _origin, transport: transport),
        vault: vault,
      );
      addTearDown(controller.dispose);

      expect(await controller.login(' test@example.test ', _password), isTrue);
      expect(await controller.refreshProfile(), isTrue);
      expect(controller.api.tokens!.accessToken, 'rotated-access');
      expect(controller.api.tokens!.refreshToken, 'rotated-refresh');
      expect(vault.value!.keys, unorderedEquals(['baseUrl', 'tokens']));
      expect(vault.value!['tokens'], controller.api.tokens!.toJson());
      expect(jsonEncode(vault.writes), isNot(contains(_password)));
      expect(jsonEncode(vault.writes), isNot(contains('password')));
    },
  );

  test(
    'registration sends API location codes without a selectable role or region',
    () async {
      final vault = MemorySessionVault();
      final transport = FakeApiTransport((_) => const ApiReply(201, '{}'));
      final controller = SessionController(
        api: ApiClient(baseUrl: _origin, transport: transport),
        vault: vault,
      );
      addTearDown(controller.dispose);

      expect(
        await controller.register(
          displayName: 'Test account',
          email: 'test@example.test',
          password: _password,
          countryCode: 'VN',
          provinceCode: '82',
        ),
        isTrue,
      );
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.body, {
        'displayName': 'Test account',
        'email': 'test@example.test',
        'password': _password,
        'countryCode': 'VN',
        'provinceCode': '82',
      });
      expect(vault.writes, isEmpty);
      expect(controller.signedIn, isFalse);
      expect(controller.error, isNull);
    },
  );

  test(
    'permissions follow Pending, Approved and inactive server profiles',
    () async {
      var profile = _profile();
      final transport = FakeApiTransport(
        (request) => _jsonReply(
          200,
          request.uri.path.endsWith('/auth/login')
              ? _sessionResponse(user: profile)
              : profile,
        ),
      );
      final controller = SessionController(
        api: ApiClient(baseUrl: _origin, transport: transport),
        vault: MemorySessionVault(),
      );
      addTearDown(controller.dispose);

      expect(await controller.login('test@example.test', _password), isTrue);
      expect(controller.signedIn, isTrue);
      expect(controller.user!.approvalStatus, ApprovalStatus.pending);
      expect(controller.user!.isApproved, isFalse);
      expect(controller.user!.canSell, isFalse);
      profile = _profile(status: 'Approved');
      expect(await controller.refreshProfile(), isTrue);
      expect(controller.user!.isApproved, isTrue);
      expect(controller.user!.canSell, isTrue);
      profile = _profile(status: 'Approved', active: false);
      expect(await controller.refreshProfile(), isTrue);
      expect(controller.user!.isApproved, isFalse);
      expect(controller.user!.canSell, isFalse);
      profile = _profile(role: 'Consumer', status: 'Approved');
      expect(await controller.refreshProfile(), isTrue);
      expect(controller.user!.role, UserRole.consumer);
      expect(controller.user!.canSell, isFalse);
    },
  );

  for (final invalidProfile in [
    _profile(role: 'UnknownRole', status: 'Approved'),
    _profile(status: 'UnknownApproval'),
  ]) {
    test(
      'unknown account values fail closed: '
      '${invalidProfile['role']}/${invalidProfile['approvalStatus']}',
      () async {
        final vault = MemorySessionVault();
        final transport = FakeApiTransport(
          (_) => _jsonReply(200, _sessionResponse(user: invalidProfile)),
        );
        final controller = SessionController(
          api: ApiClient(baseUrl: _origin, transport: transport),
          vault: vault,
        );
        addTearDown(controller.dispose);

        expect(await controller.login('test@example.test', _password), isFalse);
        expect(controller.signedIn, isFalse);
        expect(controller.api.tokens, isNull);
        expect(vault.writes, isEmpty);
        expect(controller.error, isNotEmpty);
      },
    );
  }

  test(
    'logout clears local identity and credentials when server is unavailable',
    () async {
      final vault = MemorySessionVault();
      final transport = FakeApiTransport(
        (request) => request.uri.path.endsWith('/auth/login')
            ? _jsonReply(200, _sessionResponse())
            : const ApiReply(503, ''),
      );
      final controller = SessionController(
        api: ApiClient(baseUrl: _origin, transport: transport),
        vault: vault,
      );
      addTearDown(controller.dispose);

      expect(await controller.login('test@example.test', _password), isTrue);
      expect(await controller.logout(), isTrue);
      expect(controller.signedIn, isFalse);
      expect(controller.api.tokens, isNull);
      expect(controller.mfaChallenge, isNull);
      expect(vault.value, {'baseUrl': _origin});
      expect(controller.notice, isNotEmpty);
    },
  );

  test('invalid server URLs never receive the current credentials', () async {
    final vault = MemorySessionVault();
    final transport = FakeApiTransport(
      (request) => _jsonReply(
        200,
        request.uri.path.endsWith('/auth/login')
            ? _sessionResponse()
            : _profile(),
      ),
    );
    final controller = SessionController(
      api: ApiClient(baseUrl: _origin, transport: transport),
      vault: vault,
    );
    addTearDown(controller.dispose);
    expect(await controller.login('test@example.test', _password), isTrue);
    final beforeChanges = transport.requests.length;

    for (final url in [
      'http://untrusted.example',
      'https://user:password@untrusted.example',
      'https://untrusted.example/path',
      'https://untrusted.example?token=leak',
      'https://untrusted.example#fragment',
      '//untrusted.example',
    ]) {
      expect(await controller.changeServer(url), isFalse);
      expect(controller.api.baseUrl, _origin);
      expect(controller.api.tokens!.accessToken, 'initial-access');
    }
    expect(transport.requests.length, beforeChanges);
    expect(await controller.refreshProfile(), isTrue);
    expect(transport.requests.last.uri.origin, _origin);
    expect(
      transport.requests.last.headers['Authorization'],
      'Bearer initial-access',
    );
    expect(vault.value!['baseUrl'], _origin);
  });

  for (final refreshStatus in [503, 401]) {
    test(
      'refresh $refreshStatus ${refreshStatus == 503 ? 'retains' : 'clears'} '
      'the stored credential pair',
      () async {
        final vault = MemorySessionVault();
        final transport = FakeApiTransport((request) {
          if (request.uri.path.endsWith('/auth/login')) {
            return _jsonReply(200, _sessionResponse());
          }
          if (request.uri.path.endsWith('/auth/refresh')) {
            return ApiReply(refreshStatus, '');
          }
          return const ApiReply(401, '');
        });
        final controller = SessionController(
          api: ApiClient(baseUrl: _origin, transport: transport),
          vault: vault,
        );
        addTearDown(controller.dispose);
        expect(await controller.login('test@example.test', _password), isTrue);

        await expectLater(
          controller.api.get('/history'),
          throwsA(_apiStatus(refreshStatus)),
        );
        if (refreshStatus == 503) {
          expect(controller.api.tokens!.refreshToken, 'initial-refresh');
          expect(
            (vault.value!['tokens'] as Map)['refreshToken'],
            'initial-refresh',
          );
          expect(controller.signedIn, isTrue);
        } else {
          expect(controller.api.tokens, isNull);
          expect(controller.signedIn, isFalse);
          expect(vault.value, {'baseUrl': _origin});
        }
        expect(
          transport.requests
              .where((request) => request.uri.path.endsWith('/history'))
              .length,
          1,
        );
      },
    );
  }

  for (final transition in ['logout', 'server change']) {
    for (final phase in ['network', 'vault write']) {
      test(
        '$transition during refresh $phase cannot restore credentials',
        () async {
          final vault = MemorySessionVault();
          final refreshStarted = Completer<void>();
          final refreshReply = Completer<ApiReply>();
          final persistenceStarted = Completer<void>();
          final allowPersistence = Completer<void>();
          final transport = FakeApiTransport((request) {
            if (request.uri.path.endsWith('/auth/login')) {
              return _jsonReply(200, _sessionResponse());
            }
            if (request.uri.path.endsWith('/auth/logout')) {
              return const ApiReply(204, '');
            }
            if (request.uri.path.endsWith('/auth/refresh')) {
              refreshStarted.complete();
              return refreshReply.future;
            }
            return const ApiReply(401, '');
          });
          final controller = SessionController(
            api: ApiClient(baseUrl: _origin, transport: transport),
            vault: vault,
          );
          addTearDown(controller.dispose);
          expect(
            await controller.login('test@example.test', _password),
            isTrue,
          );
          vault.beforeWrite = (value) async {
            if ((value['tokens'] as Map?)?['refreshToken'] ==
                'rotated-refresh') {
              persistenceStarted.complete();
              await allowPersistence.future;
            }
          };

          final protectedResult = expectLater(
            controller.api.get('/history'),
            throwsA(_apiStatus(401)),
          );
          await refreshStarted.future;
          final rotated = _jsonReply(
            200,
            _sessionResponse(
              access: 'rotated-access',
              refresh: 'rotated-refresh',
            ),
          );
          if (phase == 'vault write') {
            refreshReply.complete(rotated);
            await persistenceStarted.future;
          }

          final changed = transition == 'logout'
              ? controller.logout()
              : controller.changeServer(_secondOrigin);
          // Let logout finish its HTTP await and enqueue its vault write.
          await Future<void>.delayed(Duration.zero);
          expect(controller.api.tokens, isNull);
          expect(controller.signedIn, isFalse);
          if (phase == 'network') refreshReply.complete(rotated);
          allowPersistence.complete();
          expect(await changed, isTrue);
          await protectedResult;

          expect(controller.api.tokens, isNull);
          expect(controller.signedIn, isFalse);
          expect(vault.value, {
            'baseUrl': transition == 'logout' ? _origin : _secondOrigin,
          });
          expect(
            transport.requests
                .where((request) => request.uri.path.endsWith('/history'))
                .length,
            1,
          );
          expect(
            transport.requests.every(
              (request) => request.uri.origin == _origin,
            ),
            isTrue,
          );
        },
      );
    }
  }
}
