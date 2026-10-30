import 'dart:async';

import 'package:flutter/material.dart';

import '../updates.dart';
import 'components.dart';

class UpdateScope extends InheritedWidget {
  const UpdateScope({super.key, required this.updater, required super.child});
  final UpdateController updater;
  static UpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.updater;
  @override
  bool updateShouldNotify(UpdateScope oldWidget) =>
      updater != oldWidget.updater;
}

/// Runs below MaterialApp's navigator. An unavailable check never blocks sign-in.
class UpdateStartupGate extends StatefulWidget {
  const UpdateStartupGate({
    super.key,
    required this.updater,
    required this.baseUrl,
    required this.child,
  });
  final UpdateController updater;
  final String baseUrl;
  final Widget child;
  @override
  State<UpdateStartupGate> createState() => _UpdateStartupGateState();
}

class _UpdateStartupGateState extends State<UpdateStartupGate> {
  @override
  void initState() {
    super.initState();
    _scheduleCheck();
  }

  @override
  void didUpdateWidget(UpdateStartupGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseUrl != widget.baseUrl) _scheduleCheck();
  }

  void _scheduleCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_check());
    });
  }

  Future<void> _check() async {
    final updater = widget.updater, server = widget.baseUrl;
    await updater.check(server);
    if (!mounted ||
        server != widget.baseUrl ||
        updater.baseUrl != server ||
        updater.mandatory) {
      return;
    }
    final release = updater.release, key = updater.startupKey;
    if (release == null || updater.prompted(key)) return;
    updater.markPrompted(key);
    final update = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Có bản cập nhật ${release.versionName}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Dung lượng ${updateSize(release.sizeBytes)}'),
              if (release.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(release.notes),
              ],
              const SizedBox(height: 12),
              const Text('Android sẽ yêu cầu bạn xác nhận cài đặt.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Để sau'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cập nhật'),
          ),
        ],
      ),
    );
    if (!mounted ||
        update != true ||
        server != widget.baseUrl ||
        updater.baseUrl != server) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => UpdatePage(
          updater: updater,
          baseUrl: server,
          checkOnOpen: false,
          downloadOnOpen: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.updater,
    builder: (context, _) => widget.updater.mandatory
        ? UpdatePage(
            key: ValueKey('required:${widget.baseUrl}'),
            updater: widget.updater,
            baseUrl: widget.baseUrl,
            checkOnOpen: false,
          )
        : widget.child,
  );
}

String updateSize(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';

class UpdatePage extends StatefulWidget {
  const UpdatePage({
    super.key,
    this.updater,
    required this.baseUrl,
    this.checkOnOpen = true,
    this.downloadOnOpen = false,
  });
  final UpdateController? updater;
  final String baseUrl;
  final bool checkOnOpen, downloadOnOpen;
  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> with WidgetsBindingObserver {
  late final UpdateController updater;
  @override
  void initState() {
    super.initState();
    updater = widget.updater ?? createUpdateController();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (widget.checkOnOpen) await updater.check(widget.baseUrl, force: true);
      if (mounted && widget.downloadOnOpen) await updater.download();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(updater.resume());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.updater == null) {
      updater.dispose();
    } else if (updater.candidate != null ||
        updater.status == UpdateStatus.downloading) {
      unawaited(updater.cancelDownload());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: updater,
    builder: (context, _) {
      final release = updater.release,
          status = updater.status,
          candidate = updater.candidate;
      final downloading =
          status == UpdateStatus.downloading ||
          status == UpdateStatus.cancelling;
      return PopScope(
        canPop: !updater.mandatory,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Cập nhật ứng dụng'),
            automaticallyImplyLeading: !updater.mandatory,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Icon(
                  Icons.system_update_alt,
                  size: 56,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  release == null
                      ? 'Phiên bản FruitVision'
                      : 'FruitVision ${release.versionName}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                if (updater.installed != null)
                  Text(
                    'Đang dùng ${updater.installed!.versionName} (${updater.installed!.versionCode})',
                  ),
                if (release != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Bản mới ${release.versionCode} · ${updateSize(release.sizeBytes)}',
                  ),
                  if (updater.mandatory)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: MessageBox(
                        'Cần cập nhật phiên bản này để tiếp tục sử dụng. Bạn có thể hủy tải và thử lại.',
                      ),
                    ),
                  if (release.notes.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const SectionTitle('Có gì mới'),
                    Text(release.notes),
                  ],
                ],
                const SizedBox(height: 20),
                if (status == UpdateStatus.checking) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  const Text('Đang kiểm tra phiên bản…'),
                ],
                if (status == UpdateStatus.unsupported)
                  const MessageBox(
                    'Cài đặt APK trong ứng dụng chỉ có trên Android. Thiết bị này không hỗ trợ luồng cài đặt.',
                  ),
                if (status == UpdateStatus.unavailable)
                  const MessageBox(
                    'Máy chủ chưa công bố gói cập nhật. Bạn có thể tiếp tục dùng ứng dụng.',
                  ),
                if (status == UpdateStatus.current)
                  const MessageBox(
                    'Ứng dụng đang dùng phiên bản mới nhất được máy chủ công bố.',
                  ),
                if (updater.error.isNotEmpty)
                  MessageBox(updater.error, error: true),
                if (updater.notice.isNotEmpty) MessageBox(updater.notice),
                if (downloading) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: updater.progress),
                  const SizedBox(height: 8),
                  Text(
                    status == UpdateStatus.cancelling
                        ? 'Đang dừng tải…'
                        : 'Đang tải ${(100 * updater.progress).round()}%',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: status == UpdateStatus.cancelling
                        ? null
                        : updater.cancelDownload,
                    icon: const Icon(Icons.close),
                    label: const Text('Hủy tải'),
                  ),
                ] else if (release != null && candidate == null) ...[
                  FilledButton.icon(
                    onPressed: updater.busy ? null : updater.download,
                    icon: const Icon(Icons.download),
                    label: const Text('Tải bản cập nhật'),
                  ),
                ] else if (candidate != null) ...[
                  if (updater.installed?.canRequestInstalls != true) ...[
                    const MessageBox(
                      'Cho phép FruitVision cài APK trong cài đặt Android, rồi quay lại màn hình này.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: updater.busy
                          ? null
                          : updater.requestPermission,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Cho phép cài đặt'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: updater.busy ? null : updater.resume,
                      child: const Text('Tôi đã cho phép · Kiểm tra lại'),
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: updater.busy ? null : updater.install,
                      icon: const Icon(Icons.install_mobile),
                      label: Text(
                        updater.busy ? 'Đang mở cài đặt…' : 'Cài bản cập nhật',
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: updater.busy ? null : updater.cancelDownload,
                    child: const Text('Bỏ gói đã tải'),
                  ),
                ],
                if (!downloading) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: updater.busy
                        ? null
                        : () => updater.check(widget.baseUrl, force: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Kiểm tra lại'),
                  ),
                ],
                const SizedBox(height: 20),
                const Text(
                  'Gói APK được tải từ máy chủ bạn đã chọn và được Android xác minh. Bạn tự cấp quyền và xác nhận trong trình cài đặt. Dữ liệu tài khoản không bị xóa.',
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
