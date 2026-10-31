import 'dart:async';

import 'package:flutter/widgets.dart';

import 'realtime.dart';
import 'session.dart';

class InboxNotification {
  const InboxNotification(this.conversation);
  final Map<String, dynamic> conversation;
  String get id => conversation['id']?.toString() ?? '';
  int get unreadCount => (conversation['unreadCount'] as num?)?.toInt() ?? 0;
}

/// Foreground snapshots only. Read state and totals remain server authority.
class InboxController extends ChangeNotifier with WidgetsBindingObserver {
  InboxController({required this.session, this.realtime}) {
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_sessionChanged);
    realtime?.addListener(_connectionChanged);
    _events = realtime?.events.listen((event) {
      if (const {
        'MessageCreated',
        'ConversationCreated',
        'SecretMessageCreated',
        'SecretConversationCreated',
        'InboxChanged',
        'CommunityChanged',
      }.contains(event.target)) {
        _schedule();
      }
    });
    _sessionChanged();
  }

  final SessionController session;
  final RealtimeClient? realtime;
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> get entries => List.unmodifiable(_entries);
  List<InboxNotification> get notifications => _entries
      .where((row) => (row['unreadCount'] as num? ?? 0) > 0)
      .map(InboxNotification.new)
      .toList(growable: false);
  int unreadTotal = 0, unreadConversations = 0;
  bool loading = false;
  String? error;
  StreamSubscription<HubEvent>? _events;
  Timer? _debounce;
  Future<void>? _flight;
  final _reads = <String, Future<void>>{};
  String? _identity;
  int _epoch = 0;
  bool _dirty = false, _disposed = false, _foreground = true;
  HubConnectionState? _lastConnection;

  String? get _currentIdentity {
    final user = session.user;
    return session.endingSession ||
            user?.isActive != true ||
            user?.isApproved != true
        ? null
        : '${session.api.baseUrl}|${user!.id}';
  }

  void _sessionChanged() {
    final current = _currentIdentity;
    if (_disposed || current == _identity) return;
    _identity = current;
    ++_epoch;
    _debounce?.cancel();
    _entries = [];
    unreadTotal = unreadConversations = 0;
    error = null;
    loading = false;
    _dirty = current != null;
    notifyListeners();
    if (current != null && _foreground) unawaited(refresh());
  }

  void _connectionChanged() {
    final current = realtime?.state;
    if (current == HubConnectionState.connected && current != _lastConnection) {
      _schedule();
    }
    _lastConnection = current;
  }

  void _schedule() {
    if (_disposed || !_foreground || _identity == null) return;
    if (_flight != null) _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _debounce = null;
      unawaited(refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(refresh());
    } else {
      _debounce?.cancel();
      ++_epoch;
      _dirty = true;
    }
  }

  Future<void> refresh() {
    if (_disposed || !_foreground || _identity == null) return Future.value();
    if (_flight != null) {
      _dirty = true;
      return _flight!;
    }
    _debounce?.cancel();
    _debounce = null;
    _dirty = false;
    final epoch = _epoch, identity = _identity;
    loading = true;
    error = null;
    notifyListeners();
    final flight = _fetch(epoch, identity);
    _flight = flight;
    return flight;
  }

  Future<void> _fetch(int epoch, String? identity) async {
    try {
      final response = await session.api.get('/conversations?limit=20');
      if (!_valid(epoch, identity)) return;
      _entries = (response['items'] as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final summary = response['summary'];
      unreadTotal = summary is Map ? _count(summary['unreadTotal']) : 0;
      unreadConversations = summary is Map
          ? _count(summary['unreadConversations'])
          : 0;
    } catch (_) {
      if (_valid(epoch, identity)) {
        error = 'Chưa tải được tin nhắn. Hãy thử lại.';
      }
    } finally {
      _flight = null;
      if (!_disposed) {
        loading = false;
        notifyListeners();
        if (_dirty && _foreground && _identity != null) {
          _dirty = false;
          unawaited(refresh());
        }
      }
    }
  }

  bool _valid(int epoch, String? identity) =>
      !_disposed &&
      _foreground &&
      epoch == _epoch &&
      identity == _identity &&
      identity == _currentIdentity;
  int _count(Object? count) =>
      count is num ? count.toInt().clamp(0, 1 << 31) : 0;

  Future<void> markRead(
    String conversationId, {
    String? lastMessageId,
    int? lastSecretSequence,
  }) {
    if (_disposed ||
        _identity == null ||
        (lastMessageId == null && lastSecretSequence == null)) {
      return Future.value();
    }
    final epoch = _epoch, identity = _identity;
    final key = '$conversationId|$lastMessageId|$lastSecretSequence';
    return _reads.putIfAbsent(key, () async {
      try {
        await session.api.post(
          '/conversations/${Uri.encodeComponent(conversationId)}/read',
          {
            'lastMessageId': ?lastMessageId,
            'lastSecretSequence': ?lastSecretSequence,
          },
        );
        if (_valid(epoch, identity)) await refresh();
      } finally {
        _reads.remove(key);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _debounce?.cancel();
    unawaited(_events?.cancel());
    realtime?.removeListener(_connectionChanged);
    session.removeListener(_sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
