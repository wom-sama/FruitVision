import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/secret_protocol.dart';

const ownUser = '11111111-1111-4111-8111-111111111111';
const peerUser = '22222222-2222-4222-8222-222222222222';
const ownDevice = '33333333-3333-4333-8333-333333333333';
const peerDevice = '44444444-4444-4444-8444-444444444444';
const roomId = '55555555-5555-4555-8555-555555555555';
const messageId = '66666666-6666-4666-8666-666666666666';
const attachmentId = '77777777-7777-4777-8777-777777777777';

// Header-only JPEG fixture exercises the bounded header parser, not a codec.
Uint8List jpegHeader({int width = 2, int height = 3}) => Uint8List.fromList([
  255,
  216,
  255,
  192,
  0,
  17,
  8,
  height >> 8,
  height & 255,
  width >> 8,
  width & 255,
  3,
  1,
  17,
  0,
  2,
  17,
  0,
  3,
  17,
  0,
  255,
  217,
]);
SecretPacket packet({String text = 'Bí mật về xoài 🥭'}) => SecretPacket(
  conversationId: roomId,
  senderUserId: ownUser,
  senderDeviceId: ownDevice,
  clientMessageId: messageId,
  text: text,
);
SecretBundle bundle(
  SecretIdentity identity, {
  bool peer = false,
  int version = 1,
}) => SecretBundle(
  userId: peer ? peerUser : ownUser,
  deviceId: peer ? peerDevice : ownDevice,
  version: version,
  encryptionKey: identity.encryptionPublicKey,
  signingKey: identity.signingPublicKey,
);

