import 'package:flutter/material.dart';

import 'client/app.dart';
import 'client/session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Bound retained decoded previews on low-memory phones; visible image quality is unchanged.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 24 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 48;
  final controller = SessionController();
  runApp(FruitVisionApp(controller: controller));
  controller.initialize();
}
