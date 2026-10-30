import 'package:flutter/material.dart';

import '../secret_messaging.dart';

class SecretScope extends InheritedWidget {
  const SecretScope({super.key, required this.messaging, required super.child});
  final SecretMessaging messaging;
  static SecretMessaging? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SecretScope>()?.messaging;
  @override
  bool updateShouldNotify(SecretScope oldWidget) =>
      oldWidget.messaging != messaging;
}
