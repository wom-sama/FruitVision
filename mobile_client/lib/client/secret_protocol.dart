import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:sodium/sodium.dart';

const secretEnvelopeLimit = 16384;
const secretImageLimit = 5 * 1024 * 1024;
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
bool secretUuid(Object? value) =>
    value is String && _uuidPattern.hasMatch(value);
String digestHex(List<int> value) => sha256.convert(value).toString();
Uint8List secretBase64(
  Object? value, {
  int? length,
  int max = secretEnvelopeLimit,
}) {
  if (value is! String || value.length > ((max + 2) ~/ 3) * 4) {
    throw const FormatException('Dữ liệu mã hóa vượt giới hạn.');
  }
  final bytes = base64Decode(value);
  if (bytes.length > max ||
      (length != null && bytes.length != length) ||
      base64Encode(bytes) != value) {
    throw const FormatException('Dữ liệu mã hóa không đúng định dạng.');
  }
  return bytes;
}

class SecretBundle {
  const SecretBundle({
    required this.userId,
    required this.deviceId,
    required this.version,
    required this.encryptionKey,
    required this.signingKey,
    this.label = '',
  });
  factory SecretBundle.fromJson(Map<String, dynamic> json) {
    if (!secretUuid(json['userId']) ||
        !secretUuid(json['deviceId']) ||
        json['version'] is! int ||
        (json['version'] as int) < 1 ||
        json['revokedAt'] != null) {
      throw const FormatException('Khóa thiết bị không còn hiệu lực.');
    }
    return SecretBundle(
      userId: json['userId'] as String,
      deviceId: json['deviceId'] as String,
      version: json['version'] as int,
      encryptionKey: secretBase64(json['encryptionPublicKey'], length: 32),
      signingKey: secretBase64(json['signingPublicKey'], length: 32),
      label: json['label'] as String? ?? '',
    );
  }
  final String userId, deviceId, label;
  final int version;
  final Uint8List encryptionKey, signingKey;
  List<Object> get canonical => [
    userId,
    deviceId,
    version,
    base64Encode(encryptionKey),
    base64Encode(signingKey),
  ];
}

String safetyFingerprint(
  String origin,
  String conversationId,
  List<SecretBundle> bundles,
) {
  if (!secretUuid(conversationId) ||
      bundles.length != 2 ||
      bundles[0].userId == bundles[1].userId) {
    throw const FormatException('Phòng bí mật cần đúng hai người.');
  }
  final ordered = [...bundles]..sort((a, b) => a.userId.compareTo(b.userId));
  return digestHex(
    utf8.encode(
      jsonEncode([
        'fruitvision-secret-safety-v1',
        origin,
        conversationId,
        ordered.map((bundle) => bundle.canonical).toList(),
      ]),
    ),
  );
}

class SecretImageMetadata {
  const SecretImageMetadata({
    required this.attachmentId,
    required this.cipherHash,
    required this.cipherBytes,
    required this.plainBytes,
    required this.nonce,
    required this.key,
    required this.width,
    required this.height,
  });
  factory SecretImageMetadata.fromArray(Object? input) {
    if (input is! List ||
        input.length != 9 ||
        !secretUuid(input[0]) ||
        input[1] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(input[1] as String) ||
        input[2] is! int ||
        input[3] is! int ||
        input[6] is! int ||
        input[7] is! int ||
        input[8] != 'image/jpeg') {
      throw const FormatException('Mô tả ảnh bí mật không hợp lệ.');
    }
    final cipherSize = input[2] as int,
        plainSize = input[3] as int,
        width = input[6] as int,
        height = input[7] as int;
    if (plainSize < 3 ||
        plainSize > secretImageLimit ||
        cipherSize != plainSize + 16 ||
        width < 1 ||
        height < 1 ||
        width > 2048 ||
        height > 2048) {
      throw const FormatException('Ảnh bí mật vượt giới hạn.');
    }
    secretBase64(input[4], length: 24);
    secretBase64(input[5], length: 32);
    return SecretImageMetadata(
      attachmentId: input[0] as String,
      cipherHash: input[1] as String,
      cipherBytes: cipherSize,
      plainBytes: plainSize,
      nonce: input[4] as String,
      key: input[5] as String,
      width: width,
      height: height,
    );
  }
  final String attachmentId, cipherHash, nonce, key;
  final int cipherBytes, plainBytes, width, height;
  List<Object> get canonical => [
    attachmentId,
    cipherHash,
    cipherBytes,
    plainBytes,
    nonce,
    key,
    width,
    height,
    'image/jpeg',
  ];
}

