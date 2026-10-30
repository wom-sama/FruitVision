import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';

const recordSeparator = '\u001e';

/// SignalR JSON Hub Protocol v1; text messages can contain several records.
/// Sources: dotnet/aspnetcore src/SignalR/docs/specs/{HubProtocol,TransportProtocols}.md.
class HubProtocol {
  String _pending = '';
  static String encode(Map<String, dynamic> message) =>
      '${jsonEncode(message)}$recordSeparator';
  List<Map<String, dynamic>> read(Object frame) {
    _pending += frame is String ? frame : utf8.decode(frame as List<int>);
    if (_pending.length > 512 * 1024) {
      throw const FormatException('Hub frame too large');
    }
    final records = _pending.split(recordSeparator);
    _pending = records.removeLast();
    return records.where((record) => record.isNotEmpty).map((record) {
      if (record.length > 256 * 1024) {
        throw const FormatException('Hub record too large');
      }
      final json = jsonDecode(record);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Invalid hub message');
      }
      return json;
    }).toList();
  }
}

abstract interface class HubSocket {
  Stream<Object> get messages;
  void send(String message);
  Future<void> close();
}

class IoHubSocket implements HubSocket {
  IoHubSocket(this.socket);
  final WebSocket socket;
  @override
  Stream<Object> get messages => socket.cast<Object>();
  @override
  void send(String message) => socket.add(message);
  @override
  Future<void> close() => socket.close();
}

typedef HubConnector = Future<HubSocket> Function(Uri, Map<String, String>);

enum HubConnectionState {
  stopped,
  connecting,
  connected,
  reconnecting,
  offline,
}

class HubEvent {
  const HubEvent(this.target, this.data);
  final String target;
  final Map<String, dynamic> data;
}

class RealtimeClient extends ChangeNotifier {
  RealtimeClient({required this.api, this.connector});
  final ApiClient api;
  final HubConnector? connector;
  final _events = StreamController<HubEvent>.broadcast();
  Stream<HubEvent> get events => _events.stream;
  final _conversations = <String>{};
  final _seen = <String>{};
  final _joined = <String>{};
  final _joinErrors = <String, String>{};
  bool isConversationJoined(String id) => _joined.contains(id);
  String? conversationError(String id) => _joinErrors[id];
  final _invocations = <String, Completer<void>>{};
  HubConnectionState state = HubConnectionState.stopped;
  HubSocket? _socket;
  StreamSubscription<Object>? _subscription;
  Timer? _ping, _retry, _watchdog, _connectTimeout;
  HttpClient? _connectingClient;
  Completer<HubSocket>? _connectAbort;
  bool _active = false, _disposed = false;
  int _generation = 0, _attempt = 0, _invocationId = 0;
  String? _identity;
  DateTime _lastReceived = DateTime.now();
  static const reconnectDelays = [1, 2, 4, 8, 15];
  String get label => switch (state) {
    HubConnectionState.connected => 'Đã kết nối cập nhật trực tiếp',
    HubConnectionState.connecting => 'Đang kết nối cập nhật trực tiếp…',
    HubConnectionState.reconnecting => 'Đang kết nối lại…',
    HubConnectionState.offline =>
      'Mất kết nối trực tiếp · Có thể cập nhật thủ công',
    HubConnectionState.stopped => 'Cập nhật trực tiếp đang tạm dừng',
  };
  void _state(HubConnectionState next) {
    if (_disposed || state == next) return;
    state = next;
    notifyListeners();
  }

  void start(String identity) {
    if (_disposed || (_active && _identity == identity)) return;
    stop();
    if (_identity != identity) {
      _conversations.clear();
      _seen.clear();
      _joinErrors.clear();
    }
    _identity = identity;
    _active = true;
    _attempt = 0;
    unawaited(_connect());
  }

