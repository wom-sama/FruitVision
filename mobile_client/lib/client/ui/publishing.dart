import 'package:flutter/material.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../api.dart';
import '../session.dart';
import '../media.dart';
import 'components.dart';
import 'event_refresh.dart';
import 'location_picker.dart';
import 'moderation.dart';
import 'api_photo.dart';
import 'chat.dart';
import 'article_engagement.dart';

String businessPlaceLabel(UserRole role) =>
    role == UserRole.producer ? 'Cơ sở sản xuất' : 'Cơ sở kinh doanh';

class ArticlesPage extends StatefulWidget {
  const ArticlesPage({
    super.key,
    required this.controller,
    this.embedded = false,
    this.header,
    this.lane = 'Community',
  });
  final SessionController controller;
  final bool embedded;
  final Widget? header;
  final String lane;
  @override
  State<ArticlesPage> createState() => _ArticlesPageState();
}

class _ArticlesPageState extends State<ArticlesPage> {
  bool _mine = false;
  final _list = GlobalKey<ApiListState>();
  Future<void> _edit([Json? row]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PublicationEditor(
          controller: widget.controller,
          article: true,
          initial: row,
        ),
      ),
    );
    _list.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final canWrite =
        widget.controller.user!.isApproved &&
        (widget.lane == 'Professional'
            ? widget.controller.user!.canSell
            : widget.controller.user!.role == UserRole.consumer);
    final body = SafeArea(
      child: LiveApiList(
        listKey: _list,
        api: widget.controller.api,
        path:
            '${_mine ? '/articles/mine' : '/articles'}?limit=20&lane=${widget.lane}',
        targets: const {'ArticleChanged', 'PublishedArticleChanged'},
        empty: _mine
            ? 'Bạn chưa có bài viết cộng đồng.'
            : 'Chưa có bài viết được công bố.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.header != null) widget.header!,
            SectionTitle(
              widget.lane == 'Professional'
                  ? 'Chuyên môn về xoài'
                  : 'Chia sẻ cùng cộng đồng',
              subtitle: widget.lane == 'Professional'
                  ? 'Kinh nghiệm từ Nhà sản xuất và Thương lái đã duyệt. Bài viết gắn với cơ sở đã duyệt và cần được kiểm duyệt.'
                  : 'Kinh nghiệm và câu chuyện về xoài. Bài viết và ảnh cần được quản trị xét duyệt trước khi công bố.',
            ),
            if (!widget.controller.user!.isAdmin) ...[
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Công khai'),
                    selected: !_mine,
                    onSelected: (_) => setState(() => _mine = false),
                  ),
                  ChoiceChip(
                    label: const Text('Bài của tôi'),
                    selected: _mine,
                    onSelected: (_) => setState(() => _mine = true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (canWrite)
                FilledButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(
                    widget.lane == 'Professional'
                        ? 'Viết bài chuyên môn'
                        : 'Viết bài cộng đồng',
                  ),
                ),
            ],
            const SizedBox(height: 16),
          ],
        ),
        itemBuilder: (row) => DataCard(
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ArticlePage(
                  controller: widget.controller,
                  id: value(row, 'id'),
                ),
              ),
            );
            _list.currentState?.reload();
          },
          children: [
            if (row['image'] is Map)
              ApiPhoto(
                key: ValueKey('${row['id']}:${(row['image'] as Map)['id']}'),
                load: () =>
                    widget.controller.api.articleImageBytes(value(row, 'id')),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.article_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    value(row, 'title'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value(row, 'body'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            if (_mine) Text(applicationStatus(row['status'])),
            Text(
              '${row['author'] is Map ? (row['author'] as Map)['displayName'] ?? '' : ''} · ${displayTime(row['createdAt'])}',
            ),
          ],
        ),
      ),
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(
              title: Text(
                widget.lane == 'Professional'
                    ? 'Bài chuyên môn về xoài'
                    : 'Bài viết cộng đồng',
              ),
            ),
            body: body,
          );
  }
}

