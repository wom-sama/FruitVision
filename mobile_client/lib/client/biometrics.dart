import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BiometricInfo {
  const BiometricInfo({
    required this.available,
    required this.enrolled,
    this.deviceId,
    this.publicKey,
    this.label = '',
  });
  final bool available, enrolled;
  final String? deviceId, publicKey;
  final String label;
}

class BiometricPlatform {
  BiometricPlatform({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('vn.fruitvision/biometrics'),
      supported = supported ?? (!kIsWeb && Platform.isAndroid);
  final MethodChannel _channel;
  final bool supported;
  Future<BiometricInfo> _info(
    String method,
    String origin,
    String email,
  ) async {
    if (!supported) {
      return const BiometricInfo(available: false, enrolled: false);
    }
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(method, {
        'origin': origin,
        'email': email,
      });
      return BiometricInfo(
        available: data?['available'] == true,
        enrolled: data?['enrolled'] == true,
        deviceId: data?['deviceId'] as String?,
        publicKey: data?['publicKey'] as String?,
        label: data?['label'] as String? ?? '',
      );
    } on MissingPluginException {
      return const BiometricInfo(available: false, enrolled: false);
    }
  }

  Future<BiometricInfo> info(String origin, String email) =>
      _info('info', origin, email);
  Future<BiometricInfo> createKey(String origin, String email) =>
      _info('createKey', origin, email);
  Future<String> sign(String origin, String email, String payload) async {
    final signature = await _channel.invokeMethod<String>('sign', {
      'origin': origin,
      'email': email,
      'payload': payload,
    });
    if (signature == null || signature.isEmpty) {
      throw PlatformException(code: 'BIOMETRIC_SIGNATURE');
    }
    return signature;
  }

  Future<void> deleteKey(String origin, String email) => _channel
      .invokeMethod<void>('deleteKey', {'origin': origin, 'email': email});
}