class SecretPacket {
  const SecretPacket({
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.clientMessageId,
    required this.text,
    this.image,
  });
  factory SecretPacket.fromBytes(Uint8List bytes) {
    if (bytes.length > 10240) {
      throw const FormatException('Tin bí mật vượt giới hạn.');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! List ||
        data.length != 7 ||
        data[0] != 1 ||
        !secretUuid(data[1]) ||
        !secretUuid(data[2]) ||
        !secretUuid(data[3]) ||
        !secretUuid(data[4]) ||
        data[5] is! String) {
      throw const FormatException('Nội dung tin bí mật không hợp lệ.');
    }
    final packet = SecretPacket(
      conversationId: data[1] as String,
      senderUserId: data[2] as String,
      senderDeviceId: data[3] as String,
      clientMessageId: data[4] as String,
      text: data[5] as String,
      image: data[6] == null ? null : SecretImageMetadata.fromArray(data[6]),
    );
    if (packet.text.length > 2000 ||
        (packet.text.trim().isEmpty && packet.image == null) ||
        !sameBytes(bytes, packet.bytes)) {
      throw const FormatException('Tin bí mật không đúng định dạng chuẩn.');
    }
    return packet;
  }
  final String conversationId,
      senderUserId,
      senderDeviceId,
      clientMessageId,
      text;
  final SecretImageMetadata? image;
  Uint8List get bytes => Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        1,
        conversationId,
        senderUserId,
        senderDeviceId,
        clientMessageId,
        text,
        image?.canonical,
      ]),
    ),
  );
}

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

abstract interface class SecretIdentity {
  Uint8List get encryptionPublicKey;
  Uint8List get signingPublicKey;
  Uint8List exportKeys();
  void dispose();
}

class EncryptedSecretImage {
  const EncryptedSecretImage(
    this.ciphertext,
    this.key,
    this.nonce,
    this.plainBytes,
    this.width,
    this.height,
  );
  final Uint8List ciphertext;
  final String key, nonce;
  final int plainBytes, width, height;
  SecretImageMetadata metadata(String attachmentId) => SecretImageMetadata(
    attachmentId: attachmentId,
    cipherHash: digestHex(ciphertext),
    cipherBytes: ciphertext.length,
    plainBytes: plainBytes,
    nonce: nonce,
    key: key,
    width: width,
    height: height,
  );
}

abstract interface class SecretCryptography {
  SecretIdentity generateIdentity();
  SecretIdentity restoreIdentity(Uint8List keys);
  String newId();
  Uint8List seal(
    SecretIdentity identity,
    SecretPacket packet,
    Uint8List recipientKey,
  );
  SecretPacket open(
    SecretIdentity identity,
    Uint8List ciphertext,
    Uint8List senderSigningKey,
  );
  EncryptedSecretImage encryptImage(Uint8List jpeg);
  Uint8List decryptImage(Uint8List cipher, SecretImageMetadata metadata);
}

class SodiumSecretCryptography implements SecretCryptography {
  SodiumSecretCryptography(this.sodium);
  static Future<SecretCryptography> load() async =>
      SodiumSecretCryptography(await SodiumInit.init());
  final Sodium sodium;
  @override
  SecretIdentity generateIdentity() => _SodiumIdentity(
    sodium.crypto.box.keyPair(),
    sodium.crypto.sign.keyPair(),
  );
  @override
  SecretIdentity restoreIdentity(Uint8List keys) {
    if (keys.length != 160) {
      throw const FormatException('Kho khóa không hợp lệ.');
    }
    final identity = _SodiumIdentity(
      KeyPair(
        publicKey: Uint8List.fromList(keys.sublist(0, 32)),
        secretKey: sodium.secureCopy(Uint8List.sublistView(keys, 32, 64)),
      ),
      KeyPair(
        publicKey: Uint8List.fromList(keys.sublist(64, 96)),
        secretKey: sodium.secureCopy(Uint8List.sublistView(keys, 96, 160)),
      ),
    );
    try {
      final challenge = sodium.randombytes.buf(32);
      final sealed = sodium.crypto.box.seal(
        message: challenge,
        publicKey: identity.encryptionPublicKey,
      );
      final opened = sodium.crypto.box.sealOpen(
        cipherText: sealed,
        publicKey: identity.encryptionPublicKey,
        secretKey: identity.box.secretKey,
      );
      final signature = sodium.crypto.sign.detached(
        message: challenge,
        secretKey: identity.sign.secretKey,
      );
      if (!sameBytes(challenge, opened) ||
          !sodium.crypto.sign.verifyDetached(
            message: challenge,
            signature: signature,
            publicKey: identity.signingPublicKey,
          )) {
        throw const FormatException('Khóa riêng không khớp khóa công khai.');
      }
      return identity;
    } catch (_) {
      identity.dispose();
      rethrow;
    }
  }

