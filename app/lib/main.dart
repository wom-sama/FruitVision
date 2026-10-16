import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'image_preview.dart';
import 'inference.dart';
import 'live_camera_page.dart';
import 'scene_objects_view.dart';
import 'count_summary_card.dart';
import 'counting_line_controls.dart';

const mangoBlue = Color(0xFF0754AA);
const mangoInk = Color(0xFF132C47);
const mangoPaper = Color(0xFFF4F7FC);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.controller});

  final MangoController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: controller?.runtime?.classificationOnly == true
        ? 'Fruit Offline'
        : 'Mango Offline',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: mangoBlue,
        primary: mangoBlue,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: mangoPaper,
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: mangoInk,
        displayColor: mangoInk,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: mangoPaper,
        foregroundColor: mangoInk,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: Color(0xFFE1E8F3)),
        ),
      ),
    ),
    home: MangoHome(controller: controller),
  );
}

class MangoHome extends StatefulWidget {
  const MangoHome({super.key, this.controller});

  final MangoController? controller;

  @override
  State<MangoHome> createState() => _MangoHomeState();
}

class _MangoHomeState extends State<MangoHome> with WidgetsBindingObserver {
  late final MangoController _controller;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget.controller ?? MangoController();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_controller.runtime == null) await _controller.prepare();
    if (!mounted ||
        _controller.runtime == null ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _controller.selectMedia(() async {
      final response = await _picker.retrieveLostData();
      if (response.isEmpty || !mounted) return null;
      if (response.exception != null) throw response.exception!;
      final file = response.file ?? response.files?.firstOrNull;
      if (file == null) return null;
      final video = response.type == RetrieveType.video;
      return MediaSelection(
        file.path,
        isVideo: video,
        label: video ? 'Video được khôi phục' : 'Ảnh được khôi phục',
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _controller.cancelVideo();
    }
  }

  Future<void> _pickImage(ImageSource source) => _controller.selectMedia(
    () async {
      final file = await _picker.pickImage(
        source: source,
        requestFullMetadata: false,
      );
      return file == null
          ? null
          : MediaSelection(
              file.path,
              label: source == ImageSource.camera ? 'Ảnh chụp' : 'Ảnh thư viện',
            );
    },
  );

  Future<void> _pickVideo() => _controller.selectMedia(() async {
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    return file == null
        ? null
        : MediaSelection(file.path, isVideo: true, label: 'Video đã chọn');
  });

  Future<void> _openLiveCamera() async {
    if (!_controller.canSelect) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LiveCameraPage(runtime: _controller.runtime),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: mangoBlue,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.eco_rounded,
                color: Colors.white,
                size: 23,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _controller.runtime?.classificationOnly == true
                    ? 'Fruit Offline'
                    : 'Mango Offline',
                overflow: TextOverflow.fade,
                softWrap: false,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 19,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _OfflineBadge(
              ready: _controller.runtime?.offline == true,
              loading: _controller.phase == WorkPhase.prepare,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Introduction(runtime: _controller.runtime),
                  const SizedBox(height: 20),
                  if (_controller.phase == WorkPhase.prepare)
                    const _PreparingCard(),
                  if (_controller.error != null) ...[
                    _ErrorCard(
                      message: _controller.error!,
                      retry: _controller.runtime == null && !_controller.busy
                          ? _initialize
                          : null,
                    ),
                    const SizedBox(height: 16),
                  ],
                  CountingLineControls(
                    line: _controller.lineCounter,
                    enabled: _controller.canSelect,
                    onChanged: _controller.setCountingLine,
                  ),
                  const SizedBox(height: 16),
                  _SourceCard(
                    enabled: _controller.canSelect,
                    onGallery: () => _pickImage(ImageSource.gallery),
                    onCamera: () => _pickImage(ImageSource.camera),
                    onVideo: _pickVideo,
                    onLiveCamera: _openLiveCamera,
                    multiSampleLabel:
                        _controller.runtime?.graderMode == 'detection_stages'
                        ? 'Ảnh nhiều quả'
                        : 'Ảnh nhiều quả (ghép)',
                    onSample: () => _controller.analyzeImage(
                      _controller.runtime!.samplePath,
                      label: 'Ảnh mẫu đi kèm',
                    ),
                    onMultiSample: _controller.runtime?.multiSamplePath == null
                        ? null
                        : () => _controller.analyzeImage(
                            _controller.runtime!.multiSamplePath!,
                            label:
                                _controller.runtime?.graderMode ==
                                    'detection_stages'
                                ? 'Ảnh nhiều quả · ảnh thật trong nguồn dữ liệu'
                                : 'Ảnh ghép kiểm thử · không phải cảnh quay thực tế',
                          ),
                  ),
                  if (_controller.isVideo) ...[
                    const SizedBox(height: 16),
                    _VideoCard(controller: _controller),
                  ],
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final preview = _PreviewCard(controller: _controller);
                      final result = _ResultCard(
                        result: _controller.result,
                        classLabels:
                            _controller.runtime?.classLabels ?? const [],
                        fruitMode:
                            _controller.runtime?.classificationOnly == true,
                      );
                      if (constraints.maxWidth >= 760) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 6, child: preview),
                            const SizedBox(width: 20),
                            Expanded(flex: 5, child: result),
                          ],
                        );
                      }
                      return Column(
                        children: [preview, const SizedBox(height: 20), result],
                      );
                    },
                  ),
                  if (_controller.runtime != null) ...[
                    const SizedBox(height: 20),
                    _RuntimeCard(
                      runtime: _controller.runtime!,
                      result: _controller.result,
                    ),
                  ],
                  const SizedBox(height: 18),
                  const Text(
                    'Công cụ nghiên cứu • Kết quả không phải chứng nhận an toàn thực phẩm.',
                    style: TextStyle(
                      color: Color(0xFF61748B),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge({required this.ready, required this.loading});
  final bool ready;
  final bool loading;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: ready ? const Color(0xFFE8F4EE) : const Color(0xFFE7EDF7),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ready ? Icons.cloud_off_rounded : Icons.hourglass_top_rounded,
          size: 14,
          color: ready ? const Color(0xFF237149) : mangoBlue,
        ),
        const SizedBox(width: 5),
        Text(
          ready
              ? 'OFFLINE'
              : loading
              ? 'ĐANG NẠP'
              : 'CHƯA NẠP',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: .7,
            color: ready ? const Color(0xFF237149) : mangoBlue,
          ),
        ),
      ],
    ),
  );
}

