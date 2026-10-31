// DORMANT. Root must grant the host Dart/API run separately.
// One existing Producer APK + one host Trader peer; never two-phone/OOB proof.
// No private key is exported or persisted. Producer is strictly READ ONLY.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/secret_protocol.dart';

typedef Json = Map<String, dynamic>;

class _Failure implements Exception {
  const _Failure(this.step);
  final String step;
}

class _PeerTransport implements ApiTransport {
  _PeerTransport(this.readOnly);
  final bool readOnly;
  final _inner = IoApiTransport();
  final observedJson = <String>[];
  var requests = 0;
  @override
  Future<ApiReply> send(String method, Uri uri, Map<String, String> headers,
      String? body) async {
    if (++requests > 200 || !uri.path.startsWith('/api/v1/') ||
        uri.path == '/api/v1/auth/refresh' || (readOnly && method != 'GET')) {
      throw const _Failure('transport-budget-readonly-or-fresh-login-required');
    }
    if (body != null) observedJson.add(body);
    final reply = await _inner.send(method, uri, headers, body);
    if (reply.body.length > 1024 * 1024) {
      throw const _Failure('response-size-bound');
    }
    // Bounded transcript stays in RAM solely to check plaintext/key absence.
    if (observedJson.fold<int>(0, (sum, value) => sum + value.length) <
        2 * 1024 * 1024) {
      observedJson.add(reply.body);
    }
    return reply;
  }
  @override
  void close() => _inner.close();
}

List<Json> _rows(Json data) => (data['items'] as List)
    .map((row) => Map<String, dynamic>.from(row as Map)).toList();

Future<File> _newOutput(String path, Directory allowed) async {
  final file = File(path).absolute;
  final parent = await file.parent.resolveSymbolicLinks();
  final root = await allowed.resolveSymbolicLinks();
  final prefix = root.toLowerCase() + Platform.pathSeparator;
  if ((parent.toLowerCase() != root.toLowerCase() &&
          !parent.toLowerCase().startsWith(prefix)) ||
      !file.path.endsWith('.json') || await file.exists()) {
    throw const _Failure('choose-new-output-inside-required-directory');
  }
  return File('$parent${Platform.pathSeparator}${file.uri.pathSegments.last}');
}