  @override
  String newId() {
    final bytes = sodium.randombytes.buf(16);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  Uint8List seal(
    SecretIdentity identity,
    SecretPacket packet,
    Uint8List recipientKey,
  ) {
    final own = identity as _SodiumIdentity, bytes = packet.bytes;
    SecretPacket.fromBytes(bytes);
    final signature = sodium.crypto.sign.detached(
      message: bytes,
      secretKey: own.sign.secretKey,
    );
    final signed = Uint8List.fromList(
      utf8.encode(
        jsonEncode([1, base64Encode(bytes), base64Encode(signature)]),
      ),
    );
    if (signed.length + sodium.crypto.box.sealBytes > secretEnvelopeLimit) {
      throw const FormatException('Tin bí mật quá dài.');
    }
    return sodium.crypto.box.seal(message: signed, publicKey: recipientKey);
  }

  @override
  SecretPacket open(
    SecretIdentity identity,
    Uint8List ciphertext,
    Uint8List senderSigningKey,
  ) {
    if (ciphertext.length > secretEnvelopeLimit) {
      throw const FormatException('Bản mã vượt giới hạn.');
    }
    final own = identity as _SodiumIdentity;
    final signed = sodium.crypto.box.sealOpen(
      cipherText: ciphertext,
      publicKey: own.encryptionPublicKey,
      secretKey: own.box.secretKey,
    );
    final wrapper = jsonDecode(utf8.decode(signed));
    if (wrapper is! List || wrapper.length != 3 || wrapper[0] != 1) {
      throw const FormatException('Chữ ký tin bí mật không hợp lệ.');
    }
    final bytes = secretBase64(wrapper[1], max: 10240),
        signature = secretBase64(wrapper[2], length: 64);
    if (!sodium.crypto.sign.verifyDetached(
      message: bytes,
      signature: signature,
      publicKey: senderSigningKey,
    )) {
      throw const FormatException('Không xác minh được người gửi.');
    }
    return SecretPacket.fromBytes(bytes);
  }

  @override
  EncryptedSecretImage encryptImage(Uint8List jpeg) {
    final dimensions = secretJpegSize(jpeg),
        key = sodium.crypto.secretBox.keygen();
    try {
      final nonce = sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
      final ciphertext = sodium.crypto.secretBox.easy(
        message: jpeg,
        nonce: nonce,
        key: key,
      );
      final exported = key.extractBytes();
      try {
        return EncryptedSecretImage(
          ciphertext,
          base64Encode(exported),
          base64Encode(nonce),
          jpeg.length,
          dimensions.$1,
          dimensions.$2,
        );
      } finally {
        exported.fillRange(0, exported.length, 0);
      }
    } finally {
      key.dispose();
    }
  }

  @override
  Uint8List decryptImage(Uint8List cipher, SecretImageMetadata metadata) {
    if (cipher.length != metadata.cipherBytes ||
        digestHex(cipher) != metadata.cipherHash) {
      throw const FormatException('Ảnh mã hóa đã thay đổi.');
    }
    final exported = secretBase64(metadata.key, length: 32),
        key = sodium.secureCopy(exported);
    exported.fillRange(0, exported.length, 0);
    try {
      final plain = sodium.crypto.secretBox.openEasy(
        cipherText: cipher,
        nonce: secretBase64(metadata.nonce, length: 24),
        key: key,
      );
      try {
        final dimensions = secretJpegSize(plain);
        if (plain.length != metadata.plainBytes ||
            dimensions.$1 != metadata.width ||
            dimensions.$2 != metadata.height) {
          throw const FormatException('Mô tả ảnh không khớp nội dung.');
        }
        return plain;
      } catch (_) {
        plain.fillRange(0, plain.length, 0);
        rethrow;
      }
    } finally {
      key.dispose();
    }
  }
}

class _SodiumIdentity implements SecretIdentity {
  _SodiumIdentity(this.box, this.sign);
  final KeyPair box, sign;
  @override
  Uint8List get encryptionPublicKey => box.publicKey;
  @override
  Uint8List get signingPublicKey => sign.publicKey;
  @override
  Uint8List exportKeys() {
    final x = box.secretKey.extractBytes(), ed = sign.secretKey.extractBytes();
    try {
      return Uint8List(160)
        ..setRange(0, 32, box.publicKey)
        ..setRange(32, 64, x)
        ..setRange(64, 96, sign.publicKey)
        ..setRange(96, 160, ed);
    } finally {
      x.fillRange(0, x.length, 0);
      ed.fillRange(0, ed.length, 0);
    }
  }

  @override
  void dispose() {
    box.dispose();
    sign.dispose();
  }
}

(int, int) secretJpegSize(Uint8List bytes) {
  if (bytes.length < 4 ||
      bytes.length > secretImageLimit ||
      bytes[0] != 255 ||
      bytes[1] != 216) {
    throw const FormatException('Ảnh bí mật cần là JPEG chuẩn, tối đa 5 MiB.');
  }
  var offset = 2, segments = 0;
  while (offset + 3 < bytes.length && ++segments <= 1000) {
    if (bytes[offset++] != 255) break;
    while (offset < bytes.length && bytes[offset] == 255) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 217 || marker == 218) break;
    if (marker == 1 || (marker >= 208 && marker <= 216)) continue;
    if (offset + 1 >= bytes.length) break;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) break;
    if (marker >= 192 && marker <= 207 && !{196, 200, 204}.contains(marker)) {
      if (length < 8) break;
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4],
          width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      if (width < 1 || height < 1 || width > 2048 || height > 2048) {
        throw const FormatException('Ảnh bí mật tối đa 2048 × 2048 điểm ảnh.');
      }
      return (width, height);
    }
    offset += length;
  }
  throw const FormatException('Không đọc được kích thước JPEG.');
}