class ArticlePage extends StatefulWidget {
  const ArticlePage({super.key, required this.controller, required this.id});
  final SessionController controller;
  final String id;
  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage> {
  Json? _data;
  String? _error;
  bool _busy = false;
  int _loadGeneration = 0;
  String get path => '/articles/${Uri.encodeComponent(widget.id)}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final data = await widget.controller.api.get(path);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = errorText(e));
      }
    }
  }

  Future<void> _withdraw() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final data = await widget.controller.api.post('$path/withdraw', {
        'expectedRevision': _data!['revision'],
      });
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (e is ApiException && e.status == 409) await _load();
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _contact() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final conversation = await widget.controller.api.post(
        '$path/conversations',
        {},
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            controller: widget.controller,
            id: value(conversation, 'id'),
            title: value(conversation, 'title'),
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data,
        author = data?['author'] is Map
            ? Map<String, dynamic>.from(data!['author'])
            : <String, dynamic>{};
    final own = author['id'] == widget.controller.user!.id;
    return EventRefresh(
      targets: const {'ArticleChanged', 'PublishedArticleChanged'},
      matches: (event) => event.data['id'] == widget.id,
      onRefresh: _load,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            data?['audienceLane'] == 'Professional'
                ? 'Bài chuyên môn'
                : 'Bài viết cộng đồng',
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null) MessageBox(_error!, error: true),
              if (data == null && _error == null)
                const LinearProgressIndicator(),
              if (data != null) ...[
                SectionTitle(value(data, 'title')),
                Text(
                  '${value(author, 'displayName')} · ${displayTime(data['createdAt'])}',
                ),
                const SizedBox(height: 20),
                Text(value(data, 'body')),
                if (data['image'] is Map)
                  ApiPhoto(
                    key: ValueKey(
                      '${data['id']}:${(data['image'] as Map)['id']}',
                    ),
                    load: () =>
                        widget.controller.api.articleImageBytes(widget.id),
                  ),
                const SizedBox(height: 16),
                Text(applicationStatus(data['status'])),
                if (value(data, 'reviewReason').isNotEmpty)
                  MessageBox(value(data, 'reviewReason')),
                if (data['status'] == 'Published')
                  ArticleEngagement(
                    controller: widget.controller,
                    articleId: widget.id,
                  ),
                if (!own &&
                    !widget.controller.user!.isAdmin &&
                    widget.controller.user!.isApproved &&
                    data['status'] == 'Published')
                  FilledButton.icon(
                    onPressed: _busy ? null : _contact,
                    icon: const Icon(Icons.forum_outlined),
                    label: const Text('Trao đổi với tác giả'),
                  ),
                if (own && !widget.controller.user!.isAdmin) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => PublicationEditor(
                                  controller: widget.controller,
                                  article: true,
                                  initial: data,
                                ),
                              ),
                            );
                            if (mounted) _load();
                          },
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Sửa và gửi xét duyệt lại'),
                  ),
                  if (data['status'] == 'Published')
                    OutlinedButton(
                      onPressed: _busy ? null : _withdraw,
                      child: const Text('Tạm dừng bài viết'),
                    ),
                  OwnPublicationDelete(
                    controller: widget.controller,
                    article: true,
                    data: data,
                    reload: _load,
                    onDeleted: () async {
                      if (mounted) Navigator.of(context).pop(true);
                    },
                  ),
                ],
              ],
              TextButton.icon(
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Cập nhật bài viết'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BranchesPage extends StatefulWidget {
  const BranchesPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<BranchesPage> createState() => _BranchesPageState();
}

