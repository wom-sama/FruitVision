import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'media.dart';
import 'secret_protocol.dart';
import 'session.dart';

typedef SecretJson = Map<String, dynamic>;

class SecretKeyStore {
  SecretKeyStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vn.fruitvision/secret_keys');
  final MethodChannel _channel;
  Future<String?> read(String origin, String userId) => _channel
      .invokeMethod<String>('read', {'origin': origin, 'userId': userId});
  Future<void> write(String origin, String userId, String value) =>
      _channel.invokeMethod<void>('write', {
        'origin': origin,
        'userId': userId,
        'value': value,
      });
  Future<void> delete(String origin, String userId) => _channel
      .invokeMethod<void>('delete', {'origin': origin, 'userId': userId});
}

class SecretRoom {
  const SecretRoom({
    required this.id,
    required this.bundles,
    required this.fingerprint,
    required this.verified,
    required this.changed,
  });
  final String id, fingerprint;
  final List<SecretBundle> bundles;
  final bool verified, changed;
}

class SecretMessage {
  const SecretMessage(this.metadata, this.packet, this.error);
  final SecretJson metadata;
  final SecretPacket? packet;
  final String? error;
}

class SecretMessagePage {
  const SecretMessagePage(this.room, this.messages, this.nextBefore);
  final SecretRoom room;
  final List<SecretMessage> messages;
  final int? nextBefore;
}

class PreparedSecretMessage {
  const PreparedSecretMessage(this.roomId, this.fingerprint, this.body);
  final String roomId, fingerprint;
  final SecretJson body;
  String get clientMessageId => body['clientMessageId'] as String;
}

class SecretMessaging extends ChangeNotifier {
  SecretMessaging({
    required this.session,
    SecretKeyStore? store,
    Future<SecretCryptography> Function()? cryptoLoader,
  }) : store = store ?? SecretKeyStore(),
       _cryptoLoader = cryptoLoader ?? SodiumSecretCryptography.load {
    session.addListener(_syncSession);
    _syncSession();
  }
  final SessionController session;
  final SecretKeyStore store;
  final Future<SecretCryptography> Function() _cryptoLoader;
  Future<SecretCryptography>? _cryptoTask;
  Future<SecretIdentity>? _identityTask;
  SecretIdentity? _identity;
  SecretJson? _bag;
  String? _scope;
  bool _disposed = false;
  int _generation = 0;
  final _uploads = <UploadCancellation>{};
  ApiClient get api => session.api;
  String get origin => api.baseUrl;
  String get userId => session.user?.id ?? '';
  String? get deviceId => _bag?['deviceId'] as String?;

  void _syncSession() {
    final next = session.user?.canSell == true && !session.endingSession
        ? '${api.baseUrl}:${session.user!.id}'
        : null;
    if (next == _scope) return;
    _scope = next;
    lockMemory();
  }

  void lockMemory() {
    _generation++;
    _identity?.dispose();
    _identity = null;
    _bag = null;
    _identityTask = null;
    for (final upload in _uploads) {
      upload.cancel();
    }
    if (!_disposed) notifyListeners();
  }

  void _guard(int generation) {
    if (_disposed || generation != _generation || _scope == null) {
      throw const ApiException(
        'Phiên hoặc khóa bí mật đã thay đổi. Hãy mở lại phòng.',
        status: 401,
      );
    }
  }

  Future<SecretCryptography> _crypto() async {
    final task = _cryptoTask ??= _cryptoLoader();
    try {
      return await task;
    } catch (_) {
      if (identical(task, _cryptoTask)) _cryptoTask = null;
      throw const ApiException(
        'Chưa tải được thư viện mã hóa. Phòng bí mật đang khóa.',
      );
    }
  }

  List<SecretJson> _rows(SecretJson value) => (value['items'] as List? ?? [])
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  Future<List<SecretJson>> devices() async {
    final generation = _generation;
    _guard(generation);
    final result = await api.get('/secret/devices');
    _guard(generation);
    return _rows(result);
  }

