import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../media.dart';
import '../realtime.dart';
import '../session.dart';
import 'components.dart';
import 'realtime_scope.dart';
import 'live_ai.dart';
import 'visuals.dart';
import 'ai_usage.dart';

bool activeJob(Json job) => {'Queued', 'Running'}.contains(job['status']);
String jobStatus(Json job) => switch (job['status']) {
  'Queued' => 'Đang chờ xử lý',
  'Running' => 'Đang phân tích',
  'Succeeded' => 'Hoàn tất',
  'Failed' => 'Không hoàn tất',
  'Cancelled' => 'Đã hủy',
  _ => 'Đang cập nhật',
};
double jobProgress(Json job) =>
    ((job['progress'] as num?)?.toDouble() ?? 0).clamp(0, 100) / 100;
bool newerJob(Json incoming, Json? current) =>
    current == null ||
    (incoming['id'] == current['id'] &&
        ((incoming['revision'] as num?)?.toInt() ?? 0) >=
            ((current['revision'] as num?)?.toInt() ?? 0));

Json? runningSnapshot(Json event, Json current) {
  final revision = event['revision'],
      progress = event['progress'],
      frames = event['framesProcessed'];
  if (event['status'] != 'Running' ||
      !activeJob(current) ||
      !newerJob(event, current) ||
      revision is! int ||
      revision < 0 ||
      progress is! num ||
      !progress.isFinite ||
      progress < 0 ||
      progress > 100 ||
      (frames != null && (frames is! int || frames < 0))) {
    return null;
  }
  final snapshot = {
    ...current,
    'status': 'Running',
    'revision': revision,
    'progress': progress,
  };
  if (frames != null) snapshot['framesProcessed'] = frames;
  return snapshot;
}