class _Introduction extends StatelessWidget {
  const _Introduction({this.runtime});
  final RuntimeInfo? runtime;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'NHẬN DIỆN & PHÂN LOẠI',
        style: TextStyle(
          color: mangoBlue,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        runtime?.classificationOnly == true
            ? 'Đếm quả, xem mức chín.'
            : 'Hiểu hơn về quả xoài.',
        style: const TextStyle(
          fontSize: 29,
          fontWeight: FontWeight.w800,
          height: 1.15,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        runtime?.classificationOnly == true
            ? 'Chọn ảnh, video hoặc camera để đếm từng quả và thống kê mức chín. Chỉ phân mức quan sát trên vỏ cho loài được hỗ trợ; xử lý hoàn toàn trên thiết bị.'
            : 'Chọn ảnh, video hoặc mở camera trực tiếp để xem từng vùng quả và điểm của 5 lớp. Tối đa 8 quả mỗi lượt, xử lý trên thiết bị.',
        style: const TextStyle(
          color: Color(0xFF61748B),
          fontSize: 14,
          height: 1.5,
        ),
      ),
      if (runtime?.classificationOnly == true) ...[
        const SizedBox(height: 8),
        Text(
          runtime!.supportedSpeciesDescription,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ],
    ],
  );
}

class _PreparingCard extends StatelessWidget {
  const _PreparingCard();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: 16),
    child: Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Đang chuẩn bị model trên thiết bị…')),
          ],
        ),
      ),
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.retry});
  final String message;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFECE9),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFB43D31)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chưa thể xử lý',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
                if (retry != null)
                  TextButton(
                    onPressed: retry,
                    child: const Text('Thử nạp lại'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.enabled,
    required this.onGallery,
    required this.onCamera,
    required this.onSample,
    required this.onVideo,
    required this.onLiveCamera,
    this.onMultiSample,
    this.multiSampleLabel = 'Ảnh nhiều quả (ghép)',
  });
  final bool enabled;
  final VoidCallback onGallery;
  final VoidCallback onCamera;
  final VoidCallback onSample;
  final VoidCallback onVideo;
  final VoidCallback onLiveCamera;
  final VoidCallback? onMultiSample;
  final String multiSampleLabel;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Chọn nguồn để bắt đầu',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 13),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: enabled ? onGallery : null,
                icon: const Icon(Icons.photo_library_outlined, size: 19),
                label: const Text('Chọn ảnh'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? onVideo : null,
                icon: const Icon(Icons.video_library_outlined, size: 19),
                label: const Text('Chọn video'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? onLiveCamera : null,
                icon: const Icon(Icons.videocam_outlined, size: 19),
                label: const Text('Camera trực tiếp'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? onCamera : null,
                icon: const Icon(Icons.photo_camera_outlined, size: 19),
                label: const Text('Chụp ảnh'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? onSample : null,
                icon: const Icon(Icons.auto_awesome_outlined, size: 19),
                label: const Text('Ảnh mẫu'),
              ),
              if (onMultiSample != null)
                OutlinedButton.icon(
                  onPressed: enabled ? onMultiSample : null,
                  icon: const Icon(Icons.grid_view_rounded, size: 19),
                  label: Text(multiSampleLabel),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.controller});
  final MangoController controller;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 13),
          child: Row(
            children: [
              const Icon(Icons.crop_free_rounded, size: 18, color: mangoBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  controller.mediaLabel.isEmpty
                      ? 'Ảnh & vùng nhận diện'
                      : controller.mediaLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (controller.result != null)
                const Icon(
                  Icons.check_circle_outline_rounded,
                  size: 18,
                  color: Color(0xFF237149),
                ),
            ],
          ),
        ),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: const Color(0xFFEAF0F8),
            child:
                controller.selectedPath == null ||
                    (controller.isVideo && controller.result == null)
                ? _EmptyPreview(
                    fruitMode: controller.runtime?.classificationOnly == true,
                  )
                : MangoImagePreview(
                    key: const ValueKey('mango-image-overlay'),
                    path:
                        controller.result?.previewPath ??
                        controller.selectedPath!,
                    version: controller.previewVersion,
                    countingLine: controller.isVideo
                        ? controller.lineCounter
                        : null,
                    objects: controller.result?.objects,
                    box:
                        controller.result?.status == AnalysisStatus.noMango ||
                            controller.result?.status == AnalysisStatus.noFruit
                        ? null
                        : controller.result?.box,
                    label: controller.result?.status == AnalysisStatus.ok
                        ? 'Lớp ${controller.result!.classId}'
                        : controller.result?.status ==
                              AnalysisStatus.unsupportedSpecies
                        ? '${controller.result?.species == null ? 'Quả' : speciesLabel(controller.result!.species!)} · Chưa hỗ trợ'
                        : 'Vùng gợi ý',
                  ),
          ),
        ),
        if (controller.phase == WorkPhase.image)
          const LinearProgressIndicator(minHeight: 3),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            controller.isVideo && controller.result != null
                ? 'Khung hình tại ${formatTimestamp(controller.result!.timestampMs ?? 0)} • phân tích từng mốc'
                : controller.phase == WorkPhase.image
                ? 'Đang phân tích ảnh…'
                : controller.result?.objects != null
                ? 'Khung đánh số từng quả; số thứ tự có thể đổi ở khung hình sau.'
                : switch (controller.result?.status) {
                    AnalysisStatus.noMango ||
                    AnalysisStatus.noFruit => 'Chưa có vùng quả để gán lớp.',
                    AnalysisStatus.unsupportedSpecies =>
                      'Khung đánh dấu loài quả chưa hỗ trợ phân lớp.',
                    AnalysisStatus.uncertain =>
                      'Vùng gợi ý; cần kiểm tra lại ảnh.',
                    AnalysisStatus.ok =>
                      'Khung đánh dấu vùng quả mô hình ước lượng.',
                    null => 'Vùng quả sẽ xuất hiện trên ảnh sau khi phân tích.',
                  },
            style: const TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Color(0xFF61748B),
            ),
          ),
        ),
      ],
    ),
  );
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview({this.fruitMode = false});
  final bool fruitMode;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.filter_center_focus_rounded,
            size: 36,
            color: mangoBlue,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          fruitMode
              ? 'Quả nguyên vỏ, góc nhìn rõ'
              : 'Một quả xoài, góc nhìn rõ',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          'Ánh sáng đều • Ít che khuất',
          style: TextStyle(fontSize: 12, color: Color(0xFF61748B)),
        ),
      ],
    ),
  );
}

