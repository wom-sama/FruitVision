import 'package:flutter/services.dart';

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
