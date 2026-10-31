import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';

import '../session.dart';
import '../inbox.dart';
import '../realtime.dart';
import 'components.dart';
import 'visuals.dart';
import 'realtime_scope.dart';
import 'community.dart';
import 'secret_chat.dart';
import 'secret_scope.dart';
import '../api.dart';
import '../media.dart';
import 'api_photo.dart';
import 'new_message.dart';
import 'profile.dart';

String inboxTitle(Json row) {
  final peer = row['peer'];
  return row['kind'] != 'Group' &&
          peer is Map &&
          (peer['displayName']?.toString().trim().isNotEmpty ?? false)
      ? peer['displayName'].toString()
      : value(row, 'title', 'Hội thoại');
}

String inboxPreview(Json row) {
  if (row['lastMessageEncrypted'] == true) return 'Tin nhắn mã hóa';
  final message = row['lastMessage'];
  if (message is! Map) return 'Chưa có tin nhắn';
  if (message['kind'] == 'image') return 'Hình ảnh';
  if (message['kind'] == 'encrypted') return 'Tin nhắn mã hóa';
  final text = message['text']?.toString() ?? '';
  final sender = message['senderName']?.toString() ?? '';
  return sender.isEmpty ? text : '$sender: $text';
}

String inboxContext(Json row) {
  if (row['kind'] == 'Group') return '';
  if (value(row, 'articleId').isNotEmpty) {
    return 'Bài viết · ${value(row, 'title')}';
  }
  if (value(row, 'postId').isNotEmpty) {
    return 'Tin nông sản · ${value(row, 'title')}';
  }
  return 'Nhắn tin riêng';
}

Future<void> openInboxConversation(
  BuildContext context, {
  required SessionController controller,
  required InboxController inbox,
  required Json row,
}) async {
  if (row['lastMessageEncrypted'] == true) {
    final messaging = SecretScope.maybeOf(context);
    final secretId = value(row, 'secretConversationId');
    if (messaging == null ||
        controller.user?.canSell != true ||
        secretId.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Tin nhắn mã hóa đầu cuối'),
          content: const Text(
            'Chưa mở được khóa của hội thoại trên thiết bị này. Không thể chuyển nội dung mã hóa sang chat thường. Kiểm tra khóa thiết bị trong Tài khoản.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      );
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SecretChatPage(
          messaging: messaging,
          id: secretId,
          title: inboxTitle(row),
          inbox: inbox,
          directConversationId: value(row, 'id'),
        ),
      ),
    );
  } else {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          controller: controller,
          id: value(row, 'id'),
          title: value(row, 'title'),
          group: row['kind'] == 'Group',
          readOnly: row['kind'] == 'Group' && row['isOpen'] == false,
          inbox: inbox,
        ),
      ),
    );
  }
  if (context.mounted) unawaited(inbox.refresh());
}

