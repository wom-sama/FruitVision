import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../realtime.dart';
import 'components.dart';
import 'realtime_scope.dart';

class EventRefresh extends StatefulWidget {
  const EventRefresh({
    super.key,
    required this.targets,
    required this.onRefresh,
    required this.child,
    this.matches,
  });
  final Set<String> targets;
  final Future<void> Function() onRefresh;
  final bool Function(HubEvent)? matches;
  final Widget child;
  @override
  State<EventRefresh> createState() => _EventRefreshState();
}

class _EventRefreshState extends State<EventRefresh>
    with WidgetsBindingObserver {
  RealtimeClient? _hub;
  StreamSubscription<HubEvent>? _events;
  Timer? _debounce;
  bool _active = true;
  HubConnectionState? _lastState;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = RealtimeScope.maybeOf(context);
    if (hub == _hub) return;
    _hub?.removeListener(_connected);
    unawaited(_events?.cancel());
    _hub = hub;
    _lastState = hub?.state;
    hub?.addListener(_connected);
    _events = hub?.events.listen((event) {
      if (widget.targets.contains(event.target) &&
          (widget.matches?.call(event) ?? true)) {
        _schedule();
      }
    });
  }

  void _connected() {
    final state = _hub?.state;
    if (state == _lastState) return;
    _lastState = state;
    if (state == HubConnectionState.connected) _schedule();
  }

  void _schedule() {
    if (!_active) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted && _active) unawaited(widget.onRefresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      _schedule();
    } else {
      _debounce?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _hub?.removeListener(_connected);
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class LiveApiList extends StatefulWidget {
  const LiveApiList({
    super.key,
    required this.api,
    required this.path,
    required this.targets,
    required this.itemBuilder,
    this.header,
    this.empty = 'Chưa có dữ liệu.',
    this.listKey,
  });
  final ApiClient api;
  final String path, empty;
  final Set<String> targets;
  final Widget Function(Json) itemBuilder;
  final Widget? header;
  final GlobalKey<ApiListState>? listKey;
  @override
  State<LiveApiList> createState() => _LiveApiListState();
}

class _LiveApiListState extends State<LiveApiList> {
  late final _key = widget.listKey ?? GlobalKey<ApiListState>();
  @override
  Widget build(BuildContext context) => EventRefresh(
    targets: widget.targets,
    onRefresh: () async {
      await _key.currentState?.reload();
    },
    child: ApiList(
      key: _key,
      api: widget.api,
      path: widget.path,
      itemBuilder: widget.itemBuilder,
      header: widget.header,
      empty: widget.empty,
    ),
  );
}
