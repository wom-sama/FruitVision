import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/secret_messaging.dart';
import 'package:fruitvision_client/client/secret_protocol.dart';
import 'package:fruitvision_client/client/session.dart';

import 'session_test.dart' show MemorySessionVault;
import 'secret_protocol_test.dart'
    show ownUser, peerUser, ownDevice, peerDevice, roomId, messageId;

class MemorySecretStore extends SecretKeyStore {
  String? value;
  Completer<String?>? readGate;
  final writes = <String>[];
  @override
  Future<String?> read(String origin, String userId) async =>
      readGate == null ? value : readGate!.future;
  @override
  Future<void> write(String origin, String userId, String value) async {
    writes.add(value);
    this.value = value;
  }

  @override
  Future<void> delete(String origin, String userId) async {
    value = null;
  }
}

class SecretTransport implements ApiTransport {
  late FutureOr<ApiReply> Function(String, String, Map<String, dynamic>?)
  handle;
  final calls = <(String, String, Map<String, dynamic>?)>[];
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    final data = body == null ? null : jsonDecode(body) as Map<String, dynamic>;
    calls.add((method, uri.path, data));
    return handle(method, uri.path, data);
  }

  @override
  void close() {}
}

ApiReply reply(Object data, {int status = 200}) =>
    ApiReply(status, jsonEncode(data));
Map<String, dynamic> seller() => {
  'id': ownUser,
  'displayName': 'Nhà sản xuất',
  'email': 'a@example.test',
  'role': 'Producer',
  'approvalStatus': 'Approved',
  'region': 'Đồng Tháp',
  'isActive': true,
  'emailConfirmed': true,
};
Map<String, dynamic> device(SecretIdentity identity, {bool peer = false}) => {
  'userId': peer ? peerUser : ownUser,
  'deviceId': peer ? peerDevice : ownDevice,
  'version': 1,
  'encryptionPublicKey': base64Encode(identity.encryptionPublicKey),
  'signingPublicKey': base64Encode(identity.signingPublicKey),
  'label': peer ? 'Thiết bị B' : 'Thiết bị A',
  'revokedAt': null,
};