class InboxConversationTile extends StatelessWidget {
  const InboxConversationTile({
    super.key,
    required this.row,
    required this.onTap,
    this.onProfile,
  });
  final Json row;
  final VoidCallback onTap;
  final VoidCallback? onProfile;
  @override
  Widget build(BuildContext context) {
    final count = (row['unreadCount'] as num?)?.toInt() ?? 0;
    final name = inboxTitle(row), peer = row['peer'];
    final role = peer is Map
        ? UserRole.values
              .where((role) => role.wire == peer['role'])
              .firstOrNull
              ?.label
        : null;
    final theme = Theme.of(context);
    return Semantics(
      label: '$name${count > 0 ? ', $count tin chưa đọc' : ''}',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton.filledTonal(
                tooltip: onProfile == null ? null : 'Xem hồ sơ $name',
                onPressed: onProfile,
                icon: Icon(
                  row['kind'] == 'Group'
                      ? Icons.groups_outlined
                      : Icons.person_outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: count > 0
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (count > 0) ...[
                          const SizedBox(width: 8),
                          Badge(label: Text(count > 99 ? '99+' : '$count')),
                        ],
                      ],
                    ),
                    if (role != null || row['kind'] == 'Group')
                      Text(
                        role ?? 'Nhóm cộng đồng',
                        style: theme.textTheme.labelSmall,
                      ),
                    if (inboxContext(row).isNotEmpty)
                      Text(
                        inboxContext(row),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (row['lastMessageEncrypted'] == true) ...[
                          const Icon(Icons.lock_outline, size: 14),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            inboxPreview(row),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                    if (value(row, 'lastActivityAt').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          displayTime(row['lastActivityAt']),
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ConversationList extends StatefulWidget {
  const ConversationList({
    super.key,
    required this.controller,
    required this.header,
    this.inbox,
  });
  final SessionController controller;
  final Widget header;
  final InboxController? inbox;
  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  InboxController? _owned;
  RealtimeClient? _hub;
  InboxController get _inbox => widget.inbox ?? _owned!;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = RealtimeScope.maybeOf(context);
    if (widget.inbox == null && (_owned == null || hub != _hub)) {
      _owned?.dispose();
      _hub = hub;
      _owned = InboxController(session: widget.controller, realtime: hub);
    }
  }

  @override
  void didUpdateWidget(ConversationList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.inbox != widget.inbox) {
      _owned?.dispose();
      _owned = widget.inbox == null
          ? InboxController(session: widget.controller, realtime: _hub)
          : null;
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _inbox,
    builder: (context, _) => RefreshIndicator(
      onRefresh: _inbox.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                widget.header,
                const SectionTitle(
                  'Tin nhắn',
                  subtitle: 'Hội thoại trực tiếp và nhóm chia sẻ về xoài.',
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton.filledTonal(
                    tooltip: 'Tin nhắn mới',
                    icon: const Icon(Icons.edit_square),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NewMessagePage(
                          controller: widget.controller,
                          inbox: _inbox,
                        ),
                      ),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          CommunityPage(controller: widget.controller),
                    ),
                  ),
                  icon: const Icon(Icons.groups_outlined),
                  label: const Text('Nhóm cộng đồng'),
                ),
                if (_inbox.error != null)
                  MessageBox(
                    _inbox.error!,
                    error: true,
                    child: TextButton(
                      onPressed: _inbox.refresh,
                      child: const Text('Thử lại'),
                    ),
                  ),
              ],
            ),
          ),
          if (_inbox.loading) const LinearProgressIndicator(),
          if (!_inbox.loading && _inbox.entries.isEmpty && _inbox.error == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Chưa có hội thoại. Mở bài chia sẻ để liên hệ tác giả hoặc tham gia nhóm cộng đồng.',
              ),
            ),
          for (final row in _inbox.entries) ...[
            InboxConversationTile(
              row: row,
              onProfile:
                  row['peer'] is Map &&
                      value(
                        Map<String, dynamic>.from(row['peer']),
                        'id',
                      ).isNotEmpty
                  ? () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<bool>(
                          builder: (_) => UserProfilePage(
                            controller: widget.controller,
                            userId: (row['peer'] as Map)['id'].toString(),
                            inbox: _inbox,
                          ),
                        ),
                      );
                      if (mounted) await _inbox.refresh();
                    }
                  : null,
              onTap: () => openInboxConversation(
                context,
                controller: widget.controller,
                inbox: _inbox,
                row: row,
              ),
            ),
            const Divider(height: 1, indent: 68),
          ],
        ],
      ),
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
    this.inbox,
  });
  final SessionController controller;
  final String id, title;
  final bool readOnly, group;
  final InboxController? inbox;
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
  final _photoPicker = NativeMediaPicker();
  PickedMedia? _imageDraft;
  String? _imageKey;
  UploadCancellation? _imageCancel;
  bool _requestInFlight = false, _refreshPending = false;
  int _generation = 0;
  int _newMessages = 0;
  bool _openedLatest = false;
  String? _lastReadId, _readingId;
  late bool _readOnly = widget.readOnly;
  late String? _contextNotice = widget.readOnly
      ? 'Nhóm đã đóng; chỉ xem lịch sử'
      : null;
  bool _contextLoading = false, _contextPending = false;
  Json? _directPeer;
  bool _secretEligible = false, _directContextLoading = false;
  String? _directContextError;
  int _directContextGeneration = 0;
  RealtimeClient? _hub;
  StreamSubscription<HubEvent>? _events;
  Timer? _eventDebounce, _contextDebounce;
  String get _path =>
      '/conversations/${Uri.encodeComponent(widget.id)}/messages';
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_readLatest);
    if (!widget.group) unawaited(_refreshDirectContext());
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
    _directContextGeneration++;
    _eventDebounce?.cancel();
    _contextDebounce?.cancel();
    unawaited(_events?.cancel());
    _hub?.removeListener(_onHub);
    _hub?.leaveConversation(widget.id);
    _scroll.dispose();
    _text.dispose();
    _imageCancel?.cancel();
    final draft = _imageDraft;
    _imageDraft = null;
    if (draft != null) unawaited(_photoPicker.delete(draft));
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

  Future<void> _refreshDirectContext() async {
    if (widget.group || _directContextLoading) return;
    final generation = ++_directContextGeneration,
        origin = widget.controller.api.baseUrl,
        userId = widget.controller.user?.id;
    _directContextLoading = true;
    setState(() {
      _secretEligible = false;
      _directContextError = null;
    });
    try {
      final data = await widget.controller.api.get(
        '/conversations/${Uri.encodeComponent(widget.id)}/context',
      );
      if (!mounted ||
          generation != _directContextGeneration ||
          origin != widget.controller.api.baseUrl ||
          userId != widget.controller.user?.id) {
        return;
      }
      final peer = data['peer'];
      if (data['kind'] != 'Direct' ||
          peer is! Map ||
          peer['id'] is! String ||
          peer['displayName'] is! String ||
          peer['role'] is! String) {
        throw const FormatException('Chưa xác minh được thông tin hội thoại.');
      }
      final role = UserRole.values
          .where((role) => role.wire == peer['role'])
          .firstOrNull;
      final follow = _nearBottom;
      setState(() {
        _directPeer = {
          'id': peer['id'],
          'displayName': peer['displayName'],
          'role': peer['role'],
        };
        _secretEligible =
            data['secretEligible'] == true &&
            (role == UserRole.producer || role == UserRole.trader);
      });
      if (follow) unawaited(_positionMessages(latest: true));
    } catch (_) {
      if (mounted && generation == _directContextGeneration) {
        setState(() {
          _directPeer = null;
          _secretEligible = false;
          _directContextError = 'Chưa xác minh được người trao đổi. Chat thường vẫn dùng được; chat mã hóa đang ẩn.';
        });
      }
    } finally {
      _directContextLoading = false;
    }
  }

  bool get _nearBottom =>
      !_scroll.hasClients || _scroll.position.extentAfter <= 96;

  void _readLatest() {
    if (_openedLatest && !_loading && _nearBottom) {
      unawaited(_acknowledgeLatest());
    }
    if (_newMessages > 0 && _nearBottom) {
      setState(() => _newMessages = 0);
    }
  }

  Future<void> _acknowledgeLatest() async {
    if (!mounted ||
        !_scroll.hasClients ||
        !_nearBottom ||
        ModalRoute.of(context)?.isCurrent != true ||
        WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed ||
        widget.controller.endingSession ||
        _messages.isEmpty) {
      return;
    }
    final id = value(_messages.last, 'id');
    if (id.isEmpty || id == _lastReadId || _readingId != null) return;
    _readingId = id;
    final origin = widget.controller.api.baseUrl,
        userId = widget.controller.user?.id;
    try {
      if (widget.inbox != null) {
        await widget.inbox!.markRead(widget.id, lastMessageId: id);
      } else {
        await widget.controller.api.post(
          '/conversations/${Uri.encodeComponent(widget.id)}/read',
          {'lastMessageId': id},
        );
      }
      if (mounted &&
          origin == widget.controller.api.baseUrl &&
          userId == widget.controller.user?.id) {
        _lastReadId = id;
      }
    } catch (_) {
      // Failed receipts never hide messages or invent local unread totals.
    } finally {
      _readingId = null;
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
    if (latest && mounted) await _acknowledgeLatest();
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

  Future<void> _chooseImage(String method) async {
    if (_sending || _readOnly) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    PickedMedia? selected;
    try {
      selected = await _photoPicker.pick(method);
      if (selected == null) return;
      if (selected.contentType != 'image/jpeg' ||
          selected.bytes > 5 * 1024 * 1024) {
        throw const ApiException('Chọn ảnh JPEG chuẩn hóa tối đa 5 MiB.');
      }
      if (!mounted) {
        await _photoPicker.delete(selected);
        return;
      }
      final previous = _imageDraft;
      setState(() {
        _imageDraft = selected;
        _imageKey =
            'i${DateTime.now().microsecondsSinceEpoch}${_random.nextInt(1 << 30)}';
      });
      if (previous != null) await _photoPicker.delete(previous);
    } catch (error) {
      if (selected != null && selected != _imageDraft) {
        await _photoPicker.delete(selected);
      }
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendImage() async {
    final photo = _imageDraft, key = _imageKey;
    if (photo == null || key == null || _sending || _readOnly) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    _imageCancel = UploadCancellation();
    try {
      final sent = await widget.controller.api.sendChatImage(
        widget.id,
        key,
        File(photo.path),
        photo.contentType,
        cancellation: _imageCancel,
      );
      if (!mounted) return;
      final follow = _nearBottom,
          alreadyShown = _messages.any(
            (message) => message['id'] == sent['id'],
          );
      ++_generation;
      setState(() {
        _messages = [
          ..._messages.where((message) => message['id'] != sent['id']),
          sent,
        ];
        _imageDraft = null;
        _imageKey = null;
        _sending = false;
        _loading = false;
        if (follow) {
          _newMessages = 0;
        } else if (!alreadyShown) {
          _newMessages++;
        }
      });
      await _photoPicker.delete(photo);
      await _positionMessages(latest: follow);
    } catch (error) {
      if (widget.group && error is ApiException && error.status == 409) {
        await _refreshContext();
      }
      if (mounted) {
        setState(
          () => _error =
              '${errorText(error)} Ảnh đang chờ xác nhận; thử lại sẽ giữ cùng mã yêu cầu.',
        );
      }
    } finally {
      _imageCancel = null;
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _directPeer == null
                ? widget.title
                : value(_directPeer!, 'displayName'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (_directPeer != null)
            Text(
              '${UserRole.values.where((role) => role.wire == _directPeer!['role']).firstOrNull?.label ?? 'Thành viên'} · ${widget.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_directPeer == null && _directContextError != null)
            Text(
              'Chưa tải được thông tin người trao đổi',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        if (_directPeer != null)
          IconButton(
            tooltip: 'Xem hồ sơ người trao đổi',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: _sending
                ? null
                : () async {
                    final blocked = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => UserProfilePage(
                          controller: widget.controller,
                          userId: value(_directPeer!, 'id'),
                          inbox: widget.inbox,
                        ),
                      ),
                    );
                    if (mounted && blocked == true) {
                      setState(() {
                        _readOnly = true;
                        _secretEligible = false;
                        _contextNotice = 'Bạn đã chặn người này. Bỏ chặn trong Hồ sơ & quyền riêng tư để liên hệ lại.';
                      });
                    }
                  },
          ),
        if (_directContextError != null)
          IconButton(
            tooltip: 'Tải lại thông tin hội thoại',
            onPressed: _directContextLoading ? null : _refreshDirectContext,
            icon: const Icon(Icons.person_search_outlined),
          ),
        IconButton(
          tooltip: 'Cập nhật tin nhắn',
          onPressed: _loading || _sending
              ? null
              : () {
                  unawaited(_load());
                  if (!widget.group) unawaited(_refreshDirectContext());
                },
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
                      if (!widget.group && _secretEligible)
                        OpenSecretRoomButton(
                          directId: widget.id,
                          title: widget.title,
                          inbox: widget.inbox,
                        ),
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
                        MessageBox(
                          _readOnly && widget.group
                              ? 'Nhóm đã đóng và chưa có tin nhắn.'
                              : _readOnly
                              ? 'Liên hệ trực tiếp đã bị chặn. Lịch sử đã có vẫn được giữ lại.'
                              : 'Chưa có tin nhắn. Gửi lời chào đầu tiên.',
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
                                if (message['image'] is! Map)
                                  Text(value(message, 'text')),
                                if (message['image'] is Map)
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 256,
                                    ),
                                    child: ApiPhoto(
                                      key: ValueKey(
                                        'chat-image:${widget.id}:${(message['image'] as Map)['id']}',
                                      ),
                                      title: 'Ảnh hội thoại',
                                      viewportBound: true,
                                      load: () =>
                                          widget.controller.api.chatImageBytes(
                                            widget.id,
                                            value(
                                              Map<String, dynamic>.from(
                                                message['image'],
                                              ),
                                              'id',
                                            ),
                                          ),
                                    ),
                                  ),
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
          if (_imageDraft case final photo?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DataCard(
                children: [
                  Text(
                    photo.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Text(
                    'Ảnh trong chat thường được máy chủ xử lý; đây không phải ảnh mã hóa đầu cuối.',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _sending || _readOnly ? null : _sendImage,
                        icon: const Icon(Icons.send),
                        label: const Text('Gửi ảnh'),
                      ),
                      TextButton(
                        onPressed: _sending
                            ? null
                            : () async {
                                setState(() {
                                  _imageDraft = null;
                                  _imageKey = null;
                                });
                                await _photoPicker.delete(photo);
                              },
                        child: const Text('Bỏ ảnh'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Chụp ảnh gửi trong chat thường',
                  onPressed: _sending || _readOnly
                      ? null
                      : () => _chooseImage('captureChatImage'),
                  icon: const Icon(Icons.camera_alt_outlined),
                ),
                IconButton(
                  tooltip: 'Chọn ảnh gửi trong chat thường',
                  onPressed: _sending || _readOnly
                      ? null
                      : () => _chooseImage('pickChatImage'),
                  icon: const Icon(Icons.photo_library_outlined),
                ),
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