Future<void> main(List<String> args) async {
  String? option(String key) {
    final index = args.indexOf(key);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }
  if (!args.contains('--run') || args.contains('--help')) {
    stdout.writeln('Dormant Trader-only peer: --run --sessions PRIVATE.json '
        '--control NEW_PRIVATE.json --release NEW_PRIVATE.json '
        '--report NEW_PUBLIC.json [--wait-seconds 480] '
        '[--expected-producer-version 3]. Root grant required.');
    return;
  }
  final sessionPath = option('--sessions'), controlPath = option('--control'),
      releasePath = option('--release'), reportPath = option('--report');
  final waitSeconds = int.tryParse(option('--wait-seconds') ?? '480');
  final expectedProducerVersion =
      int.tryParse(option('--expected-producer-version') ?? '3');
  if (sessionPath == null || controlPath == null || releasePath == null ||
      reportPath == null || waitSeconds == null ||
      waitSeconds < 60 || waitSeconds > 480 ||
      expectedProducerVersion == null || expectedProducerVersion < 1 ||
      expectedProducerVersion > 32767) {
    stderr.writeln('Required paths, wait-seconds60..480 and '
        'expected-producer-version1..32767. No tokens on CLI.');
    exitCode = 64;
    return;
  }

  final repo = File.fromUri(Platform.script).parent.parent.parent;
  final privateRoot = Directory('${repo.path}/server/.local');
  final publicRoot = Directory('${repo.path}/server/docs');
  final checks = <Json>[];
  final transports = <_PeerTransport>[];
  final clients = <ApiClient>[];
  final started = DateTime.now().toUtc();
  final hardDeadline = started.add(const Duration(minutes: 10));
  SecretIdentity? identity;
  ApiClient? trader;
  File? control, release, report, cipherFile;
  String? traderDeviceId, secretId, directId;
  String? expectedProducerUserId;
  var deviceMayExist = false, revoked = false, success = false;
  var phase = 'preflight', replyVerified = false, released = false;
  final state = <String, dynamic>{};

  void check(String name, bool value) {
    checks.add({'check': name, 'pass': value});
    if (!value) throw _Failure(name);
  }
  Future<T> step<T>(String name, Future<T> Function() action) async {
    phase = name;
    final remaining = hardDeadline.difference(DateTime.now().toUtc()).inMilliseconds - 30000;
    if (remaining <= 0) {
      throw const _Failure('ten-minute-hard-budget');
    }
    return action().timeout(Duration(milliseconds: remaining.clamp(1, 25000).toInt()));
  }
  Future<void> checkpoint(String stage) async {
    state['stage'] = stage;
    state['updatedUtc'] = DateTime.now().toUtc().toIso8601String();
    final temp = File('${control!.path}.tmp');
    await temp.writeAsString(jsonEncode(state), flush: true);
    await temp.rename(control!.path);
    stdout.writeln('Trader peer stage: $stage');
  }

  try {
    control = await _newOutput(controlPath, privateRoot);
    release = await _newOutput(releasePath, privateRoot);
    report = await _newOutput(reportPath, publicRoot);
    check('distinct-control-release-and-report',
        control.path != release.path && control.path != report.path);
    final sessionFile = File(sessionPath).absolute;
    final canonicalSessions = await sessionFile.resolveSymbolicLinks();
    final canonicalPrivate = await privateRoot.resolveSymbolicLinks();
    check('private-bounded-session-input', canonicalSessions.toLowerCase()
        .startsWith(canonicalPrivate.toLowerCase() + Platform.pathSeparator) &&
        await sessionFile.length() <= 65536);
    final input = jsonDecode(await sessionFile.readAsString()) as Json;
    final base = ApiClient.validateBaseUrl(input['baseURL'] as String);
    final tunnel = jsonDecode(await File('${privateRoot.path}/tunnel-state.json')
        .readAsString()) as Json;
    check('owned-current-https-origin', base == tunnel['publicUrl']);
    final supplied = input['sessions'] as Json;
    expectedProducerUserId = ((supplied['Producer'] as Map)['user'] as Map)['id'] as String;
    check('source-document-pins-producer-public-user-id',
        secretUuid(expectedProducerUserId));
    final profiles = <String, Json>{};
    for (final role in ['Producer', 'Trader']) {
      final transport = _PeerTransport(role == 'Producer');
      transports.add(transport);
      final client = ApiClient(baseUrl: base, transport: transport);
      clients.add(client);
      final account = Map<String, dynamic>.from(supplied[role] as Map);
      client.setTokens(TokenPair(account['accessToken'] as String,
          account['refreshToken'] as String,
          DateTime.now().toUtc().add(const Duration(minutes: 15))));
      profiles[role] = await step('$role-read-own-profile',
          () => client.get('/auth/me'));
      final profile = profiles[role]!;
      check('$role-current-identity', profile['role'] == role &&
          profile['id'] == (account['user'] as Map)['id'] &&
          profile['isActive'] == true && profile['emailConfirmed'] == true &&
          profile['approvalStatus'] == 'Approved');
      if (role == 'Trader') trader = client;
    }
    check('two-distinct-existing-sellers',
        profiles['Producer']!['id'] != profiles['Trader']!['id']);
    final sessions = _rows(await step('trader-actual-current-session',
        () => trader!.get('/auth/sessions')));
    final current = sessions.singleWhere((row) => row['current'] == true);
    final created = DateTime.parse(current['createdAt'] as String).toUtc();
    final accessExpiry = DateTime.parse(current['accessExpiresAt'] as String).toUtc();
    final age = DateTime.now().toUtc().difference(created);
    check('trader-actual-created-session-not-refresh',
        !age.isNegative && age < const Duration(minutes: 15));
    final existingTokens = trader!.tokens!;
    trader.setTokens(TokenPair(existingTokens.accessToken,
        existingTokens.refreshToken, accessExpiry));
    var deadline = DateTime.now().toUtc().add(Duration(seconds: waitSeconds));
    final freshMargin = created.add(const Duration(minutes: 13));
    if (freshMargin.isBefore(deadline)) deadline = freshMargin;
    final hardMargin = hardDeadline.subtract(const Duration(minutes: 1));
    if (hardMargin.isBefore(deadline)) deadline = hardMargin;
    check('enough-fresh-time-for-apk-and-own-cleanup',
        deadline.difference(DateTime.now().toUtc()) >= const Duration(minutes: 2));

    final producerDevices = _rows(await step('producer-public-device-readonly',
        () => clients.first.get('/secret/devices')))
        .where((row) => row['revokedAt'] == null).toList();
    final traderDevices = _rows(await step('trader-no-active-device',
        () => trader!.get('/secret/devices')));
    check('preserve-exactly-one-producer-expected-version-device',
        producerDevices.length == 1 &&
        producerDevices.single['version'] == expectedProducerVersion);
    check('refuse-to-displace-any-active-trader-device',
        traderDevices.every((row) => row['revokedAt'] != null));
    final producerBundle = SecretBundle.fromJson(producerDevices.single);
    check('existing-producer-bundle-bound-to-source-user-id',
        producerBundle.userId == expectedProducerUserId &&
        producerBundle.userId == profiles['Producer']!['id']);
    final crypto = await SodiumSecretCryptography.load();
    identity = crypto.generateIdentity(); traderDeviceId = crypto.newId();
    final tag = crypto.newId().substring(0, 8);
    final hostMarker = 'QA26-HOST-$tag', apkMarker = 'QA26-APK-$tag',
        ackMarker = 'QA26-ACK-$tag';
    state.addAll({'schemaVersion': 1, 'scope': 'one-existing-Producer-APK-plus-host-Trader',
        'traderDeviceId': traderDeviceId, 'producerDeviceId': producerBundle.deviceId,
        'expectedProducerUserId': expectedProducerUserId,
        'expectedProducerVersion': expectedProducerVersion,
        'producerAccessReadOnly': true,
        'producerKeyVersion': producerBundle.version, 'hostTextMarker': hostMarker,
        'expectedApkReply': apkMarker, 'hostAckMarker': ackMarker,
        'releasePath': release.path, 'deadlineUtc': deadline.toIso8601String(),
        'privateKeysPersisted': false, 'instruction': 'Root opens existing Producer APK key bag; verify full fingerprint, decrypt host text/photo, send exact APK reply marker, then create release JSON {"release":true}. Never reset/revoke Producer keys.'});
    // Include the exact own ID before mutation, even if its response is lost.
    await checkpoint('REGISTERING_OWN_TRADER_DEVICE'); deviceMayExist = true;
    final traderBundle = SecretBundle.fromJson(await step('register-only-own-trader',
        () => trader!.post('/secret/devices', {'deviceId': traderDeviceId,
          'label': 'QA2.6 temporary host Trader',
          'encryptionPublicKey': base64Encode(identity!.encryptionPublicKey),
          'signingPublicKey': base64Encode(identity.signingPublicKey)})));
    check('registered-own-public-keys', traderBundle.deviceId == traderDeviceId &&
        traderBundle.userId == profiles['Trader']!['id'] &&
        sameBytes(traderBundle.encryptionKey, identity.encryptionPublicKey) &&
        sameBytes(traderBundle.signingKey, identity.signingPublicKey));
    final direct = await step('get-or-create-generic-two-seller-direct',
        () => trader!.post('/conversations/direct', {'userId': profiles['Producer']!['id']}));
    directId = direct['id'] as String;
    check('generic-direct-has-no-post-article-alias', secretUuid(directId) &&
        direct['kind'] == 'Direct' && direct['postId'] == null && direct['articleId'] == null);
    final room = await step('get-or-create-secret-room',
        () => trader!.post('/secret/conversations', {'directConversationId': directId}));
    secretId = room['id'] as String;
    final bundles = _rows(await step('pin-exact-two-public-bundles',
        () => trader!.get('/secret/conversations/$secretId/bundles')))
        .map(SecretBundle.fromJson).toList();
    check('pin-existing-producer-and-own-trader-only', bundles.length == 2 &&
        bundles.every((bundle) => [producerBundle, traderBundle].any((known) =>
          jsonEncode(bundle.canonical) == jsonEncode(known.canonical))));
    final fingerprint = safetyFingerprint(base, secretId, bundles);
    state.addAll({'directConversationId': directId, 'secretConversationId': secretId,
        'fullSafetyFingerprint': fingerprint});

    Future<Json> sendPacket(String text, {SecretImageMetadata? image}) async {
      final id = crypto.newId();
      final packet = SecretPacket(conversationId: secretId!,
          senderUserId: traderBundle.userId, senderDeviceId: traderDeviceId!,
          clientMessageId: id, text: text, image: image);
      return step('send-own-signed-sealed-packet', () => trader!.post(
          '/secret/conversations/$secretId/messages', {
            'clientMessageId': id, 'senderDeviceId': traderDeviceId,
            'envelopes': [for (final bundle in bundles) {
              'recipientDeviceId': bundle.deviceId,
              'ciphertextBase64': base64Encode(crypto.seal(identity!, packet, bundle.encryptionKey))}] }));
    }
    final textSent = await sendPacket(hostMarker);
    final imageFile = File('${repo.path}/app/android/app/src/main/assets/demo_mango.jpg');
    final jpeg = await imageFile.readAsBytes();
    check('pinned-existing-canonical-demo-jpeg',
        digestHex(jpeg) == '0104a1e5e313f5c4082607b4cac73b2497f9a916d130e500c96616e05684b9f5');
    secretJpegSize(jpeg);
    final encrypted = crypto.encryptImage(jpeg); jpeg.fillRange(0, jpeg.length, 0);
    cipherFile = File('${privateRoot.path}/secret-trader-$traderDeviceId.bin');
    check('new-own-cipher-path', !await cipherFile.exists());
    await cipherFile.writeAsBytes(encrypted.ciphertext, flush: true);
    final attachment = await step('upload-opaque-image-for-existing-producer',
        () => trader!.uploadSecretCipher(conversationId: secretId!,
          senderDeviceId: traderDeviceId!, recipientDeviceId: producerBundle.deviceId,
          ciphertext: cipherFile!));
    await cipherFile.delete(); cipherFile = null;
    check('server-cipher-digest-and-length', attachment['sha256'] ==
        digestHex(encrypted.ciphertext) && attachment['sizeBytes'] == encrypted.ciphertext.length);
    final imageMetadata = encrypted.metadata(attachment['id'] as String);
    final imageSent = await sendPacket('', image: imageMetadata);
    var sequence = imageSent['sequence'] as int;
    check('outbound-text-image-sequences-increase',
        sequence > (textSent['sequence'] as int));
    state.addAll({'hostTextSequence': textSent['sequence'],
        'hostImageSequence': sequence, 'hostImageAttachmentId': attachment['id']});
    await checkpoint('WAITING_FOR_APK_DECRYPT_AND_REPLY');

    while (DateTime.now().toUtc().isBefore(deadline)) {
      if (await release.exists()) {
        check('bounded-root-release-file', await release.length() <= 1024);
        final signal = jsonDecode(await release.readAsString()) as Json;
        check('release-only-after-verified-producer-reply',
            signal['release'] == true && replyVerified);
        released = true; break;
      }
      final page = await step('poll-only-current-trader-envelopes',
          () => trader!.get('/secret/conversations/$secretId/messages?deviceId=$traderDeviceId&afterSequence=$sequence&limit=50'));
      for (final row in _rows(page)) {
        final next = row['sequence'] as int;
        check('actual-positive-increasing-server-sequence', next > sequence);
        sequence = next;
        if (row['senderUserId'] != producerBundle.userId) continue;
        final envelope = Map<String, dynamic>.from(row['envelope'] as Map);
        check('producer-row-bound-to-pinned-device-key-and-trader-envelope',
            row['conversationId'] == secretId &&
            row['senderDeviceId'] == producerBundle.deviceId &&
            row['senderKeyVersion'] == producerBundle.version &&
            sameBytes(secretBase64(row['senderSigningPublicKey'], length: 32), producerBundle.signingKey) &&
            envelope['recipientDeviceId'] == traderDeviceId &&
            envelope['recipientKeyVersion'] == traderBundle.version);
        final opened = crypto.open(identity, secretBase64(envelope['ciphertextBase64']), producerBundle.signingKey);
        check('producer-signed-plaintext-matches-api-context',
            opened.conversationId == secretId && opened.senderUserId == producerBundle.userId &&
            opened.senderDeviceId == producerBundle.deviceId && opened.clientMessageId == row['clientMessageId']);
        if (opened.text == apkMarker && !replyVerified) {
          replyVerified = true; state['apkReplySequence'] = next;
          final ack = await sendPacket(ackMarker); state['hostAckSequence'] = ack['sequence'];
          await checkpoint('APK_REPLY_DECRYPTED_WAITING_ROOT_RELEASE');
        }
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    check('root-released-within-fresh-auth-budget', released && replyVerified);
    check('observed-server-json-excludes-host-plaintext-and-image-key',
        transports.expand((transport) => transport.observedJson).every((value) =>
            !value.contains(hostMarker) && !value.contains(imageMetadata.key)));
    success = true;
  } catch (error) {
    checks.add({'check': error is _Failure ? error.step : phase, 'pass': false,
        'errorType': error.runtimeType.toString(),
        if (error is ApiException) 'httpStatus': error.status});
  } finally {
    // Only this exact newly generated Trader ID can be revoked. Never Producer.
    if (deviceMayExist && trader != null && traderDeviceId != null) {
      try {
        await trader.delete('/secret/devices/$traderDeviceId')
            .timeout(const Duration(seconds: 25));
        revoked = true;
        checks.add({'check': 'revoke-only-own-generated-trader-device', 'pass': true});
      } catch (error) {
        success = false;
        checks.add({'check': 'revoke-only-own-generated-trader-device',
            'pass': false, 'errorType': error.runtimeType.toString(),
            if (error is ApiException) 'httpStatus': error.status});
      }
    }
    if (cipherFile != null && await cipherFile.exists()) await cipherFile.delete();
    identity?.dispose();
    if (control != null && await control.exists()) {
      state.addAll({'ownTraderRevoked': revoked, 'privateKeysPersisted': false});
      await checkpoint(success ? 'PASS_CLEANED_UP' : 'FAILED_INSPECT_RECEIPT');
    }
    for (final client in clients) { client.close(); }
    if (report != null) {
      final value = {'schemaVersion': 1, 'pass': success, 'scope': 'one-existing-Producer-APK-plus-host-Trader-Sodium-peer',
          'apkUiVerifiedByHarness': false, 'twoPhysicalPhonesTested': false,
          'humanOutOfBandComparisonTested': false, 'privateKeysPersisted': false,
          'startedUtc': started.toIso8601String(), 'completedUtc': DateTime.now().toUtc().toIso8601String(),
          'directConversationId': directId, 'secretConversationId': secretId,
          'ownTraderDeviceId': traderDeviceId, 'ownTraderRevoked': revoked,
          'expectedProducerUserId': expectedProducerUserId,
          'expectedProducerVersion': expectedProducerVersion,
          'producerAccessReadOnly': true,
          'producerReplyDecrypted': replyVerified, 'rootReleasedAfterUiReview': released,
          'jsonRequests': transports.fold<int>(0, (sum, transport) => sum + transport.requests),
          'observations': checks};
      await report.writeAsString(const JsonEncoder.withIndent('  ').convert(value), flush: true);
    }
    stdout.writeln('Trader-only host peer: ${success ? 'PASS' : 'FAIL'}; own Trader cleanup: $revoked. No Producer device changed.');
    exitCode = success ? 0 : 1;
  }
}
