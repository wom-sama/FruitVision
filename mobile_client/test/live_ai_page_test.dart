import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/live_camera.dart';
import 'package:fruitvision_client/client/ui/live_ai.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/models.dart';

import 'ui_test.dart' as old;
import 'live_camera_test.dart' show Frames, Gateway;

class PermissionFrames extends Frames {
  final permission = Completer<void>();
  @override
  Future<void> start(int id) async {
    starts++;
    await permission.future;
  }
}

SessionController sellerSession() =>
    old.controller(old.UiTransport(), role: UserRole.producer);
void smallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(540, 960);
  tester.view.devicePixelRatio = 1.5;
  tester.platformDispatcher.textScaleFactorTestValue = 1.4;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

void main() {
  testWidgets(
    'running stop stays touchable outside preview at 360x640 with large text',
    (tester) async {
      smallPhone(tester);
      final frames = Frames(),
          camera = LiveCameraController(source: frames, gateway: Gateway()),
          session = sellerSession();
      addTearDown(() {
        camera.dispose();
        session.dispose();
      });
      await camera.start(7);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveAiPage(session: session, controller: camera),
        ),
      );
      await tester.pump();
      final stop = find.widgetWithText(FilledButton, 'Dừng nhận diện');
      expect(stop.hitTestable(), findsOneWidget);
      expect(tester.getRect(stop).bottom, lessThanOrEqualTo(640));
      expect(tester.getRect(stop).height, greaterThanOrEqualTo(48));
      expect(tester.widget<FilledButton>(stop).onPressed, isNotNull);
      final preview = find.byKey(const ValueKey('live-camera-preview'));
      expect(preview, findsOneWidget);
      expect(tester.getSize(preview).height, lessThanOrEqualTo(640 * .48));
      await tester.tap(stop);
      await tester.pump();
      expect(camera.running, isFalse);
      expect(frames.stops, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
  testWidgets(
    'initial permission inactive does not cancel startup; running inactive and paused startup stop without auto resume',
    (tester) async {
      final frames = PermissionFrames(),
          camera = LiveCameraController(source: frames, gateway: Gateway()),
          session = sellerSession();
      addTearDown(() {
        camera.dispose();
        session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LiveAiPage(session: session, controller: camera),
        ),
      );
      final opening = camera.start(7);
      await tester.pump();
      expect(camera.starting, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(frames.stops, 0);
      expect(camera.starting, isTrue);
      frames.permission.complete();
      await opening;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.running, isTrue);
      expect(frames.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(camera.running, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.running, isFalse);
      expect(frames.starts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final backgroundFrames = PermissionFrames(),
          background = LiveCameraController(
            source: backgroundFrames,
            gateway: Gateway(),
          );
      addTearDown(background.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveAiPage(session: session, controller: background),
        ),
      );
      final pending = background.start(8);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(backgroundFrames.stops, 1);
      backgroundFrames.permission.complete();
      await pending;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(background.running, isFalse);
      expect(backgroundFrames.starts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
