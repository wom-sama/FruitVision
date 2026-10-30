import 'package:flutter/services.dart';

import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

Future<String> faceImageBase64(PickedMedia photo) async =>
    base64Encode(await readFaceImage(photo));

Future<Uint8List> readFaceImage(PickedMedia photo) async {
  if (!{'image/jpeg', 'image/png'}.contains(photo.contentType)) {
    throw const FormatException('Ảnh khuôn mặt cần là JPEG hoặc PNG.');
  }
  final file = File(photo.path), limit = 2 * 1024 * 1024;
  final size = await file.length();
  if (size < 3 || size > limit) {
    throw const FormatException(
      'Ảnh khuôn mặt tối đa 2 MiB. Hãy chụp ảnh mới hoặc chọn ảnh nhỏ hơn.',
    );
  }
  final builder = await file
      .openRead(0, limit + 1)
      .fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
  final bytes = builder.takeBytes();
  if (bytes.length > limit) {
    throw const FormatException('Ảnh khuôn mặt tối đa 2 MiB.');
  }
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  final png =
      bytes.length >= 8 &&
      List.generate(8, (i) => bytes[i] == signature[i]).every((v) => v);
  if ((photo.contentType == 'image/jpeg' && !jpeg) ||
      (photo.contentType == 'image/png' && !png)) {
    throw const FormatException('Tệp không khớp định dạng JPEG/PNG.');
  }
  return bytes;
}

Future<Uint8List> readPreparedChatPhoto(PickedMedia photo) async {
  if (photo.contentType != 'image/jpeg') {
    throw const FormatException('Ảnh cần được chuẩn hóa JPEG trên thiết bị.');
  }
  final file = File(photo.path),
      limit = 5 * 1024 * 1024,
      length = await File(photo.path).length();
  if (length < 3 || length > limit) {
    throw const FormatException('Ảnh tối đa 5 MiB.');
  }
  final builder = await file
      .openRead(0, limit + 1)
      .fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
  final bytes = builder.takeBytes();
  if (bytes.length > limit ||
      bytes[0] != 255 ||
      bytes[1] != 216 ||
      bytes[2] != 255) {
    throw const FormatException('Ảnh không phải JPEG chuẩn hợp lệ.');
  }
  return bytes;
}

class PickedMedia {
  const PickedMedia({
    required this.path,
    required this.name,
    required this.bytes,
    required this.mediaType,
    required this.contentType,
  });
  factory PickedMedia.fromJson(Map<dynamic, dynamic> json) => PickedMedia(
    path: json['path'] as String,
    name: json['name'] as String,
    bytes: (json['bytes'] as num).toInt(),
    mediaType: json['mediaType'] as String,
    contentType: json['contentType'] as String,
  );
  final String path, name, mediaType, contentType;
  final int bytes;
}

class NativeMediaPicker {
  static const _channel = MethodChannel('vn.fruitvision/media');
  Future<PickedMedia?> pick(String method) async {
    final json = await _channel.invokeMapMethod<dynamic, dynamic>(method);
    return json == null ? null : PickedMedia.fromJson(json);
  }

  Future<void> delete(PickedMedia media) =>
      _channel.invokeMethod<void>('delete', {'path': media.path});
}

class PickedEvidence {
  const PickedEvidence({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.contentType,
  });
  final String path, name, contentType;
  final int sizeBytes;
}

class NativeEvidencePicker {
  static const _channel = MethodChannel('vn.fruitvision/media');
  final _files = <File>[];
  Future<PickedEvidence?> pick() async {
    final data = await _channel.invokeMapMethod<String, dynamic>(
      'pickEvidence',
    );
    return data == null
        ? null
        : PickedEvidence(
            path: data['path'] as String,
            name: data['name'] as String,
            sizeBytes: (data['sizeBytes'] as num).toInt(),
            contentType: data['contentType'] as String,
          );
  }

  Future<void> delete(PickedEvidence file) =>
      _channel.invokeMethod<void>('delete', {'path': file.path});
  Future<void> view(Uint8List bytes, String contentType) async {
    final ext = switch (contentType) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'application/pdf' => 'pdf',
      _ => throw const FormatException('Loại chứng từ không hỗ trợ.'),
    };
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const FormatException('Chứng từ tối đa 5 MiB.');
    }
    final directory = await Directory(
      '${Directory.systemTemp.path}/fv_evidence',
    ).create(recursive: true);
    final random = Random.secure(), values = List<int>.generate(16, (_) => 0);
    for (var i = 0; i < values.length; i++) {
      values[i] = random.nextInt(256);
    }
    values[6] = (values[6] & 15) | 64;
    values[8] = (values[8] & 63) | 128;
    final hex = values.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final uuid =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final file = File('${directory.path}/$uuid.$ext');
    _files.add(file);
    await file.writeAsBytes(bytes, flush: true);
    await _channel.invokeMethod<void>('openEvidence', {
      'path': file.path,
      'contentType': contentType,
    });
  }

  Future<void> dispose() async {
    for (final file in _files) {
      if (await file.exists()) await file.delete();
    }
    _files.clear();
  }
}
