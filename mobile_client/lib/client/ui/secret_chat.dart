import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../inbox.dart';
import '../media.dart';
import '../secret_messaging.dart';
import '../secret_protocol.dart';
import 'components.dart';
import 'event_refresh.dart';
import 'api_photo.dart';
import 'secret_scope.dart';

String secretError(Object error) => error is ApiException
    ? safeErrorMessage(error.message)
          .replaceAll('Phòng', 'Hội thoại')
          .replaceAll('phòng', 'hội thoại')
    : 'Không xác minh được dữ liệu hoặc kho khóa bí mật. Hội thoại đang khóa.';
String fullSafetyCode(String fingerprint) => [
  for (var i = 0; i < fingerprint.length; i += 8)
    fingerprint.substring(
      i,
      i + 8 < fingerprint.length ? i + 8 : fingerprint.length,
    ),
].join(' ');

class SecretDevicesPage extends StatefulWidget {
  const SecretDevicesPage({super.key, required this.messaging});
  final SecretMessaging messaging;
  @override
  State<SecretDevicesPage> createState() => _SecretDevicesPageState();
}

class _SecretDevicesPageState extends State<SecretDevicesPage> {
  final _label = TextEditingController(text: 'Android của tôi');
  List<Json> _devices = [];
  String? _error, _notice;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final devices = await widget.messaging.devices();
      if (mounted) setState(() => _devices = devices);
    } catch (error) {
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _register() async {
    if (_busy || _label.text.trim().length < 2) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đăng ký khóa thiết bị?'),
        content: const Text(
          'Mỗi tài khoản có một thiết bị bí mật hoạt động. Khóa mới không khôi phục lịch sử của thiết bị đã bị thu hồi. Cần so sánh mã an toàn với người kia trước khi gửi tin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Để sau'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Đăng ký khóa'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.messaging.registerDevice(
        label: _label.text,
        allowNewIdentity: true,
      );
      if (mounted) {
        setState(
          () => _notice =
              'Đã đăng ký khóa công khai. Khóa riêng được giữ trên thiết bị.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  Future<void> _revoke(Json device) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thu hồi khóa bí mật?'),
        content: const Text(
          'Thiết bị bị thu hồi không thể tải lịch sử hoặc ảnh bí mật cũ. Không có khôi phục hoặc đồng bộ nhiều thiết bị. Muốn dùng lại phải đăng ký thiết bị và mã an toàn mới.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Thu hồi khóa'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.messaging.revokeDevice(value(device, 'deviceId'));
      if (mounted) setState(() => _notice = 'Đã thu hồi khóa thiết bị.');
    } catch (error) {
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fresh = widget.messaging.session.canEnrollBiometric;
    return Scaffold(
      appBar: AppBar(title: const Text('Khóa chat riêng mã hóa đầu cuối')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SectionTitle(
              'Một thiết bị, khóa riêng của bạn',
              subtitle: 'Chỉ dùng giữa hai tài khoản Nhà sản xuất hoặc Thương lái đã duyệt trong hội thoại trực tiếp. Máy chủ lưu bản mã, không nhận khóa riêng hoặc nội dung tin bí mật.',
            ),
            const MessageBox(
              'Bản này không có khôi phục khóa, đồng bộ nhiều thiết bị hay chuyển tiếp bí mật (forward secrecy). Mất hoặc thu hồi khóa có thể mất lịch sử bí mật.',
            ),
            if (_error != null) MessageBox(_error!, error: true),
            if (_notice != null) MessageBox(_notice!),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            TextFormField(
              controller: _label,
              enabled: !_busy,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Tên thiết bị'),
            ),
            if (!fresh)
              const MessageBox(
                'Đăng nhập lại bằng mật khẩu và mã email hoặc ứng dụng xác thực trong 15 phút để đăng ký hoặc thu hồi khóa.',
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || !fresh ? null : _register,
              icon: const Icon(Icons.key_outlined),
              label: const Text('Đăng ký khóa thiết bị'),
            ),
            const SizedBox(height: 20),
            const SectionTitle('Khóa đã đăng ký'),
            if (!_busy && _devices.isEmpty)
              const Text('Chưa có khóa thiết bị trên máy chủ.'),
            ..._devices.map(
              (device) => DataCard(
                children: [
                  Text(
                    value(device, 'label'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('Phiên bản khóa ${device['version']}'),
                  SelectableText(value(device, 'deviceId')),
                  Text(
                    device['revokedAt'] == null
                        ? 'Đang hoạt động'
                        : 'Đã thu hồi',
                  ),
                  if (device['revokedAt'] == null)
                    OutlinedButton(
                      onPressed: _busy || !fresh ? null : () => _revoke(device),
                      child: const Text('Thu hồi khóa'),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Cập nhật khóa'),
            ),
          ],
        ),
      ),
    );
  }
}

class OpenSecretRoomButton extends StatefulWidget {
  const OpenSecretRoomButton({
    super.key,
    required this.directId,
    required this.title,
    this.inbox,
  });
  final String directId, title;
  final InboxController? inbox;
  @override
  State<OpenSecretRoomButton> createState() => _OpenSecretRoomButtonState();
}

class _OpenSecretRoomButtonState extends State<OpenSecretRoomButton> {
  bool _busy = false;
  String? _error;
  Future<void> _open(SecretMessaging messaging) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await messaging.openDirect(widget.directId);
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SecretChatPage(
              messaging: messaging,
              id: id,
              title: widget.title,
              inbox: widget.inbox,
              directConversationId: widget.directId,
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final messaging = SecretScope.maybeOf(context);
    if (messaging == null || messaging.session.user?.canSell != true) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _open(messaging),
          icon: const Icon(Icons.enhanced_encryption_outlined),
          label: Text(
            _busy ? 'Đang kiểm tra khóa…' : 'Chat riêng mã hóa đầu cuối',
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Phần chat này được mã hóa cho hai thiết bị. Lịch sử chat thường trước đây vẫn nằm ở luồng thường.',
          ),
        ),
        if (_error != null)
          MessageBox(
            _error!,
            error: true,
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SecretDevicesPage(messaging: messaging),
                ),
              ),
              child: const Text('Quản lý khóa thiết bị'),
            ),
          ),
      ],
    );
  }
}