String formatTimestamp(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  final tenths = ((milliseconds % 1000) ~/ 100).toString();
  return '$minutes:$seconds.$tenths';
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.controller});
  final MangoController controller;

  @override
  Widget build(BuildContext context) {
    final working = controller.phase == WorkPhase.video;
    final count = '${controller.completedSamples} khung';
    final label = controller.cancelRequested && working
        ? 'Đang dừng sau khung hình hiện tại…'
        : working
        ? 'Đang phân tích video • $count'
        : controller.videoCanceled
        ? 'Đã dừng • $count'
        : controller.error != null
        ? 'Video gặp lỗi • $count'
        : 'Đã phân tích video • $count';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.movie_filter_outlined,
                  size: 20,
                  color: mangoBlue,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (working)
                  TextButton(
                    onPressed: controller.cancelRequested
                        ? null
                        : controller.cancelVideo,
                    child: const Text('Hủy video'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: working && controller.totalSamples == 0
                    ? null
                    : controller.videoProgress,
                minHeight: 5,
                backgroundColor: const Color(0xFFEAF0F8),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Đọc khung tuần tự • ${controller.videoProcessingFps.toStringAsFixed(1)} FPS xử lý • video tối đa 10 phút • có thể hủy.',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF61748B),
                height: 1.5,
              ),
            ),
            CountSummaryCard(
              summary: controller.countSummary,
              source: 'video',
              frameCount: controller.completedSamples,
              currentObjects: controller.result?.sceneObjects.length ?? 0,
              classLabels: controller.runtime?.classLabels ?? const [],
              lineCounter: controller.lineCounter,
            ),
            if (controller.videoPoints.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text(
                'Các mốc gần nhất',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final point in controller.videoPoints)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: point.status == AnalysisStatus.ok
                            ? const Color(0xFFEAF0F8)
                            : const Color(0xFFFFF3DB),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${formatTimestamp(point.timestampMs)} · ${point.objectCount != null ? '${point.objectCount} quả' : switch (point.status) {
                                AnalysisStatus.ok => 'L${point.classId}',
                                AnalysisStatus.noMango => 'không thấy quả',
                                AnalysisStatus.noFruit => 'không thấy quả',
                                AnalysisStatus.unsupportedSpecies => 'chưa hỗ trợ',
                                AnalysisStatus.uncertain => 'chưa tin cậy',
                              }}',
                        style: const TextStyle(fontSize: 10, color: mangoInk),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    this.result,
    this.classLabels = const [],
    this.fruitMode = false,
  });
  final AnalysisResult? result;
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
        emptyLabel: fruitMode || current.status == AnalysisStatus.noFruit
            ? 'Chưa tìm thấy quả'
            : 'Chưa tìm thấy quả xoài',
      );
    }
    final title = switch (current?.status) {
      AnalysisStatus.ok => 'Lớp dự đoán: ${current!.classId}',
      AnalysisStatus.noMango =>
        fruitMode ? 'Chưa tìm thấy quả' : 'Chưa tìm thấy quả xoài',
      AnalysisStatus.noFruit => 'Chưa tìm thấy quả',
      AnalysisStatus.unsupportedSpecies =>
        '${current!.species == null ? 'Quả' : speciesLabel(current.species!)} · Chưa hỗ trợ phân lớp',
      AnalysisStatus.uncertain => 'Chưa đủ tin cậy',
      null => 'Kết quả phân tích',
    };
    final subtitle = switch (current?.status) {
      AnalysisStatus.ok =>
        'Điểm lớp ${(current!.confidence! * 100).toStringAsFixed(1)}% • kết quả của mô hình',
      AnalysisStatus.noMango || AnalysisStatus.noFruit =>
        'Không gán lớp cho ảnh này. Thử ảnh có quả rõ hơn.',
      AnalysisStatus.unsupportedSpecies => 'Loài quả này chưa hỗ trợ phân lớp.',
      AnalysisStatus.uncertain =>
        'Ứng viên lớp ${current!.classId}; hãy kiểm tra ảnh hoặc chụp lại.',
      null => 'Chọn ảnh hoặc dùng ảnh mẫu để bắt đầu.',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ĐIỂM MÔ HÌNH',
              style: TextStyle(
                color: mangoBlue,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 13),
            Semantics(
              liveRegion: true,
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xFF61748B),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            for (
              var id = 0;
              (current == null || current.graded) &&
                  id <
                      (current?.probabilities.length ??
                          (classLabels.isEmpty ? 5 : classLabels.length));
              id++
            ) ...[
              _ScoreRow(
                classId: id,
                score: current?.probabilities[id],
                highlighted:
                    current?.status == AnalysisStatus.ok &&
                    current?.classId == id,
              ),
              if (id < 4) const SizedBox(height: 14),
            ],
            const SizedBox(height: 18),
            Text(
              fruitMode
                  ? classLabels.length == 2
                        ? 'Hai mức theo nguồn: Xanh / chưa chín và Chín. Không đánh giá độ ngọt hoặc an toàn thực phẩm.'
                        : 'Lớp 0–4 mô tả giai đoạn quan sát trên vỏ.'
                  : current?.status == AnalysisStatus.noMango
                  ? 'Các điểm thô bên trên không được diễn giải thành lớp.'
                  : 'Lớp 0–4 theo nhãn nghiên cứu. Điểm không phải xác suất chất lượng hay độ an toàn.',
              style: const TextStyle(
                color: Color(0xFF61748B),
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({
    required this.classId,
    required this.score,
    required this.highlighted,
  });
  final int classId;
  final double? score;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 45,
        child: Text(
          'Lớp $classId',
          style: TextStyle(
            fontSize: 12,
            fontWeight: highlighted ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: score ?? 0,
            minHeight: 8,
            backgroundColor: const Color(0xFFEAF0F8),
            color: highlighted ? mangoBlue : const Color(0xFFA8BAD3),
          ),
        ),
      ),
      const SizedBox(width: 10),
      SizedBox(
        width: 47,
        child: Text(
          score == null ? '—' : '${(score! * 100).toStringAsFixed(1)}%',
          textAlign: TextAlign.end,
          style: TextStyle(
            fontSize: 12,
            fontWeight: highlighted ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
    ],
  );
}

class _RuntimeCard extends StatelessWidget {
  const _RuntimeCard({required this.runtime, this.result});
  final RuntimeInfo runtime;
  final AnalysisResult? result;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.speed_rounded, size: 18, color: mangoBlue),
              SizedBox(width: 8),
              Text(
                'Đo trên thiết bị',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Wrap(
            spacing: 26,
            runSpacing: 15,
            children: [
              _Metric(
                label: 'Tổng xử lý',
                value: result == null
                    ? '—'
                    : '${result!.elapsedMs.toStringAsFixed(0)} ms',
              ),
              _Metric(
                label: 'Chạy model',
                value: result == null
                    ? '—'
                    : '${result!.modelMs.toStringAsFixed(0)} ms',
              ),
              if (result?.detectorMs != null)
                _Metric(
                  label: 'Phát hiện quả',
                  value: '${result!.detectorMs!.toStringAsFixed(0)} ms',
                ),
              if (result?.classificationMs != null)
                _Metric(
                  label: 'Phân lớp các vùng',
                  value: '${result!.classificationMs!.toStringAsFixed(0)} ms',
                ),
              _Metric(
                label: 'Tiền xử lý',
                value: result == null
                    ? '—'
                    : '${result!.preprocessMs.toStringAsFixed(0)} ms',
              ),
              _Metric(
                label: 'Bộ nhớ PSS',
                value: result == null && runtime.initialPssMb == null
                    ? '—'
                    : '${(result?.nativePssMb ?? runtime.initialPssMb!).toStringAsFixed(1)} MB',
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: Color(0xFFE1E8F3)),
          const SizedBox(height: 12),
          Text(
            '${runtime.modelName} • ${(runtime.modelBytes / 1048576).toStringAsFixed(1)} MB\nCPU · ${runtime.threads} luồng · ${runtime.abi}',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF61748B),
              height: 1.6,
            ),
          ),
          const SizedBox(height: 6),
          _TechnicalDetails(runtime: runtime),
        ],
      ),
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: const TextStyle(fontSize: 10, color: Color(0xFF61748B)),
      ),
    ],
  );
}

