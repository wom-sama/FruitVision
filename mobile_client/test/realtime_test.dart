import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/app.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/vault.dart';

class HubTestTransport implements ApiTransport {
  Completer<ApiReply>? logout;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/auth/logout') && logout != null) {
      return logout!.future;
    }
    return ApiReply(200, jsonEncode({'items': <Object>[], 'aiReady': true}));
  }

  @override
  void close() {}
}

class HubTestVault implements SessionVault {
  @override
  Future<Map<String, dynamic>?> read() async => null;
  @override
  Future<void> write(Map<String, dynamic> value) async {}
  @override
  Future<void> clear() async {}
}

class TestSocket implements HubSocket {
  final input = StreamController<Object>(sync: true);
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  bool rejectJoins = false;
  @override
  Stream<Object> get messages => input.stream;
  @override
  void send(String message) {
    final json = jsonDecode(
      message.split(recordSeparator).first,
    ) as Map<String, dynamic>;
    sent.add(json);
    if (json['protocol'] == 'json') {
      scheduleMicrotask(() {
        if (!closed) input.add('{}$recordSeparator');
      });
    }
    if (json['invocationId'] != null) {
      scheduleMicrotask(() {
        if (!closed) {
          input.add(
            HubProtocol.encode({
              'type': 3,
              'invocationId': json['invocationId'],
              if (rejectJoins) 'error': 'Membership rejected',
            }),
          );
        }
      });
    }
  }

  void event(String target, Map<String, dynamic> payload) => input.add(
    HubProtocol.encode({
      'type': 1,
      'target': target,
      'arguments': [payload],
    }),
  );
  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      await input.close();
    }
  }
}

ApiClient hubApi({HubTestTransport? transport}) =>
    ApiClient(
      baseUrl: 'https://example.test',
      transport: transport ?? HubTestTransport(),
    )..setTokens(
      TokenPair(
        'access-one',
        'refresh',
        DateTime.now().toUtc().add(const Duration(minutes: 15)),
      ),
    );

