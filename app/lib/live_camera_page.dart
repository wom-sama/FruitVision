import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'live_camera.dart';
import 'inference.dart';
import 'scene_objects_view.dart';
import 'count_summary_card.dart';

typedef LivePreviewBuilder = Widget Function(
  BuildContext context,
  ValueChanged<int> onCreated,
);

class LiveCameraPage extends StatefulWidget {
  const LiveCameraPage({
    super.key,
    this.controller,
    this.previewBuilder,
    this.classLabels = const [],
    this.runtime,
  });

  /// The page owns the supplied controller's session and disposes it when closed.
  final LiveCameraController? controller;
  final LivePreviewBuilder? previewBuilder;
  final List<String> classLabels;
  final RuntimeInfo? runtime;

  @override
  State<LiveCameraPage> createState() => _LiveCameraPageState();
}

class _LiveCameraPageState extends State<LiveCameraPage>
    with WidgetsBindingObserver {
  late final LiveCameraController _controller;
  final _previewKey = GlobalKey();
  bool _initialStartRequested = false;
  bool _closing = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? LiveCameraController();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_controller.handleLifecycle(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  void _onPreviewCreated(int viewId) {
    if (!mounted) return;
    _controller.attachPreview(viewId);
    if (_initialStartRequested) return;
    _initialStartRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) return;
      final render = _previewKey.currentContext?.findRenderObject();
      if (render is RenderBox &&
          render.hasSize &&
          render.size.width > 0 &&
          render.size.height > 0) {
        unawaited(_controller.start());
      }
    });
  }

  Future<void> _closePage() async {
    if (_closing) return;
    setState(() => _closing = true);
    await _controller.stop();
    if (!mounted) return;
    if (_controller.sessionActive) {
      setState(() => _closing = false);
      return;
    }
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_closePage());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Camera trực tiếp',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: const [
            Padding(
              padding: EdgeInsets.only(right: 18),
              child: Icon(Icons.cloud_off_rounded, size: 20),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final landscape =
                  constraints.maxWidth >= 720 &&
                  constraints.maxWidth > constraints.maxHeight;
              final preview = _preview(landscape);
              final details = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _controls(),
                  const SizedBox(height: 16),
                  CountSummaryCard(
                    summary: _controller.countSummary,
                    source: 'live_camera',
                    frameCount:
                        _controller.result?.performance.count('processed') ?? 0,
                    currentObjects:
                        _controller.result?.sceneObjects.length ?? 0,
                    classLabels:
                        widget.runtime?.classLabels ?? widget.classLabels,
                  ),
                  const SizedBox(height: 16),
                  _LiveResultCard(
                    result: _controller.result,
                    classLabels:
                        widget.runtime?.classLabels ?? widget.classLabels,
                    fruitMode: widget.runtime?.classificationOnly == true,
                  ),
                  const SizedBox(height: 16),
                  _PerformanceCard(result: _controller.result),
                ],
              );
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: landscape
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 6, child: preview),
                              const SizedBox(width: 16),
                              Expanded(flex: 5, child: details),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              preview,
                              const SizedBox(height: 16),
                              details,
                            ],
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _preview(bool landscape) {
    final nativePreview =
        widget.previewBuilder?.call(context, _onPreviewCreated) ??
        (defaultTargetPlatform == TargetPlatform.android
            ? AndroidView(
                viewType: 'vn.mangodemo/live_preview',
                onPlatformViewCreated: _onPreviewCreated,
              )
            : const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Camera trực tiếp cần thiết bị Android.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ));
    final stopped =
        _controller.phase == LiveCameraPhase.idle ||
        _controller.phase == LiveCameraPhase.error;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.videocam_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _controller.lensFacing == 'back'
                        ? 'Camera sau'
                        : 'Camera trước',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                _SessionBadge(phase: _controller.phase),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: landscape ? 16 / 9 : 3 / 4,
            child: SizedBox(
              key: const ValueKey('live-camera-preview'),
              child: ColoredBox(
                key: _previewKey,
                color: const Color(0xFF132C47),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    nativePreview,
                    if (stopped &&
                        (defaultTargetPlatform == TargetPlatform.android ||
                            widget.previewBuilder != null))
                      ColoredBox(
                        color: const Color(0xED132C47),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.videocam_off_outlined,
                                color: Colors.white70,
                                size: 42,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _controller.phase == LiveCameraPhase.error
                                    ? 'Camera chưa sẵn sàng'
                                    : 'Camera đã dừng',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_controller.phase == LiveCameraPhase.starting)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Giữ các quả${widget.runtime?.classificationOnly == true ? '' : ' xoài'} rõ trong khung. Mã # theo bộ đếm của phiên; che khuất lâu hoặc quay lại khung có thể tạo mã mới. Xem FPS xử lý thực trong mục Hiệu năng; tốc độ có thể giảm khi thiết bị nóng.'
              '${widget.runtime?.classificationOnly == true ? '\n${widget.runtime!.supportedSpeciesDescription}' : ''}',
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Color(0xFF61748B),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (_controller.canStop)
                FilledButton.icon(
                  onPressed: _closing
                      ? null
                      : () => unawaited(_controller.stop()),
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Dừng camera'),
                )
              else
                FilledButton.icon(
                  onPressed: _controller.canStart && !_closing
                      ? () => unawaited(_controller.start())
                      : null,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    _controller.phase == LiveCameraPhase.error
                        ? 'Thử lại'
                        : 'Bắt đầu camera',
                  ),
                ),
              OutlinedButton.icon(
                onPressed: _controller.canSwitchLens && !_closing
                    ? () => unawaited(_controller.switchLens())
                    : null,
                icon: const Icon(Icons.cameraswitch_outlined),
                label: const Text('Đổi camera'),
              ),
            ],
          ),
          if (_controller.error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                _controller.error!,
                style: const TextStyle(
                  color: Color(0xFFB43D31),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Camera tự dừng khi ứng dụng vào nền. Bấm bắt đầu để mở lại khi quay về.',
            style: TextStyle(
              color: Color(0xFF61748B),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    ),
  );
}