class _TechnicalDetails extends StatelessWidget {
  const _TechnicalDetails({required this.runtime});
  final RuntimeInfo runtime;

  String? _evaluation(String key, String label) {
    final value = runtime.metrics[key];
    if (value is! Map) return null;
    final accuracy = value['accuracy'];
    final macroF1 = value['macro_f1'];
    final class1F1 = value['class1_f1'];
    return [
      'Student lịch sử · $label${value['n'] is num ? ' · N=${value['n']}' : ''}',
      if (accuracy is num) 'Accuracy ${(accuracy * 100).toStringAsFixed(1)}%',
      if (macroF1 is num) 'Macro F1 ${macroF1.toStringAsFixed(3)}',
      if (class1F1 is num) 'F1 lớp 1 ${class1F1.toStringAsFixed(3)}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final test = _evaluation('internal_test', 'test nội bộ');
    final validation = _evaluation('validation', 'validation');
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: const Text(
          'Chi tiết model & thiết bị',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (runtime.device != null)
                  Text(
                    '${runtime.device}${runtime.androidSdk == null ? '' : ' · Android API ${runtime.androidSdk}'}',
                    style: _detailStyle,
                  ),
                if (runtime.totalMemoryMb != null)
                  Text(
                    'RAM thiết bị ${(runtime.totalMemoryMb! / 1024).toStringAsFixed(1)} GB',
                    style: _detailStyle,
                  ),
                if (runtime.loadMs != null)
                  Text(
                    'Nạp model ${runtime.loadMs!.toStringAsFixed(0)} ms',
                    style: _detailStyle,
                  ),
                if (runtime.graderMode == 'detection_stages') ...[
                  const SizedBox(height: 12),
                  Text(
                    'Một encoder YOLOX-Tiny · đầu vào 480×480 · phát hiện + hai mức chín',
                    style: _detailStyle,
                  ),
                  Text(
                    'F1 phát hiện–mức chín trên TEST nguồn: ${((runtime.metrics['stage_detection_f1'] as num? ?? 0) * 100).toStringAsFixed(2)}% · N=${runtime.metrics['n_images']}. Không phải độ chính xác ngoài thực địa.',
                    style: _detailStyle,
                  ),
                  const Text(
                    'Chỉ hỗ trợ xoài/chuối nguyên quả; còn bỏ sót và nhận nhầm trên ảnh web đa dạng. Không đánh giá độ ngọt, hư bên trong hoặc an toàn thực phẩm.',
                    style: _detailStyle,
                  ),
                ],
                if (test != null || validation != null) ...[
                  const SizedBox(height: 12),
                  if (test != null) Text(test, style: _detailStyle),
                  if (test != null && validation != null)
                    const SizedBox(height: 10),
                  if (validation != null) Text(validation, style: _detailStyle),
                  const SizedBox(height: 8),
                  const Text(
                    'Chỉ số lịch sử của student trên ảnh một quả đã sử dụng; chưa đo độ chính xác bộ phát hiện hoặc phân lớp từng vùng trong cảnh nhiều quả.',
                    style: _detailStyle,
                  ),
                ],
                if (runtime.classLabels.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    runtime.classificationOnly
                        ? 'Nhãn giai đoạn quan sát trên vỏ'
                        : 'Nhãn theo bộ dữ liệu nghiên cứu',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (var id = 0; id < runtime.classLabels.length; id++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '$id · ${runtime.classLabels[id]}',
                        style: _detailStyle,
                      ),
                    ),
                ],
                if (runtime.modelSha256 != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'SHA-256 bộ phân lớp',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    runtime.modelSha256!,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF61748B),
                    ),
                  ),
                ],
                if (runtime.detectorModelSha256 != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'SHA-256 bộ phát hiện',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    runtime.detectorModelSha256!,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF61748B),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const _detailStyle = TextStyle(
    fontSize: 11,
    height: 1.6,
    color: Color(0xFF61748B),
  );
}