class _BranchesPageState extends State<BranchesPage> {
  final _list = GlobalKey<ApiListState>();
  Future<void> _edit([Json? initial]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PublicationEditor(
          controller: widget.controller,
          article: false,
          initial: initial,
        ),
      ),
    );
    _list.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(businessPlaceLabel(widget.controller.user!.role)),
    ),
    body: SafeArea(
      child: LiveApiList(
        listKey: _list,
        api: widget.controller.api,
        path: '/branches/mine?limit=20',
        targets: const {'BranchChanged', 'ApprovedBranchChanged'},
        empty: 'Bạn chưa đăng ký cơ sở.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              businessPlaceLabel(widget.controller.user!.role),
              subtitle: 'Đăng ký địa điểm hoạt động của bạn để quản trị xét duyệt. Thay đổi thông tin sẽ cần xét duyệt lại.',
            ),
            FilledButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.add_business_outlined),
              label: Text(
                'Đăng ký ${businessPlaceLabel(widget.controller.user!.role).toLowerCase()}',
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
        itemBuilder: (row) => DataCard(
          children: [
            Text(
              value(row, 'name'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(applicationStatus(row['status'])),
            Text(value(row, 'region')),
            Text(value(row, 'street')),
            Text(value(row, 'phone')),
            if (value(row, 'reviewReason').isNotEmpty)
              MessageBox(value(row, 'reviewReason')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _edit(row),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Sửa thông tin cơ sở'),
            ),
            OwnPublicationDelete(
              controller: widget.controller,
              article: false,
              data: row,
              reload: () async {
                await _list.currentState?.reload();
              },
              onDeleted: () async {
                await _list.currentState?.reload();
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class OwnPublicationDelete extends StatefulWidget {
  const OwnPublicationDelete({
    super.key,
    required this.controller,
    required this.article,
    required this.data,
    required this.reload,
    required this.onDeleted,
  });
  final SessionController controller;
  final bool article;
  final Json data;
  final Future<void> Function() reload, onDeleted;
  @override
  State<OwnPublicationDelete> createState() => _OwnPublicationDeleteState();
}

class _OwnPublicationDeleteState extends State<OwnPublicationDelete> {
  bool _busy = false, _deleting = false;
  String? _error;
  bool get _own {
    final owner = widget.data[widget.article ? 'author' : 'owner'];
    return owner is Map &&
        owner['id'] == widget.controller.user?.id &&
        widget.controller.user?.isAdmin == false &&
        !widget.controller.endingSession;
  }

  Future<void> _delete() async {
    if (!_own || _busy || widget.data['revision'] is! int) return;
    final revision = widget.data['revision'],
        origin = widget.controller.api.baseUrl,
        ownerId = widget.controller.user?.id;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.article ? 'Xóa bài viết?' : 'Xóa cơ sở?'),
          content: Text(
            widget.article
                ? 'Bài viết này sẽ được gỡ khỏi ứng dụng. Bạn có muốn tiếp tục?'
                : 'Cơ sở này sẽ được gỡ khỏi ứng dụng. Máy chủ sẽ từ chối nếu còn tin kinh doanh liên kết chưa xóa.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Giữ lại'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xác nhận xóa'),
            ),
          ],
        ),
      );
      if (!mounted ||
          confirmed != true ||
          !_own ||
          origin != widget.controller.api.baseUrl ||
          ownerId != widget.controller.user?.id) {
        return;
      }
      setState(() => _deleting = true);
      await widget.controller.api.delete(
        '/${widget.article ? 'articles' : 'branches'}/${Uri.encodeComponent(value(widget.data, 'id'))}?expectedRevision=$revision',
      );
      if (mounted) await widget.onDeleted();
    } catch (error) {
      if (error is ApiException && error.status == 409) {
        await widget.reload();
      }
      if (mounted) {
        setState(
          () => _error = error is ApiException && error.status == 409
              ? 'Chưa thể xóa. Đã tải lại dữ liệu; hãy kiểm tra phiên bản mới hoặc các tin đang liên kết trước khi thử lại.'
              : errorText(error),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _deleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => !_own
      ? const SizedBox.shrink()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) MessageBox(_error!, error: true),
            TextButton.icon(
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              label: Text(widget.article ? 'Xóa bài viết' : 'Xóa cơ sở'),
            ),
            if (_deleting) const LinearProgressIndicator(),
          ],
        );
}

class PublicationEditor extends StatefulWidget {
  const PublicationEditor({
    super.key,
    required this.controller,
    required this.article,
    this.initial,
    this.picker,
  });
  final SessionController controller;
  final bool article;
  final Json? initial;
  final NativeMediaPicker? picker;
  @override
  State<PublicationEditor> createState() => _PublicationEditorState();
}

class _PublicationEditorState extends State<PublicationEditor> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(
    text: value(widget.initial ?? {}, widget.article ? 'title' : 'name'),
  );
  late final _body = TextEditingController(
    text: value(widget.initial ?? {}, widget.article ? 'body' : 'street'),
  );
  late final _phone = TextEditingController(
    text: value(widget.initial ?? {}, 'phone'),
  );
  LocationSelection? _location;
  bool _busy = false;
  String? _error;
  late final _photoPicker = widget.picker ?? NativeMediaPicker();
  late final bool _professional =
      widget.article &&
      (widget.initial == null
          ? widget.controller.user!.canSell
          : widget.initial!['audienceLane'] == 'Professional');
  late String? _imageId = widget.initial?['image'] is Map
      ? (widget.initial!['image'] as Map)['id'] as String?
      : null;
  PickedMedia? _photo;
  Uint8List? _photoBytes;
  UploadCancellation? _imageCancel;
  List<Json> _branches = [];
  late String? _branchId = widget.initial?['branchId'] as String?;
  bool _loadingBranches = false;
  @override
  void initState() {
    super.initState();
    if (_professional) _loadBranches();
  }

  Future<void> _loadBranches() async {
    setState(() => _loadingBranches = true);
    try {
      final response = await widget.controller.api.get(
        '/branches/mine?limit=50',
      );
      if (mounted) {
        setState(() {
          _branches = rows(response)
              .where((row) => row['status'] == 'Approved')
              .toList();
          if (!_branches.any((row) => row['id'] == _branchId)) {
            _branchId = _branches.length == 1
                ? value(_branches.single, 'id')
                : null;
          }
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _loadingBranches = false);
    }
  }

  Future<void> _choosePhoto(String method) async {
    if (_busy) return;
    setState(() => _busy = true);
    PickedMedia? photo;
    try {
      photo = await _photoPicker.pick(method);
      if (photo == null) return;
      final bytes = await readPreparedChatPhoto(photo);
      if (!mounted) {
        await _photoPicker.delete(photo);
        return;
      }
      final previous = _photo;
      setState(() {
        _photo = photo;
        _photoBytes = bytes;
      });
      if (previous != null) await _photoPicker.delete(previous);
    } catch (error) {
      if (photo != null && photo != _photo) await _photoPicker.delete(photo);
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : errorText(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _phone.dispose();
    _imageCancel?.cancel();
    final photo = _photo;
    _photo = null;
    if (photo != null) unawaited(_photoPicker.delete(photo));
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (!widget.article && _location == null) return;
    if (_professional && _branchId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = <String, dynamic>{
      if (widget.article) ...{
        'title': _title.text.trim(),
        'body': _body.text.trim(),
        'imageId': _imageId,
        if (_professional) 'branchId': _branchId,
      } else ...{
        'name': _title.text.trim(),
        'street': _body.text.trim(),
        'phone': _phone.text.trim(),
        'countryCode': _location!.countryCode,
        'provinceCode': _location!.provinceCode,
      },
      if (widget.initial != null)
        'expectedRevision': widget.initial!['revision'],
    };
    final path = '/${widget.article ? 'articles' : 'branches'}';
    try {
      if (widget.article && _photo != null) {
        _imageCancel = UploadCancellation();
        final uploaded = await widget.controller.api.uploadArticleImage(
          File(_photo!.path),
          _photo!.contentType,
          cancellation: _imageCancel,
        );
        if (!mounted) return;
        _imageId = value(uploaded, 'id');
        if (_imageId!.isEmpty) {
          throw const ApiException('Máy chủ chưa xác nhận ảnh bài viết.');
        }
        body['imageId'] = _imageId;
        final confirmedPhoto = _photo!;
        _photo = null;
        await _photoPicker.delete(confirmedPhoto);
        if (!mounted) return;
      }
      if (widget.initial == null) {
        await widget.controller.api.post(path, body);
      } else {
        await widget.controller.api.put(
          '$path/${Uri.encodeComponent(value(widget.initial!, 'id'))}',
          body,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã gửi nội dung để quản trị xét duyệt.'),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException && e.status == 409
              ? 'Nội dung đã thay đổi. Quay lại để tải phiên bản mới trước khi sửa.'
              : errorText(e),
        );
      }
    } finally {
      _imageCancel = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.article
            ? _professional
                  ? 'Viết bài chuyên môn'
                  : 'Viết bài cộng đồng'
            : 'Đăng ký ${businessPlaceLabel(widget.controller.user!.role).toLowerCase()}',
      ),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MessageBox(
                widget.article
                    ? _professional
                          ? 'Chia sẻ kiến thức về xoài từ cơ sở đã được duyệt. Nội dung và ảnh cần được quản trị xét duyệt trước khi công bố.'
                          : 'Chia sẻ về xoài cùng cộng đồng. Nội dung và ảnh cần được duyệt trước khi công bố.'
                    : 'Chọn địa chỉ cơ sở từ danh mục. Quản trị xét duyệt trước khi cơ sở được dùng trong bài chuyên môn.',
              ),
              const SizedBox(height: 16),
              if (_error != null) MessageBox(_error!, error: true),
              if (_professional) ...[
                if (_loadingBranches) const LinearProgressIndicator(),
                DropdownButtonFormField<String>(
                  key: ValueKey(_branchId),
                  initialValue: _branchId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Cơ sở đã duyệt',
                  ),
                  items: _branches
                      .map(
                        (row) => DropdownMenuItem(
                          value: value(row, 'id'),
                          child: Text(
                            value(row, 'name'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (id) => setState(() => _branchId = id),
                  validator: (id) => id == null ? 'Chọn cơ sở đã duyệt.' : null,
                ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  BranchesPage(controller: widget.controller),
                            ),
                          );
                          if (mounted) _loadBranches();
                        },
                  icon: const Icon(Icons.storefront_outlined),
                  label: const Text('Quản lý cơ sở'),
                ),
              ],
              TextFormField(
                controller: _title,
                enabled: !_busy,
                maxLength: 160,
                decoration: InputDecoration(
                  labelText: widget.article ? 'Tiêu đề bài viết' : 'Tên cơ sở',
                ),
                validator: (v) => requiredText(v, min: widget.article ? 5 : 2),
              ),
              const SizedBox(height: 12),
              if (!widget.article) ...[
                CountryProvincePicker(
                  api: widget.controller.api,
                  countryCode: widget.initial?['countryCode'] as String?,
                  provinceCode: widget.initial?['provinceCode'] as String?,
                  enabled: !_busy,
                  onChanged: (v) => _location = v,
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _body,
                enabled: !_busy,
                minLines: widget.article ? 6 : 2,
                maxLines: widget.article ? 16 : 4,
                maxLength: widget.article ? 5000 : 240,
                decoration: InputDecoration(
                  labelText: widget.article
                      ? 'Nội dung bài viết'
                      : 'Địa chỉ đường / số nhà',
                ),
                validator: (v) => requiredText(v, min: widget.article ? 10 : 5),
              ),
              if (!widget.article) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  maxLength: 30,
                  decoration: const InputDecoration(
                    labelText: 'Số điện thoại liên hệ',
                  ),
                  validator: (v) => requiredText(v, min: 7),
                ),
              ],
              const SizedBox(height: 20),
              if (widget.article) ...[
                if (_photoBytes case final bytes?)
                  Image(
                    image: ResizeImage(
                      MemoryImage(bytes),
                      width: 512,
                      height: 512,
                      policy: ResizeImagePolicy.fit,
                    ),
                    height: 160,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text(
                      'Không hiển thị được ảnh đã chọn. Bạn có thể chọn lại ảnh.',
                    ),
                  ),
                if (_photo != null)
                  Text(
                    _photo!.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (_photo == null && _imageId != null)
                  const Text('Đang giữ ảnh hiện có của bài viết.'),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _choosePhoto('captureChatImage'),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Chụp ảnh bài viết'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _choosePhoto('pickChatImage'),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Chọn ảnh bài viết'),
                    ),
                  ],
                ),
                if (_photo != null || _imageId != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final old = _photo;
                            setState(() {
                              _photo = null;
                              _photoBytes = null;
                              _imageId = null;
                            });
                            if (old != null) await _photoPicker.delete(old);
                          },
                    child: const Text('Bỏ ảnh bài viết'),
                  ),
                const Text(
                  'Ảnh JPEG chuẩn hóa tối đa 5 MiB, được gửi cho máy chủ và kiểm duyệt cùng bài viết.',
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.send_outlined),
                label: Text(_busy ? 'Đang gửi…' : 'Gửi xét duyệt'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
