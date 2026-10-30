import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';

typedef Json = Map<String, dynamic>;

String value(Json row, String key, [String fallback = '']) =>
    row[key]?.toString() ?? fallback;
List<Json> rows(Json response) => (response['items'] as List? ?? [])
    .whereType<Map>()
    .map((row) => Map<String, dynamic>.from(row))
    .toList();
String errorText(Object error) => error is ApiException
    ? error.message
    : 'Không thể kết nối máy chủ. Vui lòng thử lại.';
String displayTime(Object? input) {
  final date = DateTime.tryParse(input?.toString() ?? '')?.toLocal();
  if (date == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} ${two(date.hour)}:${two(date.minute)}';
}

String? requiredText(String? input, {int min = 2}) =>
    (input?.trim().length ?? 0) < min
    ? 'Vui lòng nhập ít nhất $min ký tự.'
    : null;

class MessageBox extends StatelessWidget {
  const MessageBox(this.text, {super.key, this.error = false, this.child});
  final String text;
  final bool error;
  final Widget? child;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: error
            ? Theme.of(context).colorScheme.errorContainer
            : const Color(0xFFE6F1E9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(
              color: error
                  ? Theme.of(context).colorScheme.onErrorContainer
                  : const Color(0xFF17352A),
            ),
          ),
          if (child != null) ...[const SizedBox(height: 8), child!],
        ],
      ),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle, this.action});
  final String title;
  final String? subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle != null) ...[const SizedBox(height: 6), Text(subtitle!)],
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

class DataCard extends StatelessWidget {
  const DataCard({super.key, required this.children, this.onTap});
  final List<Widget> children;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
}

class ApiList extends StatefulWidget {
  const ApiList({
    super.key,
    required this.api,
    required this.path,
    required this.itemBuilder,
    this.header,
    this.empty = 'Chưa có dữ liệu.',
    this.cursor = 'after',
  });
  final ApiClient api;
  final String path, empty, cursor;
  final Widget Function(Json) itemBuilder;
  final Widget? header;
  @override
  State<ApiList> createState() => ApiListState();
}

class ApiListState extends State<ApiList> {
  List<Json> items = [];
  bool loading = true;
  String? error, next;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(ApiList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.api != widget.api) reload();
  }

  Future<void> reload({bool more = false}) async {
    if (more && (loading || next == null)) return;
    final generation = ++_generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final path = more
          ? '${widget.path}${widget.path.contains('?') ? '&' : '?'}${widget.cursor}=${Uri.encodeQueryComponent(next!)}'
          : widget.path;
      final result = await widget.api.get(path);
      if (!mounted || generation != _generation) return;
      setState(() {
        items = more ? [...items, ...rows(result)] : rows(result);
        next = result['next']?.toString();
        loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        loading = false;
        error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: reload,
    child: ListView(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (widget.header != null) widget.header!,
        if (error != null) ...[
          MessageBox(
            error!,
            error: true,
            child: TextButton.icon(
              onPressed: loading ? null : reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!loading && error == null && items.isEmpty)
          MessageBox(widget.empty),
        ...items.map(widget.itemBuilder),
        if (next != null && items.length < 200)
          OutlinedButton(
            onPressed: loading ? null : () => reload(more: true),
            child: const Text('Xem thêm'),
          ),
        if (next != null && items.length >= 200)
          const Text('Kéo xuống để tải lại dữ liệu mới nhất.'),
        const SizedBox(height: 16),
      ],
    ),
  );
}

Future<void> openServerSettings(
  BuildContext context,
  SessionController controller,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ServerSettings(controller: controller),
  ),
);

class ServerSettings extends StatefulWidget {
  const ServerSettings({super.key, required this.controller});
  final SessionController controller;
  @override
  State<ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<ServerSettings> {
  final _form = GlobalKey<FormState>();
  late final _url = TextEditingController(text: widget.controller.api.baseUrl);
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.controller.changeServer(_url.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = widget.controller.error;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Máy chủ')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle(
                'Địa chỉ kết nối',
                subtitle: 'Địa chỉ HTTPS tạm thời có thể đổi khi máy chủ khởi động lại. Đổi máy chủ sẽ kết thúc phiên hiện tại.',
              ),
              TextFormField(
                controller: _url,
                enabled: !_saving,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'URL HTTPS'),
                validator: (text) {
                  final uri = Uri.tryParse(text?.trim() ?? '');
                  return uri == null ||
                          uri.scheme != 'https' ||
                          uri.host.isEmpty ||
                          uri.userInfo.isNotEmpty ||
                          uri.hasQuery ||
                          uri.hasFragment
                      ? 'Nhập URL HTTPS hợp lệ, không có thông tin đăng nhập.'
                      : null;
                },
              ),
              const SizedBox(height: 16),
              if (_error != null) ...[
                MessageBox(_error!, error: true),
                const SizedBox(height: 16),
              ],
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Đang lưu…' : 'Lưu máy chủ'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
