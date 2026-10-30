import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import 'chat.dart';
import 'components.dart';
import 'event_refresh.dart';
import 'posts.dart';
import 'visuals.dart';

class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  final _list = GlobalKey<ApiListState>();
  late final _region = TextEditingController(
    text: widget.controller.user!.region,
  );
  late String _regionQuery = widget.controller.user!.region;
  String? _product, _catalogError;
  List<Json> _products = [];
  @override
  void initState() {
    super.initState();
    _catalog();
  }

  @override
  void dispose() {
    _region.dispose();
    super.dispose();
  }

  Future<void> _catalog() async {
    try {
      final response = await widget.controller.api.get('/catalog/products');
      if (mounted) {
        setState(() {
          _products = rows(response);
          _catalogError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _catalogError = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = Uri(
      queryParameters: {
        'limit': '20',
        if (_regionQuery.isNotEmpty) 'region': _regionQuery,
        'productCode': ?_product,
      },
    ).query;
    return Scaffold(
      appBar: AppBar(title: const Text('Nhóm cộng đồng')),
      body: SafeArea(
        child: LiveApiList(
          listKey: _list,
          api: widget.controller.api,
          path: '/community/groups?$query',
          targets: const {'CommunityChanged', 'ConversationCreated'},
          empty: 'Chưa có nhóm phù hợp. Thử bộ lọc khác hoặc tạo nhóm cho khu vực của bạn.',
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle(
                'Kết nối cùng khu vực',
                subtitle: 'Nhóm mở cho tài khoản đã duyệt. Tham gia nhóm để trò chuyện với các thành viên.',
              ),
              if (_catalogError != null) ...[
                MessageBox(
                  'Danh mục nông sản: $_catalogError',
                  error: true,
                  child: TextButton(
                    onPressed: _catalog,
                    child: const Text('Tải lại danh mục'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          GroupCreatePage(controller: widget.controller),
                    ),
                  );
                  if (mounted) _list.currentState?.reload();
                },
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('Tạo nhóm'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _region,
                maxLength: 120,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  labelText: 'Khu vực',
                  hintText: 'Để trống để xem tất cả',
                ),
                onSubmitted: (_) =>
                    setState(() => _regionQuery = _region.text.trim()),
              ),
              DropdownButtonFormField<String>(
                initialValue: _product ?? 'all',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Nông sản'),
                items: [
                  const DropdownMenuItem(
                    value: 'all',
                    child: Text('Tất cả nông sản'),
                  ),
                  ..._products.map(
                    (product) => DropdownMenuItem(
                      value: value(product, 'code'),
                      child: Text(value(product, 'name')),
                    ),
                  ),
                ],
                onChanged: (product) => setState(() {
                  _product = product == 'all' ? null : product;
                  _regionQuery = _region.text.trim();
                }),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _regionQuery = _region.text.trim()),
                icon: const Icon(Icons.search),
                label: const Text('Lọc nhóm'),
              ),
              const SizedBox(height: 16),
            ],
          ),
          itemBuilder: (group) => DataCard(
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GroupDetailPage(
                    controller: widget.controller,
                    id: value(group, 'id'),
                  ),
                ),
              );
              if (mounted) _list.currentState?.reload();
            },
            children: [
              Row(
                children: [
                  const IconBadge(Icons.groups_outlined, color: blue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      value(group, 'title'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '${value(group, 'region')} · ${value(group, 'memberCount', '—')} thành viên',
              ),
              if (value(group, 'productCode').isNotEmpty)
                Text(productLabel(value(group, 'productCode'))),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  StatusPill(group['isOpen'] == false ? 'Đã đóng' : 'Đang mở'),
                  if (group['isMember'] == true)
                    const StatusPill('Đã tham gia', color: blue),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GroupDetailPage extends StatefulWidget {
  const GroupDetailPage({
    super.key,
    required this.controller,
    required this.id,
  });
  final SessionController controller;
  final String id;
  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> {
  Json? _group;
  bool _loading = true, _busy = false, _pending = false;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) {
      _pending = true;
      return;
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final group = await widget.controller.api.get(
        '/community/groups/${Uri.encodeComponent(widget.id)}',
      );
      if (!mounted || generation != _generation) return;
      if (group['kind'] != 'Group') {
        throw const ApiException('Không tìm thấy nhóm cộng đồng.');
      }
      setState(() {
        _group = group;
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _chat() async {
    final group = _group;
    if (group == null || group['isMember'] != true) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          controller: widget.controller,
          id: widget.id,
          title: value(group, 'title'),
          group: true,
          readOnly: group['isOpen'] == false,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _act(String action) async {
    if (_busy) return;
    ++_generation;
    setState(() {
      _busy = true;
      _loading = false;
      _error = null;
    });
    try {
      await widget.controller.api.post(
        '/community/groups/${Uri.encodeComponent(widget.id)}/$action',
        {},
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
      if (mounted && action == 'join' && _group?['isMember'] == true) {
        await _chat();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    } finally {
      if (mounted && _pending) {
        _pending = false;
        await _load();
      }
    }
  }

  Future<void> _close() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Đóng nhóm cộng đồng?'),
        content: const Text('Nhóm sẽ không còn mở để thành viên mới tham gia.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Đóng nhóm'),
          ),
        ],
      ),
    );
    if (mounted && confirm == true) await _act('close');
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final open = group?['isOpen'] == true;
    final member = group?['isMember'] == true;
    final owner =
        group?['ownerId'] == widget.controller.user?.id ||
        group?['currentRole'] == 'Owner';
    return EventRefresh(
      targets: const {'CommunityChanged'},
      matches: (event) =>
          event.data['id'] == widget.id ||
          event.data['groupId'] == widget.id ||
          event.data['conversationId'] == widget.id,
      onRefresh: _load,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chi tiết nhóm'),
          actions: [
            IconButton(
              tooltip: 'Cập nhật nhóm',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) ...[
                  MessageBox(_error!, error: true),
                  const SizedBox(height: 12),
                ],
                if (group != null) ...[
                  const IconBadge(Icons.groups_outlined, color: blue, size: 56),
                  const SizedBox(height: 16),
                  SectionTitle(
                    value(group, 'title'),
                    subtitle: value(group, 'region'),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusPill(open ? 'Đang mở' : 'Đã đóng'),
                      StatusPill(
                        '${value(group, 'memberCount', '—')} thành viên',
                        color: blue,
                      ),
                      if (owner) const StatusPill('Chủ nhóm'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (value(group, 'productCode').isNotEmpty)
                    Text(
                      'Nông sản: ${productLabel(value(group, 'productCode'))}',
                    ),
                  Text('Tạo lúc ${displayTime(group['createdAt'])}'),
                  const SizedBox(height: 24),
                  if (member)
                    FilledButton.icon(
                      onPressed: _busy ? null : _chat,
                      icon: const Icon(Icons.forum_outlined),
                      label: const Text('Mở hội thoại nhóm'),
                    )
                  else if (open)
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _act('join'),
                      icon: const Icon(Icons.group_add_outlined),
                      label: const Text('Tham gia và trò chuyện'),
                    ),
                  if (member) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _busy || (owner && open)
                          ? null
                          : () => _act('leave'),
                      child: const Text('Rời nhóm'),
                    ),
                  ],
                  if (owner && open)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Chủ nhóm cần đóng nhóm trước khi rời.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  if (open && (owner || widget.controller.user!.isAdmin)) ...[
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: _busy ? null : _close,
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Đóng nhóm'),
                    ),
                  ],
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GroupCreatePage extends StatefulWidget {
  const GroupCreatePage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<GroupCreatePage> createState() => _GroupCreatePageState();
}

class _GroupCreatePageState extends State<GroupCreatePage> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  late final _region = TextEditingController(
    text: widget.controller.user!.region,
  );
  String? _product, _error, _catalogError;
  List<Json> _products = [];
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _catalog();
  }

  @override
  void dispose() {
    _title.dispose();
    _region.dispose();
    super.dispose();
  }

  Future<void> _catalog() async {
    try {
      final response = await widget.controller.api.get('/catalog/products');
      if (mounted) {
        setState(() {
          _products = rows(response);
          _catalogError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _catalogError = errorText(e));
    }
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final group = await widget.controller.api.post('/community/groups', {
        'title': _title.text.trim(),
        'region': _region.text.trim(),
        if (_product != null) 'productCode': _product,
      });
      final id = value(group, 'id');
      if (id.isEmpty) {
        throw const ApiException(
          'Chưa nhận được mã nhóm. Kiểm tra danh sách trước khi tạo lại.',
        );
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              GroupDetailPage(controller: widget.controller, id: id),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Tạo nhóm')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle(
                'Nhóm cộng đồng mới',
                subtitle:
                    'Kết nối tài khoản đã duyệt theo khu vực hoặc nông sản.',
              ),
              if (_catalogError != null) ...[
                MessageBox(
                  'Chưa tải được danh mục nông sản: $_catalogError. Bạn vẫn có thể tạo nhóm không giới hạn nông sản.',
                  child: TextButton(
                    onPressed: _catalog,
                    child: const Text('Tải lại danh mục'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                MessageBox(_error!, error: true),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _title,
                enabled: !_busy,
                maxLength: 160,
                decoration: const InputDecoration(labelText: 'Tên nhóm'),
                validator: (value) => requiredText(value, min: 5),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _region,
                enabled: !_busy,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Khu vực'),
                validator: requiredText,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: 'all',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Nông sản (tùy chọn)',
                ),
                items: [
                  const DropdownMenuItem(
                    value: 'all',
                    child: Text('Không giới hạn nông sản'),
                  ),
                  ..._products.map(
                    (product) => DropdownMenuItem(
                      value: value(product, 'code'),
                      child: Text(value(product, 'name')),
                    ),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(
                        () => _product = value == 'all' ? null : value,
                      ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _create,
                child: Text(_busy ? 'Đang tạo…' : 'Tạo nhóm cộng đồng'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