class SecretInboxPage extends StatelessWidget {
  const SecretInboxPage({super.key, required this.messaging});
  final SecretMessaging messaging;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Chat riêng mã hóa đầu cuối')),
    body: SafeArea(
      child: LiveApiList(
        api: messaging.api,
        path: '/secret/conversations?limit=20',
        targets: const {
          'SecretMessageCreated',
          'SecretConversationCreated',
          'SecretDeviceChanged',
        },
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionTitle(
              'Tin và ảnh mã hóa đầu cuối',
              subtitle: 'Mở chat riêng từ một hội thoại trực tiếp. Lịch sử chat thường không tự chuyển sang mã hóa đầu cuối.',
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SecretDevicesPage(messaging: messaging),
                ),
              ),
              icon: const Icon(Icons.key_outlined),
              label: const Text('Khóa thiết bị'),
            ),
          ],
        ),
        empty: 'Chưa có chat riêng mã hóa đầu cuối. Mở hội thoại trực tiếp với một Nhà sản xuất hoặc Thương lái đủ điều kiện để bắt đầu.',
        itemBuilder: (row) => DataCard(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SecretChatPage(
                messaging: messaging,
                id: value(row, 'id'),
                title: 'Chat riêng mã hóa đầu cuối',
              ),
            ),
          ),
          children: [
            const Icon(Icons.enhanced_encryption_outlined),
            const SizedBox(height: 8),
            Text(
              'Chat riêng ${value(row, 'id').length > 8 ? value(row, 'id').substring(0, 8) : value(row, 'id')}',
            ),
            Text('Cập nhật ${displayTime(row['lastActivityAt'])}'),
          ],
        ),
      ),
    ),
  );
}

class SecretChatPage extends StatefulWidget {
  const SecretChatPage({
    super.key,
    required this.messaging,
    required this.id,
    required this.title,
    this.picker,
    this.inbox,
    this.directConversationId,
  });
  final SecretMessaging messaging;
  final String id, title;
  final NativeMediaPicker? picker;
  final InboxController? inbox;
  final String? directConversationId;
  @override
  State<SecretChatPage> createState() => _SecretChatPageState();
}