void main() {
  test('JSON framing handles fragmented records, handshake and coalesced messages', () {
    final parser = HubProtocol();
    expect(parser.read('{"proto'), isEmpty);
    expect(
      parser.read(
        'col":"json","version":1}$recordSeparator{}$recordSeparator{"type":6}$recordSeparator',
      ),
      [
        {'protocol': 'json', 'version': 1},
        <String, dynamic>{},
        {'type': 6},
      ],
    );
    expect(
      () => parser.read('${'x' * (513 * 1024)}$recordSeparator'),
      throwsFormatException,
    );
  });

  testWidgets(
    'hub handshakes, deduplicates events, reconnects with current token and rejoins',
    (tester) async {
      final api = hubApi();
      final sockets = <TestSocket>[];
      final headers = <Map<String, String>>[];
      final uris = <Uri>[];
      final hub = RealtimeClient(
        api: api,
        connector: (uri, auth) async {
          uris.add(uri);
          headers.add(auth);
          final socket = TestSocket();
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(() {
        hub.dispose();
        api.close();
      });
      final received = <HubEvent>[];
      final subscription = hub.events.listen(received.add);
      addTearDown(subscription.cancel);
      hub.start('account-one');
      await tester.pump();
      expect(hub.state, HubConnectionState.connected);
      expect(uris.first.scheme, 'wss');
      expect(uris.first.host, 'example.test');
      expect(uris.first.port, 443);
      expect(uris.first.path, '/hubs/fruitvision');
      expect(uris.first.hasQuery, isFalse);
      expect(sockets.first.sent.first, {'protocol': 'json', 'version': 1});
      await hub.joinConversation('conversation-one');
      sockets.first.event('MessageCreated', {
        'eventId': 'event-one',
        'id': 'message-one',
        'conversationId': 'conversation-one',
      });
      sockets.first.event('MessageCreated', {
        'eventId': 'event-one',
        'id': 'message-one',
        'conversationId': 'conversation-one',
      });
      sockets.first.event('AiJobChanged', {
        'id': 'job-one',
        'revision': 1,
        'status': 'Running',
        'progress': 1,
      });
      sockets.first.event('AiJobChanged', {
        'id': 'job-one',
        'revision': 2,
        'status': 'Running',
        'progress': 1,
      });
      await tester.pump();
      expect(received.map((event) => event.target), [
        'MessageCreated',
        'AiJobChanged',
        'AiJobChanged',
      ]);
      api.setTokens(
        TokenPair(
          'access-two',
          'refresh-two',
          DateTime.now().toUtc().add(const Duration(minutes: 15)),
        ),
      );
      unawaited(sockets.first.close());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(sockets, hasLength(2));
      expect(headers.last['Authorization'], 'Bearer access-two');
      expect(
        sockets.last.sent.any(
          (message) => message['target'] == 'JoinConversation',
        ),
        isTrue,
      );
      hub.stop();
      await tester.pump(const Duration(seconds: 30));
      expect(sockets.last.closed, isTrue);
      expect(sockets, hasLength(2));
    },
  );

  testWidgets('reconnect attempts stop after bounded backoff', (tester) async {
    final api = hubApi();
    var attempts = 0;
    final hub = RealtimeClient(
      api: api,
      connector: (_, _) async {
        attempts++;
        throw const ApiException('Unavailable');
      },
    );
    addTearDown(() {
      hub.dispose();
      api.close();
    });
    hub.start('account-one');
    await tester.pump();
    for (final delay in RealtimeClient.reconnectDelays) {
      await tester.pump(Duration(seconds: delay));
      await tester.pump();
    }
    expect(attempts, 6);
    expect(hub.state, HubConnectionState.offline);
    await tester.pump(const Duration(minutes: 1));
    expect(attempts, 6);
  });

  testWidgets(
    'rejected membership is visible and a late stopped connection is closed',
    (tester) async {
      final api = hubApi();
      final socket = TestSocket()..rejectJoins = true;
      final hub = RealtimeClient(api: api, connector: (_, _) async => socket);
      addTearDown(() {
        hub.dispose();
        api.close();
      });
      hub.start('account-one');
      await tester.pump();
      await hub.joinConversation('conversation-one');
      expect(hub.isConversationJoined('conversation-one'), isFalse);
      expect(hub.conversationError('conversation-one'), isNotNull);
      hub.stop();
      final pending = Completer<HubSocket>();
      final lateHub = RealtimeClient(
        api: api,
        connector: (_, _) => pending.future,
      );
      addTearDown(lateHub.dispose);
      lateHub.start('account-one');
      await tester.pump();
      lateHub.stop();
      final lateSocket = TestSocket();
      pending.complete(lateSocket);
      await tester.pump();
      expect(lateSocket.closed, isTrue);
      expect(lateHub.state, HubConnectionState.stopped);
    },
  );

  testWidgets(
    'logout closes hub before server logout response and never reconnects',
    (tester) async {
      final transport = HubTestTransport()..logout = Completer<ApiReply>();
      final api = hubApi(transport: transport);
      final c = SessionController(api: api, vault: HubTestVault())
        ..loading = false
        ..user = const Account(
          id: 'approved',
          displayName: 'Minh',
          email: 'm@example.test',
          role: UserRole.consumer,
          approvalStatus: ApprovalStatus.approved,
          region: 'Đồng Tháp',
          isActive: true,
        );
      addTearDown(c.dispose);
      final sockets = <TestSocket>[];
      await tester.pumpWidget(
        FruitVisionApp(
          controller: c,
          realtimeConnector: (_, _) async {
            final socket = TestSocket();
            sockets.add(socket);
            return socket;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(sockets.single.closed, isFalse);
      final logout = c.logout();
      await tester.pump();
      expect(sockets.single.closed, isTrue);
      transport.logout!.complete(const ApiReply(200, '{}'));
      await logout;
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      expect(c.signedIn, isFalse);
      expect(sockets, hasLength(1));
      expect(find.byType(NavigationBar), findsNothing);
    },
  );
}