class AiPage extends StatefulWidget {
  const AiPage({
    super.key,
    required this.controller,
    required this.header,
    this.picker,
  });
  final SessionController controller;
  final Widget header;
  final NativeMediaPicker? picker;
  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> with WidgetsBindingObserver {
  late final _picker = widget.picker ?? NativeMediaPicker();
  Json? _capabilities;
  List<Json> _jobs = [];
  PickedMedia? _picked;
  UploadCancellation? _cancellation;
  String? _requestId, _error;
  bool _loading = false,
      _choosing = false,
      _uploading = false,
      _viewing = false,
      _resumed = true;
  double _uploadProgress = 0;
  RealtimeClient? _hub;
  StreamSubscription<HubEvent>? _events;
  Timer? _eventDebounce, _poll;
  DateTime? _pollUntil;
  bool _reloadPending = false, _pendingCapabilities = false;
  int _reloadGeneration = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller.user!.canSell) _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = RealtimeScope.maybeOf(context);
    if (hub == _hub) return;
    unawaited(_events?.cancel());
    _hub?.removeListener(_onHub);
    _hub = hub;
    _hub?.addListener(_onHub);
    _events = hub?.events.listen((event) {
      if (event.target == 'AiJobChanged' && _resumed && !_viewing) {
        final index = _jobs.indexWhere((job) => job['id'] == event.data['id']);
        if (index >= 0) {
          if (!newerJob(event.data, _jobs[index])) return;
          final snapshot = runningSnapshot(event.data, _jobs[index]);
          if (snapshot != null) {
            setState(() => _jobs[index] = snapshot);
            _configurePoll();
            return;
          }
        }
        _eventDebounce?.cancel();
        if (!{'Queued', 'Running'}.contains(event.data['status'])) {
          _reload(capabilities: false);
          return;
        }
        _eventDebounce = Timer(const Duration(milliseconds: 350), () {
          if (_resumed && !_viewing) _reload(capabilities: false);
        });
      }
    });
  }

  void _onHub() {
    if (_hub?.state == HubConnectionState.connected && !_viewing && _resumed) {
      _reload(capabilities: false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      _reload(capabilities: false);
      _configurePoll();
    } else {
      _poll?.cancel();
      _eventDebounce?.cancel();
    }
  }

  Future<void> _reload({bool capabilities = true}) async {
    if (!mounted ||
        widget.controller.endingSession ||
        widget.controller.user?.canSell != true) {
      return;
    }
    if (_loading) {
      _reloadPending = true;
      _pendingCapabilities |= capabilities;
      return;
    }
    final generation = ++_reloadGeneration;
    final userId = widget.controller.user!.id;
    final server = widget.controller.api.baseUrl;
    _reloadPending = false;
    _pendingCapabilities = false;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.controller.api.get('/ai/jobs?limit=20'),
        if (capabilities) widget.controller.api.get('/ai/capabilities'),
      ]);
      if (!mounted ||
          generation != _reloadGeneration ||
          widget.controller.user?.id != userId ||
          widget.controller.api.baseUrl != server) {
        return;
      }
      setState(() {
        final previous = {for (final job in _jobs) value(job, 'id'): job};
        _jobs = rows(results.first)
            .map(
              (job) => newerJob(job, previous[job['id']])
                  ? job
                  : previous[job['id']]!,
            )
            .toList();
        if (capabilities) _capabilities = results.last;
        _loading = false;
      });
      _configurePoll();
    } catch (e) {
      if (mounted && generation == _reloadGeneration) {
        setState(() {
          _loading = false;
          _error = errorText(e);
        });
      }
    } finally {
      if (mounted && generation == _reloadGeneration) {
        final refresh = _reloadPending;
        final refreshCapabilities = _pendingCapabilities;
        _reloadPending = false;
        _pendingCapabilities = false;
        if (refresh &&
            _resumed &&
            !_viewing &&
            !widget.controller.endingSession &&
            widget.controller.user?.id == userId &&
            widget.controller.api.baseUrl == server) {
          unawaited(_reload(capabilities: refreshCapabilities));
        }
      }
    }
  }

  void _configurePoll() {
    _poll?.cancel();
    if (!_resumed || _viewing || !_jobs.any(activeJob)) {
      if (!_jobs.any(activeJob)) _pollUntil = null;
      return;
    }
    _pollUntil ??= DateTime.now().add(const Duration(minutes: 3));
    _poll = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_resumed || _viewing || DateTime.now().isAfter(_pollUntil!)) {
        timer.cancel();
        return;
      }
      _reload(capabilities: false);
    });
  }

  Future<void> _choose(String method) async {
    if (_choosing || _uploading) return;
    setState(() {
      _choosing = true;
      _error = null;
    });
    try {
      final picked = await _picker.pick(method);
      if (!mounted) {
        if (picked != null) await _picker.delete(picked);
        return;
      }
      if (picked != null) {
        if (_picked != null) await _picker.delete(_picked!);
        if (!mounted) {
          await _picker.delete(picked);
          return;
        }
        setState(() {
          _picked = picked;
          _requestId =
              'a${DateTime.now().microsecondsSinceEpoch}${Random.secure().nextInt(1 << 30)}';
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _error = e.message ?? 'Không đọc được tệp đã chọn.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Không mở được tệp. Vui lòng chọn lại.');
      }
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _discard() async {
    final picked = _picked;
    _cancellation?.cancel();
    if (picked == null) return;
    try {
      await _picker.delete(picked);
      if (mounted) {
        setState(() {
          _picked = null;
          _requestId = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Không xóa được bản sao tạm. Hãy thử hủy lại.');
      }
    }
  }

  Future<void> _upload() async {
    final picked = _picked;
    if (_uploading || picked == null || _requestId == null) return;
    final cancel = UploadCancellation();
    _cancellation = cancel;
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _error = null;
    });
    try {
      final job = await widget.controller.api.uploadAiFile(
        File(picked.path),
        mediaType: picked.mediaType,
        contentType: picked.contentType,
        requestId: _requestId!,
        cancellation: cancel,
        onProgress: (sent, total) {
          final progress = sent / total;
          if (mounted && (progress - _uploadProgress > .015 || progress == 1)) {
            setState(() => _uploadProgress = progress);
          }
        },
      );
      await _picker.delete(picked);
      if (!mounted) return;
      setState(() {
        _picked = null;
        _requestId = null;
        _uploading = false;
      });
      await _openJob(job);
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _error = errorText(e);
        });
      }
    } finally {
      _cancellation = null;
    }
  }

  Future<void> _openJob(Json job) async {
    final id = value(job, 'id');
    if (id.isEmpty) {
      setState(
        () => _error = 'Máy chủ chưa trả về mã tác vụ. Hãy cập nhật danh sách.',
      );
      return;
    }
    _viewing = true;
    _poll?.cancel();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AiJobPage(controller: widget.controller, id: id, initial: job),
      ),
    );
    if (!mounted) return;
    _viewing = false;
    await _reload(capabilities: false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _eventDebounce?.cancel();
    unawaited(_events?.cancel());
    _hub?.removeListener(_onHub);
    _cancellation?.cancel();
    final picked = _picked;
    if (picked != null) {
      unawaited(
        _picker.delete(picked).catchError((Object _) {
          /* Native cache also expires abandoned files. */
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final approved = widget.controller.user!.canSell;
    final ready =
        _capabilities?['aiReady'] == true && !widget.controller.endingSession;
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              padding: const EdgeInsets.all(16),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                widget.header,
                const SectionTitle(
                  'Phân tích xoài',
                  subtitle: 'Nhận diện xoài dự đoán, đếm và xem hai giai đoạn theo dữ liệu nguồn từ ảnh hoặc video.',
                ),
                if (!approved)
                  const MessageBox(
                    'Tài khoản cần được duyệt và đang hoạt động để dùng phân tích AI.',
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            AiUsagePage(controller: widget.controller),
                      ),
                    ),
                    icon: const Icon(Icons.insights_outlined),
                    label: const Text('Thống kê & hướng dẫn AI'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _choosing || _uploading
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  LiveAiPage(session: widget.controller),
                            ),
                          ),
                    icon: const Icon(Icons.videocam_outlined),
                    label: const Text('Camera nhận diện xoài'),
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    MessageBox(_error!, error: true),
                    const SizedBox(height: 12),
                  ],
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: LinearProgressIndicator(),
                    ),
                  if (!ready)
                    MessageBox(
                      value(
                        _capabilities ?? {},
                        'message',
                        'AI chưa sẵn sàng hoặc chưa kiểm tra được máy chủ.',
                      ),
                      child: TextButton.icon(
                        onPressed: _loading ? null : _reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Kiểm tra lại'),
                      ),
                    )
                  else
                    DataCard(
                      children: [
                        const StatusPill(
                          'Máy chủ sẵn sàng',
                          icon: Icons.cloud_done_outlined,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _MediaChoice(
                                label: 'Chọn ảnh',
                                icon: Icons.add_photo_alternate_outlined,
                                onTap: _choosing || _uploading
                                    ? null
                                    : () => _choose('pickImage'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _MediaChoice(
                                label: 'Chọn video',
                                icon: Icons.video_file_outlined,
                                onTap: _choosing || _uploading
                                    ? null
                                    : () => _choose('pickVideo'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _choosing || _uploading
                                ? null
                                : () => _choose('captureImage'),
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: const Text('Chụp ảnh'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'JPEG/PNG ≤ 12 MiB · MP4 ≤ 80 MiB',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF526860),
                          ),
                        ),
                        if (_choosing)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('Đang mở tệp đã chọn…'),
                          ),
                        const ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            'Ảnh của bạn được xử lý thế nào?',
                            style: TextStyle(fontSize: 13),
                          ),
                          children: [
                            Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: Text(
                                'Chọn tệp → gửi HTTPS → hàng đợi riêng tư → AI trên PC → ảnh chú thích và kết quả. Điện thoại không chạy mô hình.',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Tác vụ của tôi',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cập nhật tác vụ',
                        onPressed: _loading
                            ? null
                            : () => _reload(capabilities: false),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (!_loading && _jobs.isEmpty)
                    const DataCard(
                      children: [
                        IconBadge(Icons.photo_library_outlined),
                        SizedBox(height: 12),
                        Text(
                          'Chưa có tác vụ phân tích',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 4),
                        Text('Chọn một ảnh hoặc video để bắt đầu.'),
                      ],
                    ),
                  ..._jobs.map(
                    (job) => AiJobCard(job: job, onTap: () => _openJob(job)),
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),
        if (_picked != null)
          Material(
            color: Colors.white,
            elevation: 5,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconBadge(
                        _picked!.mediaType == 'video'
                            ? Icons.video_file_outlined
                            : Icons.image_outlined,
                        size: 36,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _picked!.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '${(_picked!.bytes / (1024 * 1024)).toStringAsFixed(2)} MiB · Sẵn sàng gửi',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _discard,
                        child: Text(_uploading ? 'Hủy' : 'Bỏ'),
                      ),
                    ],
                  ),
                  if (_uploading) ...[
                    LinearProgressIndicator(value: _uploadProgress),
                    const SizedBox(height: 6),
                    Text(
                      'Đang tải lên ${(_uploadProgress * 100).round()}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _uploading || !ready ? null : _upload,
                    icon: Icon(
                      _uploading
                          ? Icons.cloud_upload_outlined
                          : Icons.arrow_upward,
                    ),
                    label: Text(_uploading ? 'Đang tải lên…' : 'Gửi phân tích'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MediaChoice extends StatelessWidget {
  const _MediaChoice({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 112),
      padding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    child: Column(
      children: [
        Icon(icon, size: 32),
        const SizedBox(height: 10),
        Text(label, textAlign: TextAlign.center),
      ],
    ),
  );
}

class AiJobCard extends StatelessWidget {
  const AiJobCard({super.key, required this.job, required this.onTap});
  final Json job;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => DataCard(
    onTap: onTap,
    children: [
      Row(
        children: [
          IconBadge(
            job['mediaType'] == 'video'
                ? Icons.movie_outlined
                : Icons.image_outlined,
            color: blue,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${job['mediaType'] == 'video' ? 'Video' : 'Ảnh'} · ${jobStatus(job)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  displayTime(job['createdAt']),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFF698079)),
        ],
      ),
      if (activeJob(job)) ...[
        const SizedBox(height: 14),
        LinearProgressIndicator(
          value: jobProgress(job),
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: 6),
        Text(
          '${(jobProgress(job) * 100).round()}%',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    ],
  );
}

class AiJobPage extends StatefulWidget {
  const AiJobPage({
    super.key,
    required this.controller,
    required this.id,
    this.initial,
  });
  final SessionController controller;
  final String id;
  final Json? initial;
  @override
  State<AiJobPage> createState() => _AiJobPageState();
}

class _AiJobPageState extends State<AiJobPage> with WidgetsBindingObserver {
  Json? _job;
  Uint8List? _preview;
  String? _error, _previewError;
  bool _loading = false,
      _cancelling = false,
      _previewLoading = false,
      _resumed = true,
      _pollExpired = false;
  final _until = DateTime.now().add(const Duration(minutes: 3));
  Timer? _poll, _debounce;
  int _requestGeneration = 0;
  bool _refreshPending = false;
  RealtimeClient? _hub;
  StreamSubscription<HubEvent>? _events;
  @override
  void initState() {
    super.initState();
    _job = widget.initial;
    WidgetsBinding.instance.addObserver(this);
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (DateTime.now().isAfter(_until)) {
        timer.cancel();
        if (mounted) setState(() => _pollExpired = true);
        return;
      }
      if (_resumed && _job != null && activeJob(_job!)) _load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = RealtimeScope.maybeOf(context);
    if (hub == _hub) return;
    unawaited(_events?.cancel());
    _hub?.removeListener(_onHub);
    _hub = hub;
    hub?.addListener(_onHub);
    _events = hub?.events.listen((event) {
      if (event.target == 'AiJobChanged' &&
          event.data['id'] == widget.id &&
          newerJob(event.data, _job) &&
          _resumed) {
        final snapshot = _job == null
            ? null
            : runningSnapshot(event.data, _job!);
        if (snapshot != null) {
          setState(() => _job = snapshot);
          return;
        }
        _debounce?.cancel();
        if (!{'Queued', 'Running'}.contains(event.data['status'])) {
          _load();
          return;
        }
        _debounce = Timer(const Duration(milliseconds: 300), _load);
      }
    });
  }

  void _onHub() {
    if (_hub?.state == HubConnectionState.connected && _resumed) _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      _load();
    } else {
      _debounce?.cancel();
    }
  }

  Future<void> _load() async {
    if (!mounted || widget.controller.endingSession) return;
    if (_loading || _cancelling) {
      _refreshPending = true;
      return;
    }
    final generation = ++_requestGeneration;
    final id = widget.id;
    final userId = widget.controller.user?.id;
    final server = widget.controller.api.baseUrl;
    _refreshPending = false;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final job = await widget.controller.api.get(
        '/ai/jobs/${Uri.encodeComponent(widget.id)}',
      );
      if (!mounted ||
          generation != _requestGeneration ||
          widget.id != id ||
          widget.controller.user?.id != userId ||
          widget.controller.api.baseUrl != server) {
        return;
      }
      if (job['id'] != widget.id) {
        throw const ApiException(
          'Máy chủ trả về tác vụ không khớp. Vui lòng cập nhật lại.',
        );
      }
      setState(() {
        if (newerJob(job, _job)) _job = job;
        _loading = false;
      });
      if (!activeJob(_job!)) _poll?.cancel();
      if (_job!['previewAvailable'] == true &&
          _preview == null &&
          !_previewLoading) {
        _loadPreview();
      }
    } catch (e) {
      if (mounted && generation == _requestGeneration) {
        setState(() {
          _loading = false;
          _error = errorText(e);
        });
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        final refresh = _refreshPending;
        _refreshPending = false;
        if (refresh &&
            _resumed &&
            !_cancelling &&
            !widget.controller.endingSession &&
            widget.id == id &&
            widget.controller.user?.id == userId &&
            widget.controller.api.baseUrl == server) {
          unawaited(_load());
        }
      }
    }
  }

  Future<void> _loadPreview() async {
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final bytes = await widget.controller.api.aiPreview(widget.id);
      if (mounted) {
        setState(() {
          _preview = bytes;
          _previewLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewLoading = false;
          _previewError = errorText(e);
        });
      }
    }
  }

  Future<void> _cancel() async {
    if (_cancelling) return;
    ++_requestGeneration;
    setState(() {
      _cancelling = true;
      _loading = false;
      _error = null;
    });
    try {
      final job = await widget.controller.api.post(
        '/ai/jobs/${Uri.encodeComponent(widget.id)}/cancel',
        null,
      );
      if (!mounted) return;
      setState(() {
        if (newerJob(job, _job)) _job = job;
        _cancelling = false;
      });
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() {
          _cancelling = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _debounce?.cancel();
    unawaited(_events?.cancel());
    _hub?.removeListener(_onHub);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Kết quả phân tích'),
      actions: [
        IconButton(
          tooltip: 'Cập nhật tác vụ',
          onPressed: _loading || _cancelling ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_error != null) ...[
              MessageBox(_error!, error: true),
              const SizedBox(height: 12),
            ],
            if (_job != null) ...[
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusPill(
                    jobStatus(_job!),
                    icon: _job!['status'] == 'Succeeded'
                        ? Icons.check_circle_outline
                        : Icons.schedule_outlined,
                  ),
                  Text(
                    '${_job!['mediaType'] == 'video' ? 'Video' : 'Ảnh'} · ${displayTime(_job!['createdAt'])}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const RealtimeStatus(compact: true),
              const SizedBox(height: 16),
              if (activeJob(_job!))
                DataCard(
                  children: [
                    const Text(
                      'Máy chủ đang xử lý',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                      value: jobProgress(_job!),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(jobProgress(_job!) * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_job!['framesProcessed'] != null)
                      Text('Khung hình đã xử lý: ${_job!['framesProcessed']}'),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _cancelling ? null : _cancel,
                      child: Text(
                        _cancelling ? 'Đang yêu cầu hủy…' : 'Hủy tác vụ',
                      ),
                    ),
                    if (_pollExpired)
                      const Text(
                        'Đã dừng kiểm tra tự động sau 3 phút. Bấm cập nhật để xem kết quả.',
                      ),
                  ],
                ),
              if (_job!['error'] != null)
                MessageBox(value(_job!, 'error'), error: true),
              if (_previewLoading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_previewError != null)
                MessageBox(
                  _previewError!,
                  error: true,
                  child: TextButton(
                    onPressed: _loadPreview,
                    child: const Text('Tải lại ảnh kết quả'),
                  ),
                ),
              if (_preview != null) AnnotatedPreview(bytes: _preview!),
              if (_job!['result'] is Map)
                AiResultCard(
                  result: Map<String, dynamic>.from(_job!['result'] as Map),
                  mediaType: value(_job!, 'mediaType'),
                ),
            ] else if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ),
  );
}

class AnnotatedPreview extends StatelessWidget {
  const AnnotatedPreview({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('ai-annotated-preview'),
    padding: const EdgeInsets.only(bottom: 16),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Ảnh chú thích')),
              body: SafeArea(
                child: InteractiveViewer(
                  minScale: .5,
                  maxScale: 4,
                  child: Center(
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: Image.memory(
                bytes,
                width: double.infinity,
                fit: BoxFit.contain,
                semanticLabel: 'Ảnh nhận diện có chú thích từ máy chủ',
                errorBuilder: (_, _, _) => const MessageBox(
                  'Ảnh kết quả không đọc được.',
                  error: true,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.zoom_in, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ảnh chú thích · Chạm để phóng to',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
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

class AiResultCard extends StatelessWidget {
  const AiResultCard({
    super.key,
    required this.result,
    required this.mediaType,
  });
  final Json result;
  final String mediaType;
  @override
  Widget build(BuildContext context) {
    final video = mediaType == 'video';
    final mango = result['scope'] == 'predicted-mango-only';
    final grades = result['gradeCounts'] is Map
        ? Map<String, dynamic>.from(result['gradeCounts'] as Map)
        : <String, dynamic>{};
    final objects = (result['objects'] as List? ?? []).whereType<Map>().take(
      50,
    );
    final limitations = (result['limitations'] as List? ?? []).map(
      (item) => item.toString(),
    );
    return DataCard(
      children: [
        if (!mango)
          const MessageBox(
            'Kết quả lưu trước bộ lọc xoài; số đếm có thể gồm loại quả khác. Giữ nguyên nhãn và số liệu đã ghi nhận.',
          ),
        if (mango && result['maxVisibleCount'] == 0)
          MessageBox(
            value(
              result,
              'summary',
              'Không phát hiện xoài đạt ngưỡng. Kết quả này không chứng minh ảnh không có xoài.',
            ),
          ),
        CountMetric(
          label: video
              ? 'Tối đa thấy đồng thời'
              : mango
              ? 'Xoài dự đoán trong ảnh'
              : 'Quả nhận diện trong ảnh',
          value: '${result['maxVisibleCount'] ?? 0}',
          icon: Icons.filter_center_focus,
          primary: true,
          semanticLabel:
              '${video ? 'Số quả thấy đồng thời nhiều nhất' : 'Số quả nhận diện trong ảnh'}: ${result['maxVisibleCount'] ?? 0}',
        ),
        if (video) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: CountMetric(
                  label: 'Track xác nhận',
                  value: '${result['confirmedTrackCount'] ?? 0}',
                  icon: Icons.route_outlined,
                  semanticLabel:
                      'Track đã xác nhận: ${result['confirmedTrackCount'] ?? 0}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CountMetric(
                  label: 'Lượt qua vạch',
                  value: '${result['lineCrossingCount'] ?? 0}',
                  icon: Icons.line_axis,
                  semanticLabel:
                      'Lượt cắt đường đếm: ${result['lineCrossingCount'] ?? 0}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${result['framesProcessed'] ?? 0} khung hình đã xử lý',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 20),
        GradeSummary(
          counts: grades,
          caption: video
              ? '${result['confirmedTrackCount'] ?? 0} track xác nhận · không phải số quả đồng thời'
              : '${result['maxVisibleCount'] ?? 0} nhận diện trong ảnh',
        ),
        const SizedBox(height: 12),
        const Text(
          'Ước tính từ mô hình; không phải kg hoặc tồn kho.',
          style: TextStyle(fontSize: 12, color: Color(0xFF526860)),
        ),
        const Divider(height: 28),
        ExpansionTile(
          key: const ValueKey('ai-result-explanation'),
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'Cách hiểu kết quả',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          children: [
            if (video)
              const Text(
                'Các số đo có ý nghĩa khác nhau, không cộng lại thành tổng số quả. Track có thể bị đếm lại khi vật bị che hoặc rời khung hình.',
              ),
            if (video)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'Thấy đồng thời: nhiều nhất trong một khung. Track xác nhận: ID đã thấy ít nhất hai lần. Lượt qua vạch: mỗi ID xác nhận đi qua đường đếm được tính tối đa một lần.',
                ),
              ),
            const Text(
              'Chưa xác định là trường hợp mô hình chưa đủ chắc chắn để gán giai đoạn. Kết quả không chứng nhận độ chín hay chất lượng thực địa.',
            ),
            ...limitations.map(
              (limitation) => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('• $limitation'),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
        ExpansionTile(
          key: const ValueKey('ai-technical-info'),
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'Thông tin kỹ thuật',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          children: [
            Text('Mô hình: ${result['modelName'] ?? 'Không có thông tin'}'),
            if (result['schema'] != null)
              Text('Hợp đồng kết quả: ${result['schema']}'),
            if (result['processingSeconds'] != null)
              Text('Thời gian xử lý: ${result['processingSeconds']} giây'),
            if (result['modelSha256'] != null) ...[
              const SizedBox(height: 10),
              const Text(
                'SHA-256 mô hình',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SelectableText(
                value(result, 'modelSha256'),
                style: const TextStyle(fontSize: 12),
              ),
            ],
            if (objects.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Chi tiết nhận diện'),
                children: objects
                    .map(
                      (object) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${object['fruitLabel'] ?? 'Chưa xác định'} · ${object['stageLabel'] ?? 'Chưa xác định giai đoạn'}',
                            ),
                            Text(
                              'Độ tin cậy: ${(((object['score'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(1)}%${object['trackId'] == null ? '' : ' · Track ${object['trackId']}'}',
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ],
    );
  }
}