class _SecretChatPageState extends State<SecretChatPage>
    with WidgetsBindingObserver {
  final _text = TextEditingController(), _scroll = ScrollController();
  late final _picker = widget.picker ?? NativeMediaPicker();
  SecretRoom? _room;
  List<SecretMessage> _messages = [];
  int? _before;
  bool _loading = false, _pending = false, _busy = false, _compared = false;
  int _newMessages = 0;
  String? _error;
  PickedMedia? _photo;
  PreparedSecretMessage? _prepared;
  final _verifiedImages = <String>{};
  int _lastReadSequence = 0;
  bool _acknowledging = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.messaging.addListener(_locked);
    _scroll.addListener(_readVisibleLatest);
    _load();
  }

  void _readVisibleLatest() {
    if (!_loading && _scroll.hasClients && _scroll.position.pixels < 80) {
      unawaited(_acknowledgeLatest());
    }
  }

  Future<void> _acknowledgeLatest() async {
    final directId = widget.directConversationId;
    if (!mounted ||
        directId == null ||
        _acknowledging ||
        _room?.verified != true ||
        !_scroll.hasClients ||
        _scroll.position.pixels >= 80 ||
        ModalRoute.of(context)?.isCurrent != true ||
        WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed ||
        _messages.isEmpty) {
      return;
    }
    final newest = _messages.last;
    final sequence = newest.metadata['sequence'];
    if (_messages.any(
          (message) => message.packet == null || message.error != null,
        ) ||
        newest.packet?.image != null &&
            !_verifiedImages.contains(newest.packet!.image!.attachmentId) ||
        sequence is! int ||
        sequence <= _lastReadSequence) {
      return;
    }
    _acknowledging = true;
    try {
      if (widget.inbox != null) {
        await widget.inbox!.markRead(directId, lastSecretSequence: sequence);
      } else {
        await widget.messaging.api.post(
          '/conversations/${Uri.encodeComponent(directId)}/read',
          {'lastSecretSequence': sequence},
        );
      }
      if (mounted && _room?.verified == true) _lastReadSequence = sequence;
    } catch (_) {
      // A receipt failure never changes verified content or local key state.
    } finally {
      _acknowledging = false;
    }
  }

  void _locked() {
    if (mounted) {
      final photo = _photo;
      _text.clear();
      setState(() {
        _messages = [];
        _room = null;
        _compared = false;
        _prepared = null;
        _photo = null;
        _newMessages = 0;
        _verifiedImages.clear();
      });
      if (photo != null) unawaited(_picker.delete(photo));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _locked();
    }
  }

  Future<void> _load({bool older = false}) async {
    if (_loading) {
      _pending = true;
      return;
    }
    if (older && _before == null) return;
    final near = !_scroll.hasClients || _scroll.position.pixels < 80,
        oldPixels = _scroll.hasClients ? _scroll.position.pixels : 0.0,
        oldExtent = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    final previousIds = _messages
        .map(
          (m) =>
              '${m.metadata['senderDeviceId']}:${m.metadata['clientMessageId']}',
        )
        .toSet();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.messaging.messages(
        widget.id,
        beforeSequence: older ? _before : null,
      );
      if (!mounted) return;
      setState(() {
        if (_room?.fingerprint != result.room.fingerprint) _compared = false;
        _room = result.room;
        if (!result.room.verified) {
          _messages = [];
          _prepared = null;
        } else {
          final all = <String, SecretMessage>{
            for (final message in _messages)
              '${message.metadata['senderDeviceId']}:${message.metadata['clientMessageId']}':
                  message,
          };
          for (final message in result.messages) {
            all['${message.metadata['senderDeviceId']}:${message.metadata['clientMessageId']}'] =
                message;
          }
          _messages = all.values.toList()
            ..sort(
              (a, b) => (a.metadata['sequence'] as int).compareTo(
                b.metadata['sequence'] as int,
              ),
            );
          if (_messages.length > 200) {
            _messages = _messages.sublist(_messages.length - 200);
          }
        }
        if (older || _before == null) _before = result.nextBefore;
        if (!older && !near) {
          _newMessages += result.messages
              .where(
                (m) => !previousIds.contains(
                  '${m.metadata['senderDeviceId']}:${m.metadata['clientMessageId']}',
                ),
              )
              .length;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (!older && near) {
          _scroll.jumpTo(0);
          unawaited(_acknowledgeLatest());
        } else if (!older) {
          _scroll.jumpTo(
            (oldPixels + _scroll.position.maxScrollExtent - oldExtent).clamp(
              0,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_pending) {
          _pending = false;
          unawaited(_load());
        }
      }
    }
  }

  Future<void> _confirm() async {
    final room = _room;
    if (room == null || !_compared || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.messaging.confirmRoom(widget.id, room.fingerprint);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(String method) async {
    if (_busy || _room?.verified != true) return;
    setState(() => _busy = true);
    PickedMedia? photo;
    try {
      photo = await _picker.pick(method);
      if (photo == null) return;
      if (photo.contentType != 'image/jpeg' || photo.bytes > secretImageLimit) {
        throw const ApiException('Chọn JPEG chuẩn hóa tối đa 5 MiB.');
      }
      if (!mounted) {
        await _picker.delete(photo);
        return;
      }
      final old = _photo;
      setState(() => _photo = photo);
      if (old != null) await _picker.delete(old);
    } catch (error) {
      if (photo != null && photo != _photo) await _picker.delete(photo);
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_busy || _room?.verified != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final photo = _photo;
    try {
      _prepared ??= await widget.messaging.prepare(
        widget.id,
        _text.text,
        photo: photo,
      );
      await widget.messaging.send(_prepared!);
      _prepared = null;
      _text.clear();
      if (mounted) {
        setState(() => _newMessages = 0);
        await _load();
      }
    } catch (error) {
      if (mounted) setState(() => _error = secretError(error));
    } finally {
      if (photo != null) {
        if (_photo == photo) _photo = null;
        await _picker.delete(photo);
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.messaging.removeListener(_locked);
    _text.dispose();
    _scroll.dispose();
    final photo = _photo;
    _photo = null;
    if (photo != null) unawaited(_picker.delete(photo));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room, verified = room?.verified == true;
    return EventRefresh(
      targets: const {'SecretMessageCreated', 'SecretDeviceChanged'},
      matches: (event) =>
          event.target == 'SecretDeviceChanged' ||
          event.data['conversationId'] == widget.id,
      onRefresh: _load,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Chat riêng · Mã hóa đầu cuối'),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Cập nhật chat riêng',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const MessageBox(
                        'Mã hóa đầu cuối cho hội thoại riêng này. Máy chủ vẫn thấy người tham gia, thời gian và dung lượng. Không có khôi phục khóa, nhiều thiết bị hoặc forward secrecy.',
                      ),
                      if (room != null)
                        DataCard(
                          children: [
                            Row(
                              children: [
                                Icon(
                                  verified
                                      ? Icons.verified_user_outlined
                                      : Icons.lock_outline,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    verified
                                        ? 'Đã xác minh mã an toàn'
                                        : room.changed
                                        ? 'Khóa đã đổi · Cần so sánh lại'
                                        : 'So sánh mã an toàn trước khi gửi',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              fullSafetyCode(room.fingerprint),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                height: 1.6,
                              ),
                            ),
                            if (!verified) ...[
                              const SizedBox(height: 12),
                              const Text(
                                'Hai người phải so sánh toàn bộ 64 ký tự qua một kênh khác. Không xác nhận nếu khác nhau.',
                              ),
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: _compared,
                                onChanged: _busy
                                    ? null
                                    : (v) =>
                                          setState(() => _compared = v == true),
                                title: const Text(
                                  'Tôi đã so sánh toàn bộ mã với người kia qua kênh khác',
                                ),
                              ),
                              FilledButton(
                                onPressed: _busy || !_compared
                                    ? null
                                    : _confirm,
                                child: const Text('Xác nhận mã đã khớp'),
                              ),
                            ],
                          ],
                        ),
                      if (_error != null) MessageBox(_error!, error: true),
                      if (_loading) const LinearProgressIndicator(),
                      if (verified && _before != null && _messages.length < 200)
                        OutlinedButton(
                          onPressed: _loading ? null : () => _load(older: true),
                          child: const Text('Xem tin mã hóa cũ hơn'),
                        ),
                      if (verified && !_loading && _messages.isEmpty)
                        const Text(
                          'Đã xác minh hai thiết bị. Chưa có tin nhắn mã hóa trong cuộc trò chuyện này.',
                        ),
                      ..._messages.map(
                        (message) => Align(
                          alignment:
                              message.metadata['senderUserId'] ==
                                  widget.messaging.userId
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            padding: const EdgeInsets.all(14),
                            constraints: const BoxConstraints(maxWidth: 480),
                            decoration: BoxDecoration(
                              color:
                                  message.metadata['senderUserId'] ==
                                      widget.messaging.userId
                                  ? const Color(0xFFE1F1E7)
                                  : const Color(0xFFF0F4F8),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  message.metadata['senderUserId'] ==
                                          widget.messaging.userId
                                      ? 'Bạn'
                                      : 'Người kia đã xác minh',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (message.packet?.text.isNotEmpty == true)
                                  Text(message.packet!.text),
                                if (message.error != null) Text(message.error!),
                                if (message.packet?.image case final image?)
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 256,
                                    ),
                                    child: ApiPhoto(
                                      key: ValueKey(
                                        'secret-photo:${image.attachmentId}:${image.cipherHash}',
                                      ),
                                      title: 'Ảnh mã hóa đầu cuối',
                                      viewportBound: true,
                                      secret: true,
                                      load: () async {
                                        final fingerprint = _room?.fingerprint;
                                        final bytes = await widget.messaging
                                            .image(widget.id, image);
                                        if (mounted &&
                                            _room?.verified == true &&
                                            _room?.fingerprint == fingerprint) {
                                          _verifiedImages.add(
                                            image.attachmentId,
                                          );
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                                if (mounted) {
                                                  unawaited(
                                                    _acknowledgeLatest(),
                                                  );
                                                }
                                              });
                                        }
                                        return bytes;
                                      },
                                    ),
                                  ),
                                const SizedBox(height: 6),
                                Text(
                                  displayTime(message.metadata['createdAt']),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_newMessages > 0)
                TextButton.icon(
                  onPressed: () {
                    _scroll.animateTo(
                      0,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                    );
                    setState(() => _newMessages = 0);
                  },
                  icon: const Icon(Icons.arrow_downward),
                  label: Text('$_newMessages tin nhắn mã hóa mới'),
                ),
              if (_prepared != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: MessageBox(
                    'Bản mã đang chờ gửi. Thử lại dùng đúng mã yêu cầu; không tự gửi sang chat thường.',
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _prepared = null),
                      child: const Text('Bỏ bản mã đang chờ'),
                    ),
                  ),
                ),
              if (_photo case final photo?)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.image_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          photo.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Bỏ ảnh bí mật',
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _photo = null);
                                await _picker.delete(photo);
                              },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Đang kiểm tra khóa, mã hóa hoặc gửi…'),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Chụp ảnh bí mật',
                      onPressed: _busy || !verified || _prepared != null
                          ? null
                          : () => _choose('captureChatImage'),
                      icon: const Icon(Icons.camera_alt_outlined),
                    ),
                    IconButton(
                      tooltip: 'Chọn ảnh bí mật',
                      onPressed: _busy || !verified || _prepared != null
                          ? null
                          : () => _choose('pickChatImage'),
                      icon: const Icon(Icons.photo_library_outlined),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _text,
                        enabled: !_busy && verified && _prepared == null,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 2000,
                        decoration: const InputDecoration(
                          labelText: 'Tin nhắn mã hóa đầu cuối',
                          counterText: '',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Gửi tin nhắn mã hóa đầu cuối',
                      onPressed: _busy || !verified ? null : _send,
                      icon: const Icon(Icons.send),
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