  Future<SecretIdentity> _ensureIdentity() {
    if (_identityTask != null) return _identityTask!;
    final task = _readIdentity();
    _identityTask = task;
    return task.whenComplete(() {
      if (identical(_identityTask, task)) _identityTask = null;
    });
  }

  Future<SecretIdentity> _readIdentity() async {
    final generation = _generation;
    _guard(generation);
    if (_identity == null) {
      final value = await store.read(origin, userId);
      _guard(generation);
      if (value == null) {
        throw const ApiException(
          'Thiết bị chưa có khóa bí mật. Đăng ký khóa trong Bảo mật tài khoản.',
        );
      }
      if (utf8.encode(value).length > 16384) {
        throw const ApiException('Kho khóa không đúng định dạng.');
      }
      final parsed = jsonDecode(value);
      if (parsed is! Map<String, dynamic> ||
          parsed['schemaVersion'] != 1 ||
          !secretUuid(parsed['deviceId']) ||
          parsed['pins'] is! Map) {
        throw const ApiException('Không đọc được kho khóa bí mật.');
      }
      final keys = secretBase64(parsed['keys'], length: 160, max: 160);
      late SecretIdentity loaded;
      try {
        final crypto = await _crypto();
        _guard(generation);
        loaded = crypto.restoreIdentity(keys);
      } finally {
        keys.fillRange(0, keys.length, 0);
      }
      if (generation != _generation || _disposed) {
        loaded.dispose();
        _guard(generation);
      }
      _bag = Map<String, dynamic>.from(parsed);
      _identity = loaded;
    }
    final active = (await devices())
        .where((device) => device['revokedAt'] == null)
        .toList();
    _guard(generation);
    if (active.length != 1) {
      throw const ApiException(
        'Khóa thiết bị đã bị thu hồi hoặc chưa đăng ký. Không thể mở phòng bí mật.',
      );
    }
    final own = SecretBundle.fromJson(active.single);
    _checkOwnBundle(own, _identity!);
    return _identity!;
  }

  void _checkOwnBundle(SecretBundle bundle, SecretIdentity identity) {
    if (bundle.userId != userId ||
        bundle.deviceId != deviceId ||
        !sameBytes(bundle.encryptionKey, identity.encryptionPublicKey) ||
        !sameBytes(bundle.signingKey, identity.signingPublicKey)) {
      throw const ApiException(
        'Khóa công khai trên máy chủ không khớp khóa của thiết bị. Phòng đang khóa.',
      );
    }
  }

  Future<void> _saveBag(SecretJson bag, int generation) async {
    _guard(generation);
    final value = jsonEncode(bag);
    if (utf8.encode(value).length > 16384) {
      throw const ApiException(
        'Kho xác minh thiết bị đã đầy. Không lưu được xác minh mới.',
      );
    }
    await store.write(origin, userId, value);
    _guard(generation);
    _bag = bag;
  }