class _SessionBadge extends StatelessWidget {
  const _SessionBadge({required this.phase});
  final LiveCameraPhase phase;

  @override
  Widget build(BuildContext context) {
    final running = phase == LiveCameraPhase.running;
    final color = running ? const Color(0xFF237149) : const Color(0xFF61748B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        switch (phase) {
          LiveCameraPhase.running => 'ĐANG CHẠY',
          LiveCameraPhase.starting => 'ĐANG MỞ',
          LiveCameraPhase.stopping => 'ĐANG DỪNG',
          LiveCameraPhase.error => 'CẦN THỬ LẠI',
          LiveCameraPhase.idle => 'ĐÃ DỪNG',
        },
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _LiveResultCard extends StatelessWidget {
  const _LiveResultCard({
    required this.result,
    required this.classLabels,
    this.fruitMode = false,
  });
  final LiveFrame? result;
  final List<String> classLabels;
  final bool fruitMode;

  @override
  Widget build(BuildContext context) {
    final current = result;
    if (current?.objects != null) {
      return SceneObjectsView(
        objects: current!.objects!,
        classLabels: classLabels,
        detectionLimitReached: current.detectionLimitReached,
        live: true,
        emptyLabel: fruitMode || current.status == LiveFrameStatus.noFruit
            ? 'Chưa tìm thấy quả'
            : 'Chưa tìm thấy quả xoài',
      );
    }
    final title = switch (current?.status) {
      LiveFrameStatus.ok => 'Lớp dự đoán: ${current!.classId}',
      LiveFrameStatus.uncertain => 'Chưa đủ tin cậy',
      LiveFrameStatus.noMango =>
        fruitMode ? 'Chưa tìm thấy quả' : 'Chưa tìm thấy quả xoài',
      LiveFrameStatus.noFruit => 'Chưa tìm thấy quả',
      LiveFrameStatus.unsupportedSpecies =>
        '${current!.species == null ? 'Quả' : speciesLabel(current.species!)} · Chưa hỗ trợ phân lớp',
      null => 'Đang chờ khung hình',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'KHUNG HÌNH GẦN NHẤT',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              switch (current?.status) {
                LiveFrameStatus.ok =>
                  'Điểm lớp ${(current!.confidence! * 100).toStringAsFixed(1)}%${current.classId! < classLabels.length ? ' • ${classLabels[current.classId!]}' : ''}',
                LiveFrameStatus.uncertain =>
                  'Ứng viên lớp ${current!.classId}; hãy giữ quả rõ hơn và kiểm tra lại.',
                LiveFrameStatus.noMango ||
                LiveFrameStatus.noFruit => 'Không gán lớp cho khung hình này.',
                LiveFrameStatus.unsupportedSpecies =>
                  'Loài quả này chưa hỗ trợ phân lớp.',
                null =>
                  'Kết quả sẽ xuất hiện khi camera phân tích được khung hình.',
              },
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Color(0xFF61748B),
              ),
            ),
            if (current != null && current.graded) ...[
              const SizedBox(height: 18),
              for (var id = 0; id < current.probabilities.length; id++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          'Lớp $id',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: current.probabilities[id],
                            minHeight: 7,
                            color:
                                current.status == LiveFrameStatus.ok &&
                                    current.classId == id
                                ? Theme.of(context).colorScheme.primary
                                : const Color(0xFFA8BAD3),
                            backgroundColor: const Color(0xFFEAF0F8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 46,
                        child: Text(
                          '${(current.probabilities[id] * 100).toStringAsFixed(1)}%',
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 10),
            Text(
              fruitMode ? 'Lớp 0–4 mô tả giai đoạn quan sát trên vỏ.' : 'Điểm lớp phục vụ nghiên cứu; không phải chứng nhận chất lượng hay an toàn thực phẩm.',
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF61748B),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({required this.result});
  final LiveFrame? result;

  @override
  Widget build(BuildContext context) {
    final stats = result?.performance;
    String metric(String key, {String unit = 'ms', int digits = 1}) =>
        stats == null
        ? '—'
        : '${stats.number(key).toStringAsFixed(digits)} $unit';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        leading: Icon(
          Icons.speed_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: const Text(
          'Hiệu năng phiên camera',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          stats == null
              ? 'Chờ số đo trên thiết bị'
              : '${metric('inferenceFps', unit: 'FPS')} phân tích • ${stats.count('sampleCount')} mẫu',
          style: const TextStyle(fontSize: 11),
        ),
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              _Measurement(
                'FPS phân tích',
                metric('inferenceFps', unit: 'FPS'),
              ),
              _Measurement('FPS analyzer', metric('analyzerFps', unit: 'FPS')),
              _Measurement('Giới hạn phân tích', metric('maxFps', unit: 'FPS')),
              if (stats?.values.containsKey('effectiveMaxFps') == true)
                _Measurement(
                  'Giới hạn đang áp dụng',
                  metric('effectiveMaxFps', unit: 'FPS'),
                ),
              _Measurement(
                'Model p50 / p95',
                '${metric('modelP50Ms')} / ${metric('modelP95Ms')}',
              ),
              _Measurement(
                'Pipeline p50 / p95',
                '${metric('pipelineP50Ms')} / ${metric('pipelineP95Ms')}',
              ),
              _Measurement('Chuyển ảnh p95', metric('conversionP95Ms')),
              _Measurement(
                'Callback → overlay p95',
                metric('callbackToOverlayP95Ms'),
              ),
              _Measurement('Bộ nhớ PSS', metric('pssMb', unit: 'MB')),
              _Measurement(
                'Đã xử lý / bỏ qua',
                stats == null
                    ? '—'
                    : '${stats.count('processed')} / ${stats.count('skipped')}',
              ),
              _Measurement(
                'Khung analyzer nhận',
                stats == null ? '—' : '${stats.count('delivered')}',
              ),
              _Measurement(
                'Ảnh phân tích',
                stats == null
                    ? '—'
                    : '${stats.count('analysisWidth')} × ${stats.count('analysisHeight')}',
              ),
              _Measurement(
                'Thời gian phiên',
                stats == null
                    ? '—'
                    : '${(stats.count('uptimeMs') / 1000).toStringAsFixed(1)} s',
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'FPS analyzer là tốc độ nhận khung hình để phân tích, không phải FPS xem trước. FPS phân tích là số khung được model xử lý mỗi giây.',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: Color(0xFF61748B),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Callback → overlay đo từ lúc analyzer nhận khung đến khi cập nhật vùng nhận diện; không đo độ trễ photon → màn hình. p50/p95 là trung vị/phân vị 95 của tối đa 120 mẫu gần nhất, bỏ 5 khung làm nóng.',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: Color(0xFF61748B),
            ),
          ),
        ],
      ),
    );
  }
}

class _Measurement extends StatelessWidget {
  const _Measurement(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 10, color: Color(0xFF61748B)),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    ],
  );
}