void main() {
  late SecretCryptography crypto;
  setUpAll(() async {
    crypto = await SodiumSecretCryptography.load();
  });
  late SecretIdentity own, peer, third;
  setUp(() {
    own = crypto.generateIdentity();
    peer = crypto.generateIdentity();
    third = crypto.generateIdentity();
  });
  tearDown(() {
    own.dispose();
    peer.dispose();
    third.dispose();
  });

  test('real sodium signed sealed packet opens for peer and own independent envelopes', () {
    final message = packet();
    final toPeer = crypto.seal(own, message, peer.encryptionPublicKey);
    final toSelf = crypto.seal(own, message, own.encryptionPublicKey);
    expect(toPeer, isNot(orderedEquals(toSelf)));
    expect(
      crypto.open(peer, toPeer, own.signingPublicKey).bytes,
      orderedEquals(message.bytes),
    );
    expect(crypto.open(own, toSelf, own.signingPublicKey).text, message.text);
    expect(
      utf8.decode(toPeer, allowMalformed: true),
      isNot(contains(message.text)),
    );
  });
  test(
    'wrong recipient, wrong pinned signer, and modified ciphertext fail closed',
    () {
      final cipher = crypto.seal(own, packet(), peer.encryptionPublicKey);
      expect(
        () => crypto.open(third, cipher, own.signingPublicKey),
        throwsA(anything),
      );
      expect(
        () => crypto.open(peer, cipher, third.signingPublicKey),
        throwsA(anything),
      );
      final changed = Uint8List.fromList(cipher)..[cipher.length - 1] ^= 1;
      expect(
        () => crypto.open(peer, changed, own.signingPublicKey),
        throwsA(anything),
      );
    },
  );
  test('keybag restore proves both private/public pairs and rejects altered public key', () {
    final exported = own.exportKeys();
    final restored = crypto.restoreIdentity(exported);
    addTearDown(restored.dispose);
    expect(
      restored.encryptionPublicKey,
      orderedEquals(own.encryptionPublicKey),
    );
    expect(restored.signingPublicKey, orderedEquals(own.signingPublicKey));
    final cipher = crypto.seal(restored, packet(), peer.encryptionPublicKey);
    expect(crypto.open(peer, cipher, own.signingPublicKey).text, packet().text);
    exported[0] ^= 1;
    expect(() => crypto.restoreIdentity(exported), throwsA(anything));
    exported.fillRange(0, exported.length, 0);
  });
  test('safety number is full SHA256, order independent and binds origin room and both keys', () {
    final a = bundle(own), b = bundle(peer, peer: true);
    final fingerprint = safetyFingerprint('https://example.test', roomId, [
      a,
      b,
    ]);
    expect(fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
      safetyFingerprint('https://example.test', roomId, [b, a]),
      fingerprint,
    );
    expect(
      safetyFingerprint('https://other.test', roomId, [a, b]),
      isNot(fingerprint),
    );
    expect(
      safetyFingerprint('https://example.test', messageId, [a, b]),
      isNot(fingerprint),
    );
    expect(
      safetyFingerprint('https://example.test', roomId, [
        a,
        bundle(third, peer: true),
      ]),
      isNot(fingerprint),
    );
    expect(
      safetyFingerprint('https://example.test', roomId, [
        a,
        bundle(peer, peer: true, version: 2),
      ]),
      isNot(fingerprint),
    );
  });
  test('packet canonical UTF8 format binds all context fields and rejects ambiguous encodings', () {
    final message = packet();
    expect(SecretPacket.fromBytes(message.bytes).clientMessageId, messageId);
    final decoded = jsonDecode(utf8.decode(message.bytes)) as List;
    final spaced = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent(' ').convert(decoded)),
    );
    expect(() => SecretPacket.fromBytes(spaced), throwsFormatException);
    decoded[0] = 2;
    expect(
      () => SecretPacket.fromBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(decoded))),
      ),
      throwsFormatException,
    );
    expect(
      () => SecretPacket.fromBytes(packet(text: '').bytes),
      throwsFormatException,
    );
    expect(
      () => SecretPacket.fromBytes(packet(text: 'x' * 2001).bytes),
      throwsFormatException,
    );
  });
  test(
    'base64 parsing rejects noncanonical, oversized and wrong length keys',
    () {
      expect(() => secretBase64('YQ', length: 1), throwsFormatException);
      expect(
        () => secretBase64(base64Encode([1, 2]), length: 1),
        throwsFormatException,
      );
      expect(
        () => secretBase64(base64Encode([1, 2, 3]), max: 2),
        throwsFormatException,
      );
    },
  );
  test('real sodium secretbox image binds ciphertext digest length and actual JPEG header', () {
    final plain = jpegHeader(),
        encrypted = crypto.encryptImage(plain),
        metadata = encrypted.metadata(attachmentId);
    expect(encrypted.ciphertext.length, plain.length + 16);
    expect(
      crypto.decryptImage(encrypted.ciphertext, metadata),
      orderedEquals(plain),
    );
    final changed = Uint8List.fromList(encrypted.ciphertext)..[0] ^= 1;
    expect(() => crypto.decryptImage(changed, metadata), throwsFormatException);
    final wrongDimension = SecretImageMetadata.fromArray(
      [...metadata.canonical]..[6] = 4,
    );
    expect(
      () => crypto.decryptImage(encrypted.ciphertext, wrongDimension),
      throwsFormatException,
    );
    final wrongKey = SecretImageMetadata.fromArray(
      [...metadata.canonical]..[5] = base64Encode(Uint8List(32)),
    );
    expect(
      () => crypto.decryptImage(encrypted.ciphertext, wrongKey),
      throwsA(anything),
    );
  });
  test('actual image header dimensions are bounded before any image codec', () {
    expect(secretJpegSize(jpegHeader()), (2, 3));
    expect(
      () => secretJpegSize(jpegHeader(width: 65535, height: 65535)),
      throwsFormatException,
    );
    expect(
      () => secretJpegSize(Uint8List.fromList([137, 80, 78, 71])),
      throwsFormatException,
    );
    expect(
      () => secretJpegSize(Uint8List(secretImageLimit + 1)),
      throwsFormatException,
    );
    expect(
      () => SecretImageMetadata.fromArray([
        attachmentId,
        '0' * 64,
        20,
        4,
        base64Encode(Uint8List(24)),
        base64Encode(Uint8List(32)),
        65535,
        65535,
        'image/jpeg',
      ]),
      throwsFormatException,
    );
  });
}