  Future<void> registerDevice({
    required String label,
    required bool allowNewIdentity,
  }) async {
    final generation = _generation;
    _guard(generation);
    if (!session.canEnrollBiometric) {
      throw const ApiException(
        'Đăng nhập lại bằng mật khẩu và mã xác thực trong 15 phút để đăng ký khóa bí mật.',
      );
    }
    final current = await devices();
    _guard(generation);
    final value = await store.read(origin, userId);
    _guard(generation);
    final active = current
        .where((device) => device['revokedAt'] == null)
        .toList();
    final saved = value == null ? null : jsonDecode(value);
    final savedId = saved is Map ? saved['deviceId'] : null;
    if (active.isNotEmpty &&
        (active.length != 1 || active.single['deviceId'] != savedId)) {
      throw const ApiException(
        'Tài khoản đã có khóa trên thiết bị khác. Cần chủ động thu hồi trước khi tạo khóa mới.',
      );
    }
    final revoked = current.any(
      (device) => device['deviceId'] == savedId && device['revokedAt'] != null,
    );
    if (savedId == null || revoked) {
      if (!allowNewIdentity) {
        throw const ApiException(
          'Cần xác nhận tạo thiết bị mới. Lịch sử bí mật cũ không được khôi phục.',
        );
      }
      final crypto = await _crypto();
      _guard(generation);
      final created = crypto.generateIdentity(), keys = created.exportKeys();
      final bag = <String, dynamic>{
        'schemaVersion': 1,
        'deviceId': crypto.newId(),
        'label': label.trim(),
        'keys': base64Encode(keys),
        'pins': <String, String>{},
      };
      keys.fillRange(0, keys.length, 0);
      try {
        await _saveBag(bag, generation);
        _identity?.dispose();
        _identity = created;
      } catch (_) {
        created.dispose();
        rethrow;
      }
    } else {
      if (saved is! Map<String, dynamic>) {
        throw const ApiException('Kho khóa không hợp lệ.');
      }
      _bag = Map<String, dynamic>.from(saved);
      final keys = secretBase64(saved['keys'], length: 160, max: 160);
      try {
        final crypto = await _crypto();
        _guard(generation);
        _identity?.dispose();
        _identity = crypto.restoreIdentity(keys);
      } finally {
        keys.fillRange(0, keys.length, 0);
      }
    }
    _guard(generation);
    final result = await api.post('/secret/devices', {
      'deviceId': deviceId,
      'label': label.trim(),
      'encryptionPublicKey': base64Encode(_identity!.encryptionPublicKey),
      'signingPublicKey': base64Encode(_identity!.signingPublicKey),
    });
    _guard(generation);
    _checkOwnBundle(SecretBundle.fromJson(result), _identity!);
  }

  Future<void> revokeDevice(String id) async {
    final generation = _generation;
    _guard(generation);
    if (!session.canEnrollBiometric) {
      throw const ApiException(
        'Đăng nhập lại bằng mật khẩu và mã xác thực trong 15 phút để thu hồi khóa.',
      );
    }
    await api.delete('/secret/devices/${Uri.encodeComponent(id)}');
    _guard(generation);
    final local = await store.read(origin, userId);
    _guard(generation);
    if (local != null && (jsonDecode(local) as Map)['deviceId'] == id) {
      _identity?.dispose();
      _identity = null;
      _bag = null;
      await store.delete(origin, userId);
      _guard(generation);
    }
    if (!_disposed) notifyListeners();
  }

  Future<String> openDirect(String directConversationId) async {
    final generation = _generation;
    await _ensureIdentity();
    _guard(generation);
    final room = await api.post('/secret/conversations', {
      'directConversationId': directConversationId,
    });
    _guard(generation);
    if (!secretUuid(room['id'])) {
      throw const ApiException('Không nhận được phòng bí mật hợp lệ.');
    }
    return room['id'] as String;
  }

  Future<SecretRoom> inspectRoom(String id) async {
    final generation = _generation, own = await _ensureIdentity();
    _guard(generation);
    final response = await api.get(
      '/secret/conversations/${Uri.encodeComponent(id)}/bundles',
    );
    _guard(generation);
    final bundles = _rows(response).map(SecretBundle.fromJson).toList();
    if (bundles.length != 2 ||
        bundles.where((bundle) => bundle.userId == userId).length != 1) {
      throw const ApiException(
        'Một bên chưa có khóa hoạt động. Phòng bí mật đang khóa.',
      );
    }
    _checkOwnBundle(
      bundles.firstWhere((bundle) => bundle.userId == userId),
      own,
    );
    final fingerprint = safetyFingerprint(origin, id, bundles),
        pins = Map<String, dynamic>.from(_bag!['pins'] as Map);
    final previous = pins[id];
    return SecretRoom(
      id: id,
      bundles: bundles,
      fingerprint: fingerprint,
      verified: previous == fingerprint,
      changed: previous != null && previous != fingerprint,
    );
  }