void main() {
  late SecretCryptography crypto;
  setUpAll(() async {
    crypto = await SodiumSecretCryptography.load();
  });
  late SecretIdentity own, peer;
  late MemorySecretStore store;
  late SecretTransport transport;
  late SessionController session;
  late SecretMessaging secrets;
  late Map<String, dynamic> ownBundle, peerBundle;
  List<Map<String, dynamic>> messages = [];
  setUp(() {
    own = crypto.generateIdentity();
    peer = crypto.generateIdentity();
    ownBundle = device(own);
    peerBundle = device(peer, peer: true);
    messages = [];
    final exported = own.exportKeys();
    store = MemorySecretStore()
      ..value = jsonEncode({
        'schemaVersion': 1,
        'deviceId': ownDevice,
        'keys': base64Encode(exported),
        'pins': <String, String>{},
      });
    exported.fillRange(0, exported.length, 0);
    transport = SecretTransport()
      ..handle = (method, path, body) {
        if (path.endsWith('/secret/devices')) {
          return reply({
            'items': [ownBundle],
          });
        }
        if (path.endsWith('/bundles')) {
          return reply({
            'items': [ownBundle, peerBundle],
          });
        }
        if (path.endsWith('/messages')) {
          return reply({
            'items': messages,
            'nextBefore': null,
            'nextAfter': null,
          });
        }
        return reply({});
      };
    session =
        SessionController(
            api: ApiClient(
              baseUrl: 'https://example.test',
              transport: transport,
            ),
            vault: MemorySessionVault(),
          )
          ..loading = false
          ..user = Account.fromJson(seller());
    session.api.setTokens(
      TokenPair(
        'access',
        'refresh',
        DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    secrets = SecretMessaging(
      session: session,
      store: store,
      cryptoLoader: () async => crypto,
    );
  });
  tearDown(() {
    secrets.dispose();
    session.dispose();
    own.dispose();
    peer.dispose();
  });
  Future<void> confirm() async {
    final room = await secrets.inspectRoom(roomId);
    await secrets.confirmRoom(roomId, room.fingerprint);
  }

  Map<String, dynamic> incoming({SecretPacket? packet}) {
    final content =
        packet ??
        const SecretPacket(
          conversationId: roomId,
          senderUserId: peerUser,
          senderDeviceId: peerDevice,
          clientMessageId: messageId,
          text: 'Riêng tư',
        );
    return {
      'id': messageId,
      'conversationId': roomId,
      'sequence': 1,
      'clientMessageId': content.clientMessageId,
      'senderUserId': peerUser,
      'senderDeviceId': peerDevice,
      'senderKeyVersion': 1,
      'senderSigningPublicKey': peerBundle['signingPublicKey'],
      'envelope': {
        'recipientDeviceId': ownDevice,
        'recipientKeyVersion': 1,
        'ciphertextBase64': base64Encode(
          crypto.seal(peer, content, own.encryptionPublicKey),
        ),
      },
    };
  }

  test('no plaintext fetch or send before explicit full safety-number confirmation', () async {
    final page = await secrets.messages(roomId);
    expect(page.room.verified, isFalse);
    expect(page.messages, isEmpty);
    expect(transport.calls.where((c) => c.$2.endsWith('/messages')), isEmpty);
    await expectLater(
      secrets.prepare(roomId, 'Không gửi trước xác minh'),
      throwsA(isA<ApiException>()),
    );
    expect(store.writes, isEmpty);
    await confirm();
    expect((await secrets.inspectRoom(roomId)).verified, isTrue);
    expect(jsonDecode(store.value!)['pins'][roomId], hasLength(64));
  });
  test('real prepared envelopes contain no plaintext or private keys and exact retries reuse ciphertext', () async {
    await confirm();
    final prepared = await secrets.prepare(
      roomId,
      'Nội dung chỉ hai thiết bị đọc',
    );
    final encoded = jsonEncode(prepared.body);
    expect(encoded, isNot(contains('Nội dung')));
    expect(encoded, isNot(contains('keys')));
    final envelopes = prepared.body['envelopes'] as List;
    expect(envelopes, hasLength(2));
    for (final envelope in envelopes) {
      final recipient = envelope['recipientDeviceId'] == ownDevice ? own : peer;
      final opened = crypto.open(
        recipient,
        base64Decode(envelope['ciphertextBase64'] as String),
        own.signingPublicKey,
      );
      expect(opened.text, 'Nội dung chỉ hai thiết bị đọc');
      expect(opened.conversationId, roomId);
    }
    var attempts = 0;
    final previous = transport.handle;
    transport.handle = (method, path, body) {
      if (method == 'POST' && path.endsWith('/messages')) {
        attempts++;
        return attempts == 1
            ? reply({'detail': 'Chưa xác nhận'}, status: 503)
            : reply({});
      }
      return previous(method, path, body);
    };
    await expectLater(secrets.send(prepared), throwsA(isA<ApiException>()));
    await secrets.send(prepared);
    final sent = transport.calls
        .where((c) => c.$1 == 'POST' && c.$2.endsWith('/messages'))
        .toList();
    expect(sent, hasLength(2));
    expect(jsonEncode(sent[0].$3), jsonEncode(sent[1].$3));
  });
  test('peer key change invalidates pinned room and prevents retrying prepared ciphertext', () async {
    await confirm();
    final prepared = await secrets.prepare(roomId, 'Tin chưa gửi');
    final replacement = crypto.generateIdentity();
    addTearDown(replacement.dispose);
    peerBundle = device(replacement, peer: true);
    final changed = await secrets.inspectRoom(roomId);
    expect(changed.changed, isTrue);
    expect(changed.verified, isFalse);
    await expectLater(secrets.send(prepared), throwsA(isA<ApiException>()));
    expect(
      transport.calls.where(
        (c) => c.$1 == 'POST' && c.$2.endsWith('/messages'),
      ),
      isEmpty,
    );
  });
  test(
    'server own public-key substitution is rejected before peer verification',
    () async {
      ownBundle = {
        ...ownBundle,
        'encryptionPublicKey': peerBundle['encryptionPublicKey'],
      };
      await expectLater(
        secrets.inspectRoom(roomId),
        throwsA(isA<ApiException>()),
      );
      expect(store.writes, isEmpty);
    },
  );
  test('real signature and packet are bound to DTO room user device client key version and recipient', () async {
    await confirm();
    messages = [incoming()];
    expect(
      (await secrets.messages(roomId)).messages.single.packet!.text,
      'Riêng tư',
    );
    for (final field in [
      'conversationId',
      'senderUserId',
      'senderDeviceId',
      'clientMessageId',
      'senderKeyVersion',
      'senderSigningPublicKey',
    ]) {
      final row = incoming();
      row[field] = field == 'senderKeyVersion'
          ? 2
          : field == 'senderSigningPublicKey'
          ? ownBundle['signingPublicKey']
          : ownUser;
      messages = [row];
      expect(
        (await secrets.messages(roomId)).messages.single.packet,
        isNull,
        reason: field,
      );
    }
    for (final field in ['recipientDeviceId', 'recipientKeyVersion']) {
      final row = incoming();
      (row['envelope'] as Map)[field] = field == 'recipientKeyVersion'
          ? 2
          : peerDevice;
      messages = [row];
      expect(
        (await secrets.messages(roomId)).messages.single.packet,
        isNull,
        reason: field,
      );
    }
    messages = [
      incoming(
        packet: const SecretPacket(
          conversationId: messageId,
          senderUserId: peerUser,
          senderDeviceId: peerDevice,
          clientMessageId: messageId,
          text: 'Sai phòng đã ký',
        ),
      ),
    ];
    expect((await secrets.messages(roomId)).messages.single.packet, isNull);
  });
  test('memory lock drops loaded identity but preserves encrypted keybag and verified pins for reopen', () async {
    await confirm();
    expect(secrets.deviceId, ownDevice);
    final saved = store.value;
    secrets.lockMemory();
    expect(secrets.deviceId, isNull);
    expect(store.value, saved);
    expect((await secrets.inspectRoom(roomId)).verified, isTrue);
    await session.logout();
    expect(secrets.deviceId, isNull);
    expect(store.value, saved);
    await expectLater(
      secrets.inspectRoom(roomId),
      throwsA(isA<ApiException>()),
    );
  });
  test('server change during native keybag read never adopts old-origin identity or queries bundles', () async {
    store.readGate = Completer<String?>();
    final opening = secrets.inspectRoom(roomId);
    final failed = expectLater(opening, throwsA(isA<ApiException>()));
    await session.changeServer('https://other.test');
    store.readGate!.complete(store.value);
    await failed;
    expect(secrets.deviceId, isNull);
    expect(transport.calls.where((c) => c.$2.endsWith('/bundles')), isEmpty);
  });
  test('enrollment persists device keybag before POST and recovers lost response with same immutable key', () async {
    store.value = null;
    var active = <Map<String, dynamic>>[];
    var posts = 0;
    transport.handle = (method, path, body) {
      if (path.endsWith('/auth/login')) {
        return reply({
          'requiresTwoFactor': true,
          'method': 'email',
          'challengeToken': 'password-backed',
        });
      }
      if (path.endsWith('/auth/otp/verify')) {
        return reply({
          'accessToken': 'access',
          'refreshToken': 'refresh',
          'expiresIn': 900,
          'user': seller(),
        });
      }
      if (path.endsWith('/secret/devices') && method == 'GET') {
        return reply({'items': active});
      }
      if (path.endsWith('/secret/devices') && method == 'POST') {
        expect(store.value, isNotNull);
        expect(jsonDecode(store.value!)['deviceId'], body!['deviceId']);
        posts++;
        active = [
          {...body, 'userId': ownUser, 'version': 1, 'revokedAt': null},
        ];
        return posts == 1
            ? reply({'detail': 'Réponse perdue'}, status: 503)
            : reply(active.single);
      }
      return reply({});
    };
    await session.login('a@example.test', 'password');
    await session.completeMfa('123456');
    await expectLater(
      secrets.registerDevice(label: 'A', allowNewIdentity: true),
      throwsA(isA<ApiException>()),
    );
    final persisted = store.value;
    await secrets.registerDevice(label: 'A', allowNewIdentity: false);
    expect(store.value, persisted);
    final registered = transport.calls
        .where((c) => c.$1 == 'POST' && c.$2.endsWith('/secret/devices'))
        .toList();
    expect(registered, hasLength(2));
    expect(registered[0].$3, registered[1].$3);
    expect(registered.last.$3!.containsKey('keys'), isFalse);
  });
}