  void retry() {
    if (!_active || _disposed) return;
    _retry?.cancel();
    _attempt = 0;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    _closeSocket();
    _state(
      _attempt == 0
          ? HubConnectionState.connecting
          : HubConnectionState.reconnecting,
    );
    Completer<void>? handshake;
    try {
      final token = await api.authenticatedToken();
      if (!_current(generation)) return;
      final base = Uri.parse(api.baseUrl);
      final uri = base.replace(
        scheme: 'wss',
        port: base.port,
        path: '/hubs/fruitvision',
      );
      final abort = Completer<HubSocket>();
      _connectAbort = abort;
      final connecting =
          Future<HubSocket>.sync(() {
            if (connector != null) {
              return connector!(uri, {'Authorization': 'Bearer $token'});
            }
            final client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 15);
            _connectingClient = client;
            return WebSocket.connect(
              uri.toString(),
              headers: {'Authorization': 'Bearer $token'},
              customClient: client,
            ).then<HubSocket>((socket) => IoHubSocket(socket));
          }).then((socket) {
            if (!_current(generation)) unawaited(socket.close());
            return socket;
          });
      final pending = Future.any([connecting, abort.future]);
      _connectTimeout = Timer(const Duration(seconds: 15), () {
        if (!abort.isCompleted) {
          abort.completeError(
            const ApiException('Kết nối trực tiếp quá thời gian.'),
          );
        }
        _connectingClient?.close(force: true);
      });
      final socket = await pending;
      _connectTimeout?.cancel();
      _connectAbort = null;
      _connectingClient?.close();
      _connectingClient = null;
      if (!_current(generation)) {
        await socket.close();
        return;
      }
      _socket = socket;
      final protocol = HubProtocol();
      final ready = Completer<void>();
      handshake = ready;
      _lastReceived = DateTime.now();
      _subscription = socket.messages.listen(
        (frame) {
          if (!_current(generation)) return;
          _lastReceived = DateTime.now();
          try {
            for (final message in protocol.read(frame)) {
              if (!ready.isCompleted) {
                if (message.containsKey('type') || message['error'] != null) {
                  ready.completeError(
                    const ApiException('Máy chủ từ chối giao thức cập nhật.'),
                  );
                } else {
                  ready.complete();
                }
              } else {
                _message(message, generation);
              }
            }
          } catch (_) {
            if (!ready.isCompleted) {
              ready.completeError(
                const ApiException('Phản hồi cập nhật không hợp lệ.'),
              );
            } else {
              _disconnected(generation);
            }
          }
        },
        onError: (Object _) {
          if (!ready.isCompleted) {
            ready.completeError(
              const ApiException('Kết nối trực tiếp bị gián đoạn.'),
            );
          } else {
            _disconnected(generation);
          }
        },
        onDone: () {
          if (!ready.isCompleted) {
            ready.completeError(
              const ApiException('Kết nối trực tiếp đã đóng.'),
            );
          } else {
            _disconnected(generation);
          }
        },
      );
      socket.send(HubProtocol.encode({'protocol': 'json', 'version': 1}));
      await ready.future.timeout(const Duration(seconds: 10));
      if (!_current(generation)) return;
      _attempt = 0;
      _state(HubConnectionState.connected);
      for (final id in _conversations.toList()) {
        unawaited(_join(id));
      }
      _ping = Timer.periodic(const Duration(seconds: 15), (_) {
        if (_current(generation)) _send({'type': 6});
      });
      _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        if (DateTime.now().difference(_lastReceived) >
            const Duration(seconds: 45)) {
          _disconnected(generation);
        }
      });
    } catch (_) {
      // Handshake errors are consumed here; auth/token errors are handled by ApiClient.
      if (handshake != null && !handshake.isCompleted) handshake.complete();
      if (_current(generation)) _disconnected(generation);
    }
  }

  bool _current(int generation) =>
      !_disposed && _active && generation == _generation;
  void _message(Map<String, dynamic> message, int generation) {
    switch (message['type']) {
      case 1:
        final target = message['target'];
        final arguments = message['arguments'];
        if (!const {
              'MessageCreated',
              'AiJobChanged',
              'PostChanged',
              'PublishedPostChanged',
              'ConversationCreated',
              'CommunityChanged',
              'ArticleChanged',
              'PublishedArticleChanged',
              'BranchChanged',
              'ApprovedBranchChanged',
              'RoleApplicationChanged',
              'SecretMessageCreated',
              'SecretConversationCreated',
              'SecretDeviceChanged',
            }.contains(target) ||
            arguments is! List ||
            arguments.isEmpty ||
            arguments.first is! Map) {
          return;
        }
        final data = Map<String, dynamic>.from(arguments.first as Map);
        final key =
            '$target:${data['serverEventId'] ?? data['eventId'] ?? '${data['id']}:${data['revision']}:${data['status']}:${data['progress']}:${data['framesProcessed']}'}';
        if (!_seen.add(key)) return;
        if (_seen.length > 200) _seen.remove(_seen.first);
        _events.add(HubEvent(target as String, data));
      case 3:
        final completer = _invocations.remove(message['invocationId']);
        if (completer != null && !completer.isCompleted) {
          if (message['error'] != null) {
            completer.completeError(
              const ApiException(
                'Không tham gia được hội thoại trực tiếp. Hãy cập nhật thủ công hoặc thử lại.',
              ),
            );
          } else {
            completer.complete();
          }
        }
      case 7:
        if (message['allowReconnect'] == true) {
          _disconnected(generation);
        } else {
          ++_generation;
          _closeSocket();
          _state(HubConnectionState.offline);
        }
      case 6:
        break;
    }
  }

  void _send(Map<String, dynamic> message) {
    try {
      _socket?.send(HubProtocol.encode(message));
    } catch (_) {
      _disconnected(_generation);
    }
  }

  Future<void> joinConversation(String id) async {
    _conversations.add(id);
    if (state == HubConnectionState.connected) await _join(id);
  }

  Future<void> _join(String id) async {
    if (!_active ||
        state != HubConnectionState.connected ||
        !_conversations.contains(id)) {
      return;
    }
    final invocationId = '${++_invocationId}';
    final generation = _generation;
    _joinErrors.remove(id);
    _joined.remove(id);
    final completer = Completer<void>();
    _invocations[invocationId] = completer;
    _send({
      'type': 1,
      'invocationId': invocationId,
      'target': 'JoinConversation',
      'arguments': [id],
    });
    try {
      await completer.future.timeout(const Duration(seconds: 10));
      if (_current(generation)) _joined.add(id);
    } catch (_) {
      if (_current(generation)) _joinErrors[id] = 'Không nhận được xác nhận tham gia hội thoại. Dùng cập nhật thủ công hoặc thử lại.';
    } finally {
      _invocations.remove(invocationId);
    }
    if (_current(generation)) notifyListeners();
  }

  void leaveConversation(String id) {
    _conversations.remove(id);
    _joined.remove(id);
    _joinErrors.remove(id);
  }

  void _disconnected(int generation) {
    if (!_current(generation)) return;
    ++_generation;
    _closeSocket();
    if (_attempt >= reconnectDelays.length) {
      _state(HubConnectionState.offline);
      return;
    }
    _state(HubConnectionState.reconnecting);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: reconnectDelays[_attempt++]), () {
      if (_active && !_disposed) unawaited(_connect());
    });
  }

  void _closeSocket() {
    _joined.clear();
    _connectTimeout?.cancel();
    final connecting = _connectAbort;
    _connectAbort = null;
    if (connecting != null && !connecting.isCompleted) {
      connecting.completeError(
        const ApiException('Đã dừng kết nối trực tiếp.'),
      );
    }
    _connectingClient?.close(force: true);
    _connectingClient = null;
    _ping?.cancel();
    _watchdog?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_socket?.close());
    _socket = null;
    for (final pending in _invocations.values) {
      if (!pending.isCompleted) pending.complete();
    }
    _invocations.clear();
  }

  void stop() {
    _active = false;
    ++_generation;
    _retry?.cancel();
    _closeSocket();
    _state(HubConnectionState.stopped);
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    unawaited(_events.close());
    super.dispose();
  }
}