  Future<void> confirmRoom(String id, String expectedFingerprint) async {
    final generation = _generation, room = await inspectRoom(id);
    _guard(generation);
    if (room.fingerprint != expectedFingerprint) {
      throw const ApiException(
        'Khóa đã đổi trong lúc xác minh. Hãy so sánh lại toàn bộ mã.',
      );
    }
    final pins = Map<String, dynamic>.from(_bag!['pins'] as Map)
      ..[id] = expectedFingerprint;
    await _saveBag({..._bag!, 'pins': pins}, generation);
  }

  Future<SecretMessagePage> messages(String id, {int? beforeSequence}) async {
    final generation = _generation, room = await inspectRoom(id);
    _guard(generation);
    if (!room.verified) return SecretMessagePage(room, [], null);
    final response = await api.get(
      '/secret/conversations/${Uri.encodeComponent(id)}/messages?deviceId=${Uri.encodeQueryComponent(deviceId!)}&limit=20${beforeSequence == null ? '' : '&beforeSequence=$beforeSequence'}',
    );
    _guard(generation);
    final crypto = await _crypto();
    _guard(generation);
    final messages = <SecretMessage>[];
    for (final dto in _rows(response)) {
      try {
        messages.add(SecretMessage(dto, _openMessage(dto, room, crypto), null));
      } catch (_) {
        messages.add(
          SecretMessage(
            dto,
            null,
            'Tin này không vượt qua xác minh khóa, chữ ký hoặc liên kết phòng.',
          ),
        );
      }
    }
    return SecretMessagePage(
      room,
      messages,
      response['nextBefore'] is int ? response['nextBefore'] as int : null,
    );
  }

  SecretPacket _openMessage(
    SecretJson dto,
    SecretRoom room,
    SecretCryptography crypto,
  ) {
    final envelope = dto['envelope'] is Map
        ? Map<String, dynamic>.from(dto['envelope'])
        : <String, dynamic>{};
    final sender = room.bundles
        .where((bundle) => bundle.userId == dto['senderUserId'])
        .firstOrNull;
    final own = room.bundles.firstWhere((bundle) => bundle.userId == userId);
    if (!secretUuid(dto['id']) ||
        dto['sequence'] is! int ||
        (dto['sequence'] as int) < 1 ||
        !secretUuid(dto['clientMessageId']) ||
        sender == null ||
        dto['conversationId'] != room.id ||
        dto['senderDeviceId'] != sender.deviceId ||
        dto['senderKeyVersion'] != sender.version ||
        envelope['recipientDeviceId'] != deviceId ||
        envelope['recipientKeyVersion'] != own.version ||
        !sameBytes(
          secretBase64(dto['senderSigningPublicKey'], length: 32),
          sender.signingKey,
        )) {
      throw const FormatException('Khóa tin không khớp khóa đã xác minh.');
    }
    final packet = crypto.open(
      _identity!,
      secretBase64(envelope['ciphertextBase64']),
      sender.signingKey,
    );
    if (packet.conversationId != room.id ||
        packet.senderUserId != dto['senderUserId'] ||
        packet.senderDeviceId != dto['senderDeviceId'] ||
        packet.clientMessageId != dto['clientMessageId']) {
      throw const FormatException('Tin bị gắn sai ngữ cảnh.');
    }
    return packet;
  }

