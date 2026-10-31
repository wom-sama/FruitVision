import 'package:flutter/material.dart';

import '../inbox.dart';
import '../session.dart';
import '../models.dart';
import 'chat.dart';
import 'components.dart';
import 'profile.dart';

class NewMessagePage extends StatefulWidget {
  const NewMessagePage({super.key, required this.controller, this.inbox});
  final SessionController controller;
  final InboxController? inbox;
  @override
  State<NewMessagePage> createState() => _NewMessagePageState();
}

class _NewMessagePageState extends State<NewMessagePage> {
  final _search = TextEditingController();
  List<Json> _contacts = [];
  String? _error, _opening;
  bool _loading = false;
  int _generation = 0;
  bool get _allowed =>
      widget.controller.user?.isApproved == true &&
      widget.controller.user?.isActive == true &&
      !widget.controller.endingSession;
  @override
  void initState() {
    super.initState();
    if (_allowed) _load();
  }

  Future<void> _load() async {
    if (!_allowed || _opening != null) return;
    final generation = ++_generation,
        origin = widget.controller.api.baseUrl,
        user = widget.controller.user?.id;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.controller.api.get(
        '/contacts?limit=20&search=${Uri.encodeQueryComponent(_search.text.trim())}',
      );
      if (mounted &&
          _allowed &&
          generation == _generation &&
          origin == widget.controller.api.baseUrl &&
          user == widget.controller.user?.id) {
        setState(() => _contacts = rows(result));
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(Json contact) async {
    if (!_allowed || _opening != null) return;
    final origin = widget.controller.api.baseUrl,
        user = widget.controller.user?.id;
    setState(() {
      _opening = value(contact, 'id');
      _error = null;
    });
    try {
      final conversation = await widget.controller.api.post(
        '/conversations/direct',
        {'userId': value(contact, 'id')},
      );
      if (!mounted ||
          !_allowed ||
          origin != widget.controller.api.baseUrl ||
          user != widget.controller.user?.id) {
        return;
      }
      final id = value(conversation, 'id');
      if (id.isEmpty || conversation['kind'] != 'Direct') {
        throw const FormatException();
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            controller: widget.controller,
            id: id,
            title: value(contact, 'displayName'),
            inbox: widget.inbox,
          ),
        ),
      );
      if (mounted) await widget.inbox?.refresh();
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Tin nhắn mới')),
    body: SafeArea(
      child: !_allowed
          ? const Center(child: Text('Tài khoản cần được duyệt để trao đổi.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Chọn người nhận để mở hội thoại trực tiếp. Đây là chat thường; mã hóa đầu cuối là lựa chọn riêng trong hội thoại đủ điều kiện.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _search,
                  enabled: _opening == null,
                  maxLength: 80,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    labelText: 'Tìm theo tên',
                    suffixIcon: IconButton(
                      tooltip: 'Tìm người nhận',
                      onPressed: _loading || _opening != null ? null : _load,
                      icon: const Icon(Icons.search),
                    ),
                  ),
                ),
                if (_loading || _opening != null)
                  const LinearProgressIndicator(),
                if (_error != null) MessageBox(_error!, error: true),
                if (!_loading && _contacts.isEmpty)
                  const Text('Chưa tìm thấy người nhận phù hợp.'),
                for (final contact in _contacts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      child: Icon(Icons.person_outline),
                    ),
                    title: Text(value(contact, 'displayName')),
                    subtitle: Text(
                      UserRole.values
                              .where((role) => role.wire == contact['role'])
                              .firstOrNull
                              ?.label ??
                          'Thành viên',
                    ),
                    trailing: IconButton(
                      tooltip: 'Xem hồ sơ ${value(contact, 'displayName')}',
                      icon: const Icon(Icons.account_circle_outlined),
                      onPressed: _opening != null
                          ? null
                          : () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<bool>(
                                  builder: (_) => UserProfilePage(
                                    controller: widget.controller,
                                    userId: value(contact, 'id'),
                                    inbox: widget.inbox,
                                  ),
                                ),
                              );
                              if (mounted) await _load();
                            },
                    ),
                    onTap: _opening != null ? null : () => _open(contact),
                  ),
              ],
            ),
    ),
  );
}
