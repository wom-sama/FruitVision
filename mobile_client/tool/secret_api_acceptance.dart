// DORMANT: root must explicitly authorize the live run and provide fresh sessions.
// Pinned Dart: dart run tool/secret_api_acceptance.dart --run --sessions PRIVATE.json
//   --report verification/2.4/secret-api-acceptance.json
// Private JSON shape (never commit): {baseUrl,directConversationId,imagePath,
// producer:{accessToken,refreshToken,expiresIn},trader:{...}}.
// imagePath is a local canonical JPEG <=5 MiB and <=2048px per dimension.
// Refuses any pre-existing active E2EE device. Finally revokes ONLY generated IDs.
// Keys exist in host RAM only. This harness does not exercise Android Keystore.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/secret_protocol.dart';

typedef Json = Map<String, dynamic>;

class _Failure implements Exception {
  const _Failure(this.check);
  final String check;
}

class _ObservedTransport implements ApiTransport {
  final _inner = IoApiTransport();
  final observedJson = <String>[];
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (body != null) observedJson.add(body);
    final reply = await _inner.send(method, uri, headers, body);
    observedJson.add(reply.body);
    return reply;
  }

  @override
  void close() => _inner.close();
}

List<Json> _rows(Json data) => (data['items'] as List)
    .map((row) => Map<String, dynamic>.from(row as Map))
    .toList();