  Future<PreparedSecretMessage> prepare(
    String roomId,
    String text, {
    PickedMedia? photo,
  }) async {
    final generation = _generation, room = await inspectRoom(roomId);
    _guard(generation);
    if (!room.verified) {
      throw const ApiException(
        'Cần so sánh và xác nhận mã an toàn trước khi gửi.',
      );
    }
    if (text.length > 2000 || (text.trim().isEmpty && photo == null)) {
      throw const ApiException('Nhập tin tối đa 2000 ký tự hoặc chọn một ảnh.');
    }
    final crypto = await _crypto();
    _guard(generation);
    SecretImageMetadata? image;
    if (photo != null) {
      if (photo.contentType != 'image/jpeg') {
        throw const ApiException(
          'Ảnh bí mật cần được chuẩn hóa JPEG trên thiết bị.',
        );
      }
      final file = File(photo.path), length = await file.length();
      _guard(generation);
      if (length < 3 || length > secretImageLimit) {
        throw const ApiException('Ảnh bí mật tối đa 5 MiB.');
      }
      final builder = await file
          .openRead(0, secretImageLimit + 1)
          .fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (builder, chunk) => builder..add(chunk),
          );
      _guard(generation);
      final plain = builder.takeBytes();
      EncryptedSecretImage encrypted;
      try {
        encrypted = crypto.encryptImage(plain);
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
      final folder = await Directory.systemTemp.createTemp('fv-secret-cipher-');
      _guard(generation);
      final ciphertextFile = File('${folder.path}/image.bin'),
          cancel = UploadCancellation();
      _uploads.add(cancel);
      try {
        await ciphertextFile.writeAsBytes(encrypted.ciphertext, flush: true);
        _guard(generation);
        final uploaded = await api.uploadSecretCipher(
          conversationId: roomId,
          senderDeviceId: deviceId!,
          recipientDeviceId: room.bundles
              .firstWhere((bundle) => bundle.userId != userId)
              .deviceId,
          ciphertext: ciphertextFile,
          cancellation: cancel,
        );
        _guard(generation);
        if (!secretUuid(uploaded['id']) ||
            uploaded['sizeBytes'] != encrypted.ciphertext.length ||
            uploaded['sha256'] != digestHex(encrypted.ciphertext)) {
          throw const ApiException('Máy chủ không xác nhận đúng bản mã ảnh.');
        }
        image = encrypted.metadata(uploaded['id'] as String);
      } finally {
        _uploads.remove(cancel);
        if (await ciphertextFile.exists()) await ciphertextFile.delete();
        if (await folder.exists()) await folder.delete();
      }
    }
    _guard(generation);
    final packet = SecretPacket(
      conversationId: roomId,
      senderUserId: userId,
      senderDeviceId: deviceId!,
      clientMessageId: crypto.newId(),
      text: text.trim(),
      image: image,
    );
    final envelopes = room.bundles
        .map(
          (bundle) => Map<String, dynamic>.unmodifiable({
            'recipientDeviceId': bundle.deviceId,
            'ciphertextBase64': base64Encode(
              crypto.seal(_identity!, packet, bundle.encryptionKey),
            ),
          }),
        )
        .toList(growable: false);
    return PreparedSecretMessage(
      roomId,
      room.fingerprint,
      Map<String, dynamic>.unmodifiable({
        'clientMessageId': packet.clientMessageId,
        'senderDeviceId': deviceId,
        'envelopes': List.unmodifiable(envelopes),
      }),
    );
  }

  Future<void> send(PreparedSecretMessage prepared) async {
    final generation = _generation, room = await inspectRoom(prepared.roomId);
    _guard(generation);
    if (!room.verified || room.fingerprint != prepared.fingerprint) {
      throw const ApiException(
        'Khóa đã đổi. Không gửi lại bản mã trước khi xác minh phòng.',
      );
    }
    await api.post(
      '/secret/conversations/${Uri.encodeComponent(prepared.roomId)}/messages',
      prepared.body,
    );
    _guard(generation);
  }

  Future<Uint8List> image(String roomId, SecretImageMetadata metadata) async {
    final generation = _generation, room = await inspectRoom(roomId);
    _guard(generation);
    if (!room.verified) {
      throw const ApiException('Cần xác minh lại mã an toàn để mở ảnh.');
    }
    final cipher = await api.secretCipherBytes(
      roomId,
      metadata.attachmentId,
      deviceId!,
    );
    _guard(generation);
    final crypto = await _crypto();
    _guard(generation);
    return crypto.decryptImage(cipher, metadata);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    session.removeListener(_syncSession);
    _identity?.dispose();
    _identity = null;
    _bag = null;
    for (final upload in _uploads) {
      upload.cancel();
    }
    super.dispose();
  }
}
