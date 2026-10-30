import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../session.dart';
import '../realtime.dart';
import 'components.dart';
import 'realtime_scope.dart';
import 'event_refresh.dart';
import 'community.dart';
import 'posts.dart';
import 'visuals.dart';
import '../api.dart';

class ConversationList extends StatelessWidget {
  const ConversationList({
    super.key,
    required this.controller,
    required this.header,
  });
  final SessionController controller;
  final Widget header;
  @override
  Widget build(BuildContext context) => LiveApiList(
    api: controller.api,
    path: '/conversations?limit=20',
    targets: const {
      'ConversationCreated',
      'CommunityChanged',
      'MessageCreated',
    },
    header: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SectionTitle(
          'Trao đổi',
          subtitle:
              'Liên hệ từ tin nông sản hoặc tham gia nhóm để bắt đầu trao đổi.',
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CommunityPage(controller: controller),
            ),
          ),
          icon: const Icon(Icons.groups_outlined),
          label: const Text('Nhóm cộng đồng'),
        ),
        const SizedBox(height: 16),
      ],
    ),
    empty: 'Chưa có hội thoại. Mở một tin nông sản và chọn Liên hệ người đăng, hoặc tham gia nhóm cộng đồng.',
    itemBuilder: (row) => DataCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            controller: controller,
            id: value(row, 'id'),
            title: value(row, 'title'),
            group: row['kind'] == 'Group',
            readOnly: row['kind'] == 'Group' && row['isOpen'] == false,
          ),
        ),
      ),
      children: [
        IconBadge(
          row['kind'] == 'Group' ? Icons.groups_outlined : Icons.forum_outlined,
          color: blue,
        ),
        const SizedBox(height: 8),
        Text(
          value(row, 'title'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          row['kind'] == 'Group'
              ? 'Nhóm cộng đồng${value(row, 'region').isEmpty ? '' : ' · ${row['region']}'}'
              : 'Trao đổi từ tin nông sản',
        ),
        if (value(row, 'postId').isNotEmpty)
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PostDetailPage(
                  controller: controller,
                  id: value(row, 'postId'),
                ),
              ),
            ),
            icon: const Icon(Icons.article_outlined),
            label: const Text('Xem tin liên quan'),
          ),
        const Text('Mở hội thoại →'),
      ],
    ),
  );
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.controller,
    required this.id,
    required this.title,
    this.readOnly = false,
    this.group = false,
  });
  final SessionController controller;
  final String id, title;
  final bool readOnly, group;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _random = Random.secure();
  List<Json> _messages = [];
  String? _error, _next, _retryText, _retryKey;
  bool _loading = true, _sending = false;
  bool _requestInFlight = false, _refreshPending = false;
  int _generation = 0;
  int _newMessages = 0;
  bool _openedLatest = false;
  late bool _readOnly = widget.readOnly;
  late String? _contextNotice = widget.readOnly
      ? 'Nhóm đã đóng; chỉ xem lịch sử'
      : null;
  bool _contextLoading = false, _contextPending = false;
  RealtimeClient? _hub;
  StreamSubscription<HubEvent>? _events;
  Timer? _eventDebounce, _contextDebounce;
  String get _path =>
      '/conversations/${Uri.encodeComponent(widget.id)}/messages';
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_readLatest);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = RealtimeScope.maybeOf(context);
    if (hub == _hub) return;
    _hub?.removeListener(_onHub);
    _hub?.leaveConversation(widget.id);
    unawaited(_events?.cancel());
    _hub = hub;
    hub?.addListener(_onHub);
    unawaited(hub?.joinConversation(widget.id));
    _events = hub?.events.listen((event) {
      if (event.target == 'MessageCreated' &&
          event.data['conversationId'] == widget.id) {
        _eventDebounce?.cancel();
        _eventDebounce = Timer(const Duration(milliseconds: 250), _load);
      }
      if (widget.group &&
          event.target == 'CommunityChanged' &&
          (event.data['id'] == widget.id ||
              event.data['groupId'] == widget.id ||
              event.data['conversationId'] == widget.id)) {
        _contextDebounce?.cancel();
        _contextDebounce = Timer(
          const Duration(milliseconds: 250),
          _refreshContext,
        );
      }
    });
  }

  void _onHub() {
    if (_hub?.state == HubConnectionState.connected) {
      _load();
      if (widget.group) _refreshContext();
    }
  }

  @override
  void dispose() {
    _eventDebounce?.cancel();
    _contextDebounce?.cancel();
    unawaited(_events?.cancel());
    _hub?.removeListener(_onHub);
    _hub?.leaveConversation(widget.id);
    _scroll.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _refreshContext() async {
    if (_contextLoading) {
      _contextPending = true;
      return;
    }
    _contextLoading = true;
    try {
      final group = await widget.controller.api.get(
        '/community/groups/${Uri.encodeComponent(widget.id)}',
      );
      if (!mounted) return;
      setState(() {
        _readOnly = group['isOpen'] == false || group['isMember'] != true;
        _contextNotice = group['isMember'] != true
            ? 'Bạn không còn là thành viên của nhóm.'
            : group['isOpen'] == false
            ? 'Nhóm đã đóng; chỉ xem lịch sử'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is ApiException && (e.status == 403 || e.status == 404)) {
          _readOnly = true;
          _contextNotice = 'Bạn không còn quyền truy cập nhóm.';
        } else {
          _error = errorText(e);
        }
      });
    } finally {
      _contextLoading = false;
      if (mounted && _contextPending) {
        _contextPending = false;
        unawaited(_refreshContext());
      }
    }
  }

  bool get _nearBottom =>
      !_scroll.hasClients || _scroll.position.extentAfter <= 96;

  void _readLatest() {
    if (_newMessages > 0 && _nearBottom) {
      setState(() => _newMessages = 0);
    }
  }

  Future<void> _positionMessages({
    required bool latest,
    double? oldPixels,
    double? oldExtent,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (oldPixels != null && oldExtent != null) {
      _scroll.jumpTo((oldPixels + max - oldExtent).clamp(0.0, max).toDouble());
    } else if (latest) {
      _scroll.jumpTo(max);
    }
  }

  void _showLatest() {
    setState(() => _newMessages = 0);
    unawaited(_positionMessages(latest: true));
  }

  Future<void> _load({bool older = false}) async {
    if (widget.controller.endingSession) return;
    if (older && (_loading || _next == null)) return;
    if (_requestInFlight) {
      if (!older) _refreshPending = true;
      return;
    }
    _requestInFlight = true;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.controller.api.get(
        '$_path?limit=20${older ? '&before=${Uri.encodeQueryComponent(_next!)}' : ''}',
      );
      if (!mounted || generation != _generation) return;
      final incoming = rows(result).reversed.toList();
      final follow = !_openedLatest || _nearBottom;
      final oldPixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
      final oldExtent = _scroll.hasClients
          ? _scroll.position.maxScrollExtent
          : 0.0;
      final known = _messages.map((message) => message['id']).toSet();
      final added = incoming
          .where((message) => !known.contains(message['id']))
          .length;
      setState(() {
        final unique = <String, Json>{
          for (final item in [..._messages, ...incoming])
            value(item, 'id'): item,
        };
        _messages = unique.values.toList()
          ..sort(
            (a, b) => value(a, 'createdAt').compareTo(value(b, 'createdAt')),
          );
        if (_messages.length > 200) {
          _messages = _messages.sublist(_messages.length - 200);
        }
        _next = result['next']?.toString();
        _loading = false;
        if (!older) {
          _openedLatest = true;
          _newMessages = follow ? 0 : _newMessages + added;
        }
      });
      await _positionMessages(
        latest: !older && follow,
        oldPixels: older ? oldPixels : null,
        oldExtent: older ? oldExtent : null,
      );
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    } finally {
      _requestInFlight = false;
      if (mounted && _refreshPending) {
        _refreshPending = false;
        _load();
      }
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (_sending || _readOnly || text.isEmpty) return;
    if (text.length > 2000) {
      setState(() => _error = 'Tin nhắn tối đa 2.000 ký tự.');
      return;
    }
    // Keep the key for a retry of the same draft after an uncertain network response.
    if (_retryText != text) {
      _retryText = text;
      _retryKey =
          'm${DateTime.now().microsecondsSinceEpoch}${_random.nextInt(1 << 30)}';
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final sent = await widget.controller.api.post(_path, {
        'text': text,
        'clientMessageId': _retryKey,
      });
      if (!mounted) return;
      final follow = _nearBottom;
      final alreadyShown = _messages.any(
        (message) => message['id'] == sent['id'],
      );
      // A refresh that began before this mutation must not overwrite the new message.
      ++_generation;
      setState(() {
        _messages = [..._messages.where((m) => m['id'] != sent['id']), sent];
        _text.clear();
        _retryText = null;
        _retryKey = null;
        _sending = false;
        _loading = false;
        if (follow) {
          _newMessages = 0;
        } else if (!alreadyShown) {
          _newMessages++;
        }
      });
      await _positionMessages(latest: follow);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: 'Cập nhật tin nhắn',
          onPressed: _loading || _sending ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  // History is capped at 200. Measure this bounded transcript as
                  // one child so newest/reading anchors use exact extents.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const RealtimeStatus(),
                      const SizedBox(height: 8),
                      if (_hub?.state == HubConnectionState.connected) ...[
                        if (_hub!.conversationError(widget.id) != null)
                          MessageBox(
                            _hub!.conversationError(widget.id)!,
                            error: true,
                            child: TextButton(
                              onPressed: () =>
                                  _hub!.joinConversation(widget.id),
                              child: const Text('Thử tham gia lại'),
                            ),
                          )
                        else
                          Text(
                            _hub!.isConversationJoined(widget.id)
                                ? 'Đã tham gia cập nhật hội thoại trực tiếp.'
                                : 'Đang xác nhận tham gia hội thoại…',
                          ),
                        const SizedBox(height: 8),
                      ],
                      const Text(
                        'Kéo xuống hoặc bấm cập nhật để khôi phục tin khi kết nối gián đoạn.',
                      ),
                      const SizedBox(height: 12),
                      if (_error != null) ...[
                        MessageBox(
                          _error!,
                          error: true,
                          child: TextButton(
                            onPressed: _loading || _sending ? null : _load,
                            child: const Text('Cập nhật lại'),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_loading && _messages.isEmpty)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      if (_next != null && _messages.length < 200)
                        OutlinedButton(
                          onPressed: _loading || _sending
                              ? null
                              : () => _load(older: true),
                          child: const Text('Xem tin cũ hơn'),
                        ),
                      if (!_loading && _messages.isEmpty && _error == null)
                        const MessageBox(
                          'Chưa có tin nhắn. Gửi lời chào đầu tiên.',
                        ),
                      ..._messages.map((message) {
                        final own =
                            message['senderId'] == widget.controller.user?.id;
                        final sender = message['sender'] is Map
                            ? Map<String, dynamic>.from(
                                message['sender'] as Map,
                              )
                            : <String, dynamic>{};
                        final identified = sender['id'] == message['senderId'];
                        final name = identified
                            ? value(sender, 'displayName').trim()
                            : '';
                        final roles = UserRole.values.where(
                          (role) => identified && role.wire == sender['role'],
                        );
                        return Align(
                          key: ValueKey(message['id']),
                          alignment: own
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 480),
                            margin: EdgeInsets.only(
                              bottom: 12,
                              left: own ? 24 : 0,
                              right: own ? 0 : 24,
                            ),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: own
                                  ? const Color(0xFFDCEFE1)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  own
                                      ? 'Bạn'
                                      : name.isEmpty
                                      ? 'Thành viên'
                                      : name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (!own && roles.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      roles.first.label,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: blue,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 4),
                                Text(value(message, 'text')),
                                const SizedBox(height: 8),
                                Text(
                                  displayTime(message['createdAt']),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_newMessages > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Semantics(
                liveRegion: true,
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: _showLatest,
                    icon: const Icon(Icons.arrow_downward),
                    label: Text(
                      '$_newMessages tin nhắn mới',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          if (_contextNotice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _contextNotice!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    enabled: !_sending && !_readOnly,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      labelText: 'Tin nhắn',
                      counterText: '',
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 52,
                  height: 52,
                  child: IconButton.filled(
                    tooltip: _sending ? 'Đang gửi tin' : 'Gửi tin nhắn',
                    onPressed: _sending || _readOnly ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