Future<void> main(List<String> args) async {
  String? option(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  if (args.contains('--help') || !args.contains('--run')) {
    stdout.writeln(
      'Dormant host acceptance. Use --run --sessions PRIVATE.json --report REPORT.json only after root authorizes live mutations.',
    );
    return;
  }
  final sessionPath = option('--sessions'), reportPath = option('--report');
  if (sessionPath == null || reportPath == null) {
    stderr.writeln('Required: --sessions PRIVATE.json --report REPORT.json');
    exitCode = 64;
    return;
  }
  final checks = <Json>[],
      clients = <ApiClient>[],
      transports = <_ObservedTransport>[];
  final registered = <(ApiClient, String)>[];
  final identities = <SecretIdentity>[];
  final started = DateTime.now().toUtc();
  var phase = 'read-private-input', success = false;
  String? origin, conversationId;
  void check(String name, bool pass) {
    checks.add({'check': name, 'pass': pass});
    if (!pass) throw _Failure(name);
  }

  Future<T> step<T>(String name, Future<T> Function() work) async {
    phase = name;
    if (DateTime.now().toUtc().difference(started) >
        const Duration(minutes: 3)) {
      throw const _Failure('three-minute-operation-budget');
    }
    return await work().timeout(const Duration(seconds: 25));
  }

  try {
    final file = File(sessionPath);
    if (await file.length() > 32768) throw const _Failure('private-input-size');
    final input = jsonDecode(await file.readAsString()) as Json;
    final baseUrl = ApiClient.validateBaseUrl(input['baseUrl'] as String);
    origin = baseUrl;
    final directId = input['directConversationId'];
    check('input-direct-uuid', secretUuid(directId));
    final photoPath = input['imagePath'];
    check(
      'explicit-local-jpeg-fixture',
      photoPath is String && photoPath.isNotEmpty,
    );
    final photo = File(photoPath as String);
    check('photo-size-bound', await photo.length() <= secretImageLimit);
    final jpeg = await photo.readAsBytes();
    secretJpegSize(jpeg);
    final originalImageDigest = digestHex(jpeg);
    final crypto = await SodiumSecretCryptography.load();
    final localIds = <String>[],
        profiles = <Json>[],
        bundles = <SecretBundle>[];
    for (final role in ['producer', 'trader']) {
      final account = Map<String, dynamic>.from(input[role] as Map);
      final transport = _ObservedTransport();
      transports.add(transport);
      final client = ApiClient(baseUrl: baseUrl, transport: transport);
      clients.add(client);
      client.setTokens(
        TokenPair(
          account['accessToken'] as String,
          account['refreshToken'] as String,
          DateTime.now().add(
            Duration(
              seconds: (account['expiresIn'] as num? ?? 600).toInt().clamp(
                1,
                900,
              ),
            ),
          ),
        ),
      );
      final profile = await step('$role-profile', () => client.get('/auth/me'));
      check(
        '$role-active-approved-verified',
        profile['role'] == (role == 'producer' ? 'Producer' : 'Trader') &&
            profile['approvalStatus'] == 'Approved' &&
            profile['isActive'] == true &&
            profile['emailConfirmed'] == true &&
            secretUuid(profile['id']),
      );
      profiles.add(profile);
      final devices = await step(
        '$role-existing-devices',
        () => client.get('/secret/devices'),
      );
      check(
        '$role-no-foreign-active-device',
        _rows(devices).every((row) => row['revokedAt'] != null),
      );
    }
    check(
      'two-distinct-seller-accounts',
      profiles[0]['id'] != profiles[1]['id'],
    );
    // Check BOTH accounts before registering either; never displace a real device.
    for (var index = 0; index < 2; index++) {
      final identity = crypto.generateIdentity();
      identities.add(identity);
      final id = crypto.newId();
      localIds.add(id);
      registered.add((
        clients[index],
        id,
      )); // Includes a potentially committed lost response.
      final dto = await step(
        'register-host-device-$index',
        () => clients[index].post('/secret/devices', {
          'deviceId': id,
          'label': 'Authorized host acceptance',
          'encryptionPublicKey': base64Encode(identity.encryptionPublicKey),
          'signingPublicKey': base64Encode(identity.signingPublicKey),
        }),
      );
      final bundle = SecretBundle.fromJson(dto);
      bundles.add(bundle);
      check(
        'own-api-key-matches-local-$index',
        bundle.userId == profiles[index]['id'] &&
            bundle.deviceId == id &&
            sameBytes(bundle.encryptionKey, identity.encryptionPublicKey) &&
            sameBytes(bundle.signingKey, identity.signingPublicKey),
      );
    }
    final created = await step(
      'create-secret-from-existing-direct',
      () => clients[0].post('/secret/conversations', {
        'directConversationId': directId,
      }),
    );
    conversationId = created['id'] as String;
    check(
      'secret-conversation-binding',
      secretUuid(conversationId) &&
          created['directConversationId'] == directId &&
          {
            created['firstUserId'],
            created['secondUserId'],
          }.containsAll(profiles.map((profile) => profile['id'])),
    );
    final fingerprints = <String>[];
    for (var index = 0; index < 2; index++) {
      final response = await step(
        'fetch-key-bundles-$index',
        () =>
            clients[index].get('/secret/conversations/$conversationId/bundles'),
      );
      final received = _rows(response).map(SecretBundle.fromJson).toList();
      check(
        'exact-two-known-local-bundles-$index',
        received.length == 2 &&
            received.every(
              (bundle) => bundles.any(
                (known) =>
                    jsonEncode(known.canonical) == jsonEncode(bundle.canonical),
              ),
            ),
      );
      fingerprints.add(safetyFingerprint(baseUrl, conversationId, received));
    }
    check(
      'host-known-key-full-fingerprint-parity',
      fingerprints[0] == fingerprints[1] && fingerprints[0].length == 64,
    );
    // This compares two harness-owned identities; it is NOT a human OOB ceremony.
    final marker = 'client-only-secret-${crypto.newId()}';
    final messageId = crypto.newId();
    final packet = SecretPacket(
      conversationId: conversationId,
      senderUserId: bundles[0].userId,
      senderDeviceId: localIds[0],
      clientMessageId: messageId,
      text: marker,
    );
    final outgoing = {
      'clientMessageId': messageId,
      'senderDeviceId': localIds[0],
      'envelopes': [
        for (final bundle in bundles)
          {
            'recipientDeviceId': bundle.deviceId,
            'ciphertextBase64': base64Encode(
              crypto.seal(identities[0], packet, bundle.encryptionKey),
            ),
          },
      ],
    };
    final sent = await step(
      'send-signed-sealed-text',
      () => clients[0].post(
        '/secret/conversations/$conversationId/messages',
        outgoing,
      ),
    );
    final retry = await step(
      'exact-idempotent-text-retry',
      () => clients[0].post(
        '/secret/conversations/$conversationId/messages',
        outgoing,
      ),
    );
    check(
      'idempotent-message-id-sequence',
      sent['id'] == retry['id'] && sent['sequence'] == retry['sequence'],
    );
    for (var index = 0; index < 2; index++) {
      final response = await step(
        'read-text-own-envelope-$index',
        () => clients[index].get(
          '/secret/conversations/$conversationId/messages?deviceId=${localIds[index]}&limit=50',
        ),
      );
      final row = _rows(response)
          .singleWhere((row) => row['clientMessageId'] == messageId);
      final envelope = Map<String, dynamic>.from(row['envelope'] as Map),
          cipher = secretBase64(envelope['ciphertextBase64']);
      check(
        'server-metadata-key-context-$index',
        row['conversationId'] == conversationId &&
            row['senderUserId'] == bundles[0].userId &&
            row['senderDeviceId'] == localIds[0] &&
            row['senderKeyVersion'] == bundles[0].version &&
            row['senderSigningPublicKey'] ==
                base64Encode(bundles[0].signingKey) &&
            envelope['recipientDeviceId'] == localIds[index] &&
            envelope['recipientKeyVersion'] == bundles[index].version,
      );
      final opened = crypto.open(
        identities[index],
        cipher,
        bundles[0].signingKey,
      );
      check(
        'both-recipients-decrypt-signed-text-$index',
        opened.text == marker &&
            opened.conversationId == conversationId &&
            opened.clientMessageId == messageId,
      );
      var rejected = false;
      try {
        crypto.open(identities[1 - index], cipher, bundles[0].signingKey);
      } catch (_) {
        rejected = true;
      }
      check('other-device-cannot-open-envelope-$index', rejected);
      rejected = false;
      final tampered = Uint8List.fromList(cipher)..[cipher.length - 1] ^= 1;
      try {
        crypto.open(identities[index], tampered, bundles[0].signingKey);
      } catch (_) {
        rejected = true;
      }
      check('sealed-packet-tamper-rejected-$index', rejected);
      rejected = false;
      try {
        crypto.open(identities[index], cipher, bundles[1].signingKey);
      } catch (_) {
        rejected = true;
      }
      check('pinned-signature-key-substitution-rejected-$index', rejected);
    }
    var wrongDeviceDenied = false;
    try {
      await step(
        'cross-account-device-query',
        () => clients[1].get(
          '/secret/conversations/$conversationId/messages?deviceId=${localIds[0]}',
        ),
      );
    } on ApiException catch (error) {
      wrongDeviceDenied = error.status == 404 || error.status == 403;
    }
    check('server-denies-cross-account-device-query', wrongDeviceDenied);
    final encrypted = crypto.encryptImage(jpeg);
    jpeg.fillRange(0, jpeg.length, 0);
    final folder = await Directory.systemTemp.createTemp(
      'fv-host-secret-cipher-',
    );
    late Json attachment;
    try {
      final cipherFile = await File('${folder.path}/cipher.bin')
          .writeAsBytes(encrypted.ciphertext);
      try {
        attachment = await step(
          'upload-opaque-image-cipher',
          () => clients[0].uploadSecretCipher(
            conversationId: conversationId!,
            senderDeviceId: localIds[0],
            recipientDeviceId: localIds[1],
            ciphertext: cipherFile,
          ),
        );
      } finally {
        await cipherFile.delete();
      }
    } finally {
      await folder.delete();
    }
    check(
      'cipher-attachment-server-digest-length',
      secretUuid(attachment['id']) &&
          attachment['sha256'] == digestHex(encrypted.ciphertext) &&
          attachment['sizeBytes'] == encrypted.ciphertext.length,
    );
    final imageMetadata = encrypted.metadata(attachment['id'] as String),
        imageMessageId = crypto.newId();
    final imagePacket = SecretPacket(
      conversationId: conversationId,
      senderUserId: bundles[0].userId,
      senderDeviceId: localIds[0],
      clientMessageId: imageMessageId,
      text: '',
      image: imageMetadata,
    );
    await step(
      'send-sealed-image-key-metadata',
      () => clients[0].post('/secret/conversations/$conversationId/messages', {
        'clientMessageId': imageMessageId,
        'senderDeviceId': localIds[0],
        'envelopes': [
          for (final bundle in bundles)
            {
              'recipientDeviceId': bundle.deviceId,
              'ciphertextBase64': base64Encode(
                crypto.seal(identities[0], imagePacket, bundle.encryptionKey),
              ),
            },
        ],
      }),
    );
    for (var index = 0; index < 2; index++) {
      final imagePage = await step(
        'read-sealed-image-message-$index',
        () => clients[index].get(
          '/secret/conversations/$conversationId/messages?deviceId=${localIds[index]}&limit=50',
        ),
      );
      final row = _rows(imagePage)
          .singleWhere((row) => row['clientMessageId'] == imageMessageId);
      final envelope = Map<String, dynamic>.from(row['envelope'] as Map);
      check(
        'image-message-pinned-metadata-$index',
        row['conversationId'] == conversationId &&
            row['senderUserId'] == bundles[0].userId &&
            row['senderDeviceId'] == localIds[0] &&
            row['senderKeyVersion'] == bundles[0].version &&
            row['senderSigningPublicKey'] ==
                base64Encode(bundles[0].signingKey) &&
            envelope['recipientDeviceId'] == localIds[index] &&
            envelope['recipientKeyVersion'] == bundles[index].version,
      );
      final opened = crypto.open(
        identities[index],
        secretBase64(envelope['ciphertextBase64']),
        bundles[0].signingKey,
      );
      check(
        'image-key-traverses-signed-sealed-envelope-$index',
        opened.conversationId == conversationId &&
            opened.senderUserId == bundles[0].userId &&
            opened.senderDeviceId == localIds[0] &&
            opened.clientMessageId == imageMessageId &&
            opened.text.isEmpty &&
            opened.image != null &&
            jsonEncode(opened.image!.canonical) ==
                jsonEncode(imageMetadata.canonical),
      );
      final receivedImage = opened.image!;
      final downloaded = await step(
        'download-private-cipher-$index',
        () => clients[index].secretCipherBytes(
          conversationId!,
          attachment['id'] as String,
          localIds[index],
        ),
      );
      final decoded = crypto.decryptImage(downloaded, receivedImage);
      check(
        'cipher-image-roundtrip-$index',
        decoded.length == receivedImage.plainBytes &&
            digestHex(decoded) == originalImageDigest &&
            secretJpegSize(decoded) ==
                (receivedImage.width, receivedImage.height),
      );
      decoded.fillRange(0, decoded.length, 0);
      var rejected = false;
      final changed = Uint8List.fromList(downloaded)..[0] ^= 1;
      try {
        crypto.decryptImage(changed, imageMetadata);
      } catch (_) {
        rejected = true;
      }
      check('image-cipher-tamper-rejected-$index', rejected);
      final changedDigest = SecretImageMetadata.fromArray(
        [...receivedImage.canonical]..[1] = digestHex(changed),
      );
      rejected = false;
      try {
        crypto.decryptImage(changed, changedDigest);
      } catch (_) {
        rejected = true;
      }
      check(
        'secretbox-mac-tamper-rejected-after-digest-match-$index',
        rejected,
      );
    }
    check(
      'observed-server-json-excludes-plaintext-and-image-key',
      transports
          .expand((transport) => transport.observedJson)
          .every(
            (json) =>
                !json.contains(marker) && !json.contains(imageMetadata.key),
          ),
    );
    success = true;
  } catch (error) {
    checks.add({
      'check': error is _Failure ? error.check : phase,
      'pass': false,
      if (error is ApiException) 'httpStatus': error.status,
      'errorType': error.runtimeType.toString(),
    });
  } finally {
    for (final (client, deviceId) in registered.reversed) {
      try {
        await client
            .delete('/secret/devices/$deviceId')
            .timeout(const Duration(seconds: 20));
        checks.add({
          'check': 'revoke-owned-host-device',
          'deviceId': deviceId,
          'pass': true,
        });
      } catch (_) {
        success = false;
        checks.add({
          'check': 'revoke-owned-host-device',
          'deviceId': deviceId,
          'pass': false,
        });
      }
    }
    for (final identity in identities) {
      identity.dispose();
    }
    for (final client in clients) {
      client.close();
    }
    final report = {
      'schemaVersion': 1,
      'scope': 'authorized-host-api-real-sodium',
      'androidKeystoreTested': false,
      'humanOutOfBandComparisonTested': false,
      'startedAt': started.toIso8601String(),
      'completedAt': DateTime.now().toUtc().toIso8601String(),
      'baseUrl': origin,
      'secretConversationId': conversationId,
      'pass': success,
      'observations': checks,
    };
    await File(reportPath).parent.create(recursive: true);
    await File(reportPath)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(
      'Host secret API acceptance: ${success ? 'PASS' : 'FAIL'}; ${checks.length} observations. Report: $reportPath',
    );
    exitCode = success ? 0 : 1;
  }
}
