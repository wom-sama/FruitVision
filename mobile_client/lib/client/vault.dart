import 'dart:convert';

import 'package:flutter/services.dart';

abstract interface class SessionVault {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
  Future<void> clear();
}

class AndroidSessionVault implements SessionVault {
  static const _channel = MethodChannel('vn.fruitvision/session_vault');
  @override
  Future<Map<String, dynamic>?> read() async {
    final value = await _channel.invokeMethod<String>('read');
    return value == null ? null : jsonDecode(value) as Map<String, dynamic>;
  }

  @override
  Future<void> write(Map<String, dynamic> value) =>
      _channel.invokeMethod<void>('write', jsonEncode(value));
  @override
  Future<void> clear() => _channel.invokeMethod<void>('clear');
}
