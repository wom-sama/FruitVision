import 'package:flutter/material.dart';

import '../realtime.dart';

class RealtimeScope extends InheritedWidget {
  const RealtimeScope({super.key, required this.client, required super.child});
  final RealtimeClient client;
  static RealtimeClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RealtimeScope>()?.client;
  @override
  bool updateShouldNotify(RealtimeScope oldWidget) =>
      oldWidget.client != client;
}

class RealtimeStatus extends StatelessWidget {
  const RealtimeStatus({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final hub = RealtimeScope.maybeOf(context);
    if (hub == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: hub,
      builder: (_, _) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Icon(
              hub.state == HubConnectionState.connected
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
              size: 20,
            ),
            Tooltip(
              message: hub.label,
              child: Text(
                compact
                    ? switch (hub.state) {
                        HubConnectionState.connected => 'Đã kết nối',
                        HubConnectionState.connecting => 'Đang kết nối',
                        HubConnectionState.reconnecting => 'Đang nối lại',
                        HubConnectionState.offline => 'Ngoại tuyến',
                        HubConnectionState.stopped => 'Tạm dừng',
                      }
                    : hub.label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (hub.state == HubConnectionState.offline)
              TextButton(
                onPressed: hub.retry,
                child: const Text('Kết nối lại'),
              ),
          ],
        ),
      ),
    );
  }
}
