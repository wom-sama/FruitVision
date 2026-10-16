import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fruit_line_counter.dart';
import 'fruit_tracking.dart';

enum AnalysisStatus { ok, noMango, uncertain, unsupportedSpecies, noFruit }

String? parseSpecies(Map<Object?, Object?> data) {
  final species = data['species'];
  if (species == null) return null;
  if (species is! String || species.trim().isEmpty) {
    throw const FormatException('Loài quả không hợp lệ.');
  }
  return species;
}

String speciesLabel(String species) => switch (species) {
  'fruit' => 'Quả',
  'mango' => 'Xoài',
  'banana' => 'Chuối',
  'apple' => 'Táo',
  'orange' => 'Cam',
  _ => species,
};

({int? classId, List<double> probabilities}) parseSceneGrade(
  Map<Object?, Object?> data, {
  required bool ungraded,
}) {
  final rawClass = data['classId'];
  final rawScores = data['probabilities'];
  final graded = data['graded'];
  final scheme = data['gradeScheme'];
  if (scheme != null && scheme != 'source_two_stage') {
    throw const FormatException('Hệ mức chín không được hỗ trợ.');
  }
  final classCount = scheme == 'source_two_stage' ? 2 : 5;
  if (data.containsKey('graded') && graded is! bool) {
    throw const FormatException('Trạng thái phân lớp không hợp lệ.');
  }
  if (ungraded) {
    if (rawClass != null || rawScores != null || graded == true) {
      throw const FormatException('Quả chưa hỗ trợ không được gán lớp.');
    }
    return (classId: null, probabilities: const []);
  }
  if (graded == false ||
      rawClass is! num ||
      !rawClass.isFinite ||
      rawClass != rawClass.roundToDouble() ||
      rawClass < 0 ||
      rawClass >= classCount ||
      rawScores is! List ||
      rawScores.length != classCount ||
      rawScores.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
    throw const FormatException('Điểm hoặc lớp của quả không hợp lệ.');
  }
  return (
    classId: rawClass.toInt(),
    probabilities: List.unmodifiable(
      rawScores.map((v) => (v as num).toDouble()),
    ),
  );
}

/// A detected region and its own crop classification, in current-frame order.
class SceneObject {
  const SceneObject({
    required this.box,
    required this.detectionScore,
    required this.classId,
    required this.probabilities,
    required this.status,
    this.species,
  });

  factory SceneObject.fromMap(Map<Object?, Object?> data) {
    final status = switch (data['status']) {
      'OK' => AnalysisStatus.ok,
      'UNCERTAIN' => AnalysisStatus.uncertain,
      'UNSUPPORTED_SPECIES' => AnalysisStatus.unsupportedSpecies,
      _ => throw const FormatException('Trạng thái của quả không hợp lệ.'),
    };
    final species = parseSpecies(data);
    if (status == AnalysisStatus.unsupportedSpecies && species == null) {
      throw const FormatException('Thiếu loài quả chưa hỗ trợ.');
    }
    final grade = parseSceneGrade(
      data,
      ungraded: status == AnalysisStatus.unsupportedSpecies,
    );
    final detectionScore = data['detectionScore'];
    if (detectionScore is! num ||
        !detectionScore.isFinite ||
        detectionScore < 0 ||
        detectionScore > 1) {
      throw const FormatException('Điểm hoặc lớp của quả không hợp lệ.');
    }
    final box = parseNormalizedBox(data['box']);
    if (box == null) {
      throw const FormatException('Thiếu tọa độ vùng quả.');
    }
    return SceneObject(
      box: box,
      detectionScore: detectionScore.toDouble(),
      classId: grade.classId,
      probabilities: grade.probabilities,
      status: status,
      species: species,
    );
  }

  /// Absent is the legacy contract; an explicit empty list means no detections.
  static List<SceneObject>? listFromMap(Map<Object?, Object?> data) {
    if (!data.containsKey('objects')) return null;
    final raw = data['objects'];
    final limit = data['gradeScheme'] == 'source_two_stage' ? 64 : 8;
    if (raw is! List || raw.length > limit || raw.any((v) => v is! Map)) {
      throw FormatException('Danh sách vùng quả không hợp lệ (tối đa $limit).');
    }
    return List.unmodifiable(
      raw.map((v) => SceneObject.fromMap(Map<Object?, Object?>.from(v as Map))),
    );
  }

  final Rect box;
  final double detectionScore;
  final int? classId;
  final List<double> probabilities;
  final AnalysisStatus status;
  final String? species;
  bool get graded => classId != null;
  double? get confidence => graded ? probabilities[classId!] : null;
}

Rect? parseNormalizedBox(Object? rawBox) {
  if (rawBox == null) return null;
  if (rawBox is! List ||
      rawBox.length != 4 ||
      rawBox.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
    throw const FormatException('Tọa độ vùng quả không hợp lệ.');
  }
  final coordinates = rawBox.map((v) => (v as num).toDouble()).toList();
  if (coordinates[0] >= coordinates[2] || coordinates[1] >= coordinates[3]) {
    throw const FormatException('Tọa độ vùng quả bị đảo hoặc rỗng.');
  }
  return Rect.fromLTRB(
    coordinates[0],
    coordinates[1],
    coordinates[2],
    coordinates[3],
  );
}

double? optionalSceneMeasurement(Map<Object?, Object?> data, String key) {
  if (!data.containsKey(key)) return null;
  final value = data[key];
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException('Số đo $key không hợp lệ.');
  }
  return value.toDouble();
}

bool parseDetectionLimit(Map<Object?, Object?> data) {
  if (!data.containsKey('detectionLimitReached')) return false;
  final value = data['detectionLimitReached'];
  if (value is! bool) {
    throw const FormatException('Giới hạn vùng quả không hợp lệ.');
  }
  return value;
}

int? parseSceneTimestamp(Map<Object?, Object?> data) {
  final value = optionalSceneMeasurement(data, 'timestampMs');
  if (value == null) return null;
  if (value != value.roundToDouble()) {
    throw const FormatException('Mốc khung hình không hợp lệ.');
  }
  return value.toInt();
}

class RuntimeInfo {
  const RuntimeInfo({
    required this.modelName,
    required this.modelBytes,
    required this.threads,
    required this.abi,
    required this.offline,
    required this.samplePath,
    required this.metrics,
    this.multiSamplePath,
    this.classLabels = const [],
    this.device,
    this.androidSdk,
    this.totalMemoryMb,
    this.initialPssMb,
    this.loadMs,
    this.modelSha256,
    this.detectorModelSha256,
    this.supportedSpecies = const [],
    this.graderMode,
  });

  factory RuntimeInfo.fromMap(Map<Object?, Object?> data) {
    final samplePath = data['samplePath'];
    if (samplePath is! String ||
        samplePath.isEmpty ||
        data['offline'] != true) {
      throw const FormatException('Model offline hoặc ảnh mẫu chưa sẵn sàng.');
    }
    final graderMode = data['graderMode'];
    final supportedSpecies = data['supportedSpecies'] ?? const [];
    if ((graderMode != null &&
            graderMode != 'classification_only' &&
            graderMode != 'detection_stages' &&
            graderMode != 'legacy_mask') ||
        supportedSpecies is! List ||
        supportedSpecies.any((v) => v is! String || v.trim().isEmpty)) {
      throw const FormatException(
        'Loài hỗ trợ hoặc chế độ phân lớp không hợp lệ.',
      );
    }
    return RuntimeInfo(
      modelName: data['modelName'] as String,
      modelBytes: (data['modelBytes'] as num).toInt(),
      threads: (data['threads'] as num).toInt(),
      abi: data['abi'] as String,
      offline: true,
      samplePath: samplePath,
      multiSamplePath: data['multiSamplePath'] as String?,
      metrics: Map<Object?, Object?>.from(data['metrics'] as Map? ?? {}),
      classLabels: (data['classLabels'] as List?)?.cast<String>() ?? const [],
      device: data['device'] as String?,
      androidSdk: (data['androidSdk'] as num?)?.toInt(),
      totalMemoryMb: (data['totalMemoryMb'] as num?)?.toDouble(),
      initialPssMb: (data['nativePssMb'] as num?)?.toDouble(),
      loadMs: (data['loadMs'] as num?)?.toDouble(),
      modelSha256: data['modelSha256'] as String?,
      detectorModelSha256: data['detectorModelSha256'] as String?,
      supportedSpecies: List.unmodifiable(supportedSpecies.cast<String>()),
      graderMode: graderMode as String?,
    );
  }

  final String modelName;
  final int modelBytes;
  final int threads;
  final String abi;
  final bool offline;
  final String samplePath;
  final String? multiSamplePath;
  final Map<Object?, Object?> metrics;
  final List<String> classLabels;
  final String? device;
  final int? androidSdk;
  final double? totalMemoryMb;
  final double? initialPssMb;
  final double? loadMs;
  final String? modelSha256;
  final String? detectorModelSha256;
  final List<String> supportedSpecies;
  final String? graderMode;
  bool get classificationOnly =>
      graderMode == 'classification_only' || graderMode == 'detection_stages';
  String get supportedSpeciesDescription => supportedSpecies.isEmpty
      ? 'Chưa khai báo loài quả được hỗ trợ phân lớp.'
      : 'Phân lớp vỏ hỗ trợ: ${supportedSpecies.map(speciesLabel).join(', ')}.';
}

class AnalysisResult {
  const AnalysisResult({
    required this.status,
    required this.probabilities,
    required this.classId,
    required this.previewPath,
    required this.elapsedMs,
    required this.modelMs,
    required this.preprocessMs,
    required this.nativePssMb,
    this.box,
    this.timestampMs,
    this.objects,
    this.detectorMs,
    this.classificationMs,
    this.detectionLimitReached = false,
    this.species,
  });

  factory AnalysisResult.fromMap(Map<Object?, Object?> data) {
    final status = switch (data['status']) {
      'OK' => AnalysisStatus.ok,
      'NO_MANGO' => AnalysisStatus.noMango,
      'UNCERTAIN' => AnalysisStatus.uncertain,
      'UNSUPPORTED_SPECIES' => AnalysisStatus.unsupportedSpecies,
      'NO_FRUIT' => AnalysisStatus.noFruit,
      _ => throw const FormatException('Trạng thái mô hình không hợp lệ.'),
    };
    final grade = parseSceneGrade(
      data,
      ungraded:
          status == AnalysisStatus.unsupportedSpecies ||
          status == AnalysisStatus.noFruit,
    );
    final box = parseNormalizedBox(data['box']);
    return AnalysisResult(
      status: status,
      probabilities: grade.probabilities,
      classId: grade.classId,
      previewPath: data['previewPath'] as String,
      elapsedMs: (data['elapsedMs'] as num).toDouble(),
      modelMs: (data['modelMs'] as num).toDouble(),
      preprocessMs: (data['preprocessMs'] as num).toDouble(),
      nativePssMb: (data['nativePssMb'] as num).toDouble(),
      box: box,
      timestampMs: parseSceneTimestamp(data),
      objects: SceneObject.listFromMap(data),
      detectorMs: optionalSceneMeasurement(data, 'detectorMs'),
      classificationMs: optionalSceneMeasurement(data, 'classificationMs'),
      detectionLimitReached: parseDetectionLimit(data),
      species: parseSpecies(data),
    );
  }

  final AnalysisStatus status;
  final List<double> probabilities;
  final int? classId;
  final String previewPath;
  final double elapsedMs;
  final double modelMs;
  final double preprocessMs;
  final double nativePssMb;
  final Rect? box;
  final int? timestampMs;
  final List<SceneObject>? objects;
  final double? detectorMs;
  final double? classificationMs;
  final bool detectionLimitReached;
  final String? species;
  bool get graded => classId != null;

  List<SceneObject> get sceneObjects =>
      objects ??
      [
        if (box != null &&
            status != AnalysisStatus.noMango &&
            status != AnalysisStatus.noFruit)
          SceneObject(
            box: box!,
            detectionScore: 1,
            classId: classId,
            probabilities: probabilities,
            status: status,
            species: species,
          ),
      ];

  double? get confidence => graded ? probabilities[classId!] : null;
}

enum WorkPhase { idle, prepare, picking, image, video }

class VideoPoint {
  const VideoPoint(
    this.timestampMs,
    this.status,
    this.classId,
    this.confidence, {
    this.objectCount,
  });
  final int timestampMs;
  final AnalysisStatus status;
  final int? classId;
  final double? confidence;
  final int? objectCount;
}

class MediaSelection {
  const MediaSelection(
    this.path, {
    this.isVideo = false,
    this.label = 'Ảnh đã chọn',
  });

  final String path;
  final bool isVideo;
  final String label;
}

/// Owns one native operation at a time; the method channel is the native boundary.
class MangoController extends ChangeNotifier {
  MangoController({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vn.mangodemo/inference');

  final MethodChannel _channel;
  bool _disposed = false;
  RuntimeInfo? runtime;
  AnalysisResult? result;
  String? selectedPath;
  String mediaLabel = '';
  String? error;
  WorkPhase phase = WorkPhase.idle;
  bool isVideo = false;
  bool cancelRequested = false;
  bool videoCanceled = false;
  int videoDurationMs = 0;
  int sampleIntervalMs = 1000;
  int completedSamples = 0;
  int totalSamples = 0;
  int videoTimestampMs = 0;
  double videoProcessingFps = 0;
  bool videoReachedEnd = false;
  int previewVersion = 0;
  final List<VideoPoint> _videoPoints = [];
  final FruitTracker _tracker = FruitTracker();
  FruitLineCounter? _lineCounter;
  FruitLineCounter? get lineCounter => _lineCounter;
  FruitCountSummary get countSummary =>
      _lineCounter?.summary ?? _tracker.summary;
  FruitCountSummary get trackingSummary => _tracker.summary;

  /// Counting configuration may change only between native operations.
  /// Selecting a mode starts fresh counts; new media preserves the configuration.
  void setCountingLine(FruitLineCounter? counter) {
    if (_disposed || busy) {
      throw StateError(
        'Stop the current media operation before changing counts',
      );
    }
    _tracker.reset();
    _lineCounter = counter;
    _lineCounter?.reset();
    _changed();
  }

  List<VideoPoint> get videoPoints => List.unmodifiable(_videoPoints);
  double get videoProgress => videoReachedEnd
      ? 1
      : videoDurationMs == 0
      ? 0
      : (videoTimestampMs / videoDurationMs).clamp(0, 1);

  bool get busy => phase != WorkPhase.idle;
  bool get canSelect => runtime != null && !busy;

  Future<void> prepare() async {
    if (busy || _disposed) return;
    phase = WorkPhase.prepare;
    error = null;
    _changed();
    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'prepare',
      );
      if (_disposed) return;
      if (response == null) {
        throw const FormatException('Không nhận được model.');
      }
      runtime = RuntimeInfo.fromMap(response);
    } catch (exception) {
      if (!_disposed) error = _errorMessage(exception);
    } finally {
      phase = WorkPhase.idle;
      _changed();
    }
  }

  Future<void> analyzeImage(String path, {String label = 'Ảnh đã chọn'}) async {
    if (!canSelect || _disposed) return;
    phase = WorkPhase.image;
    _resetMedia(path, label);
    _changed();
    try {
      await _image(path);
    } catch (exception) {
      if (!_disposed) error = _errorMessage(exception);
    } finally {
      phase = WorkPhase.idle;
      _changed();
    }
  }

  Future<void> selectMedia(Future<MediaSelection?> Function() picker) async {
    if (!canSelect || _disposed) return;
    phase = WorkPhase.picking;
    error = null;
    _changed();
    try {
      final selection = await picker();
      if (selection == null || _disposed) return;
      _resetMedia(selection.path, selection.label, video: selection.isVideo);
      phase = selection.isVideo ? WorkPhase.video : WorkPhase.image;
      _changed();
      if (selection.isVideo) {
        await _video(selection.path);
      } else {
        await _image(selection.path);
      }
    } catch (exception) {
      if (!_disposed) error = _errorMessage(exception);
    } finally {
      phase = WorkPhase.idle;
      _changed();
    }
  }

  Future<void> _image(String path) async {
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'analyzeImage',
      {'path': path},
    );
    if (_disposed) return;
    if (response == null) {
      throw const FormatException('Không nhận được kết quả.');
    }
    result = AnalysisResult.fromMap(response);
    previewVersion++;
  }

  Future<void> _video(String path) async {
    final info = await _channel.invokeMapMethod<Object?, Object?>(
      'openVideoSequence',
      {'path': path},
    );
    final clock = Stopwatch()..start();
    try {
      if (_disposed || cancelRequested) {
        videoCanceled = cancelRequested;
        return;
      }
      if (info == null || info['durationMs'] is! num) {
        throw const FormatException('Không đọc được thời lượng video.');
      }
      videoDurationMs = (info['durationMs'] as num).toInt();
      if (videoDurationMs <= 0) {
        throw const FormatException('Video rỗng hoặc bị hỏng.');
      }
      if (videoDurationMs > 600000) {
        throw const FormatException(
          'Hãy chia video thành đoạn tối đa 10 phút để theo dõi đủ dày và giữ bộ nhớ ổn định.',
        );
      }
      sampleIntervalMs = 0;
      totalSamples = (info['estimatedFrameCount'] as num?)?.toInt() ?? 0;
      var previousTimestamp = -1;
      _changed();
      while (true) {
        if (_disposed || cancelRequested) break;
        final response = await _channel.invokeMapMethod<Object?, Object?>(
          'nextVideoFrame',
          {'path': path},
        );
        if (_disposed) return;
        if (response == null) {
          throw const FormatException('Không nhận được khung hình.');
        }
        if (response['endOfStream'] == true) {
          videoReachedEnd = true;
          totalSamples = completedSamples;
          break;
        }
        final timeMs = (response['timestampMs'] as num?)?.toInt();
        if (timeMs == null ||
            timeMs <= previousTimestamp ||
            timeMs < 0 ||
            timeMs >= videoDurationMs) {
          throw const FormatException(
            'Timestamp video không tăng hoặc ngoài thời lượng.',
          );
        }
        previousTimestamp = timeMs;
        final frame = AnalysisResult.fromMap({
          ...response,
          'timestampMs': timeMs,
        });
        final previewUpdated = response['previewUpdated'] != false;
        if (previewUpdated) result = frame;
        final tracks = _tracker.update(timeMs, [
          for (final object in frame.sceneObjects)
            FruitObservation(
              box: object.box,
              classId: object.status == AnalysisStatus.ok
                  ? object.classId
                  : null,
              confidence: object.status == AnalysisStatus.ok
                  ? object.confidence
                  : null,
              species: object.species,
            ),
        ]);
        _lineCounter?.update(timeMs, [
          for (final track in tracks)
            if (track.observations >= _tracker.minimumObservations)
              FruitLineObservation(
                trackId: track.id,
                box: track.box,
                grade: track.grade,
              ),
        ]);
        if (previewUpdated) previewVersion++;
        completedSamples++;
        videoTimestampMs = timeMs;
        videoProcessingFps =
            completedSamples *
            1000 /
            clock.elapsedMilliseconds.clamp(1, 1 << 53);
        _videoPoints.add(
          VideoPoint(
            timeMs,
            frame.status,
            frame.classId,
            frame.confidence,
            objectCount: frame.objects?.length,
          ),
        );
        if (_videoPoints.length > 12) _videoPoints.removeAt(0);
        if (previewUpdated) _changed();
        if (cancelRequested) break;
      }
      videoCanceled = cancelRequested;
    } finally {
      clock.stop();
      await _channel.invokeMethod<void>('closeVideoSequence');
    }
  }

  void cancelVideo() {
    if (phase != WorkPhase.video || cancelRequested || _disposed) return;
    cancelRequested = true;
    _changed();
  }

  void _resetMedia(String path, String label, {bool video = false}) {
    selectedPath = path;
    mediaLabel = label;
    result = null;
    error = null;
    isVideo = video;
    cancelRequested = false;
    videoCanceled = false;
    videoDurationMs = 0;
    completedSamples = 0;
    totalSamples = 0;
    videoTimestampMs = 0;
    videoProcessingFps = 0;
    videoReachedEnd = false;
    _videoPoints.clear();
    _tracker.reset();
    _lineCounter?.reset();
    previewVersion++;
  }

  void reportError(Object exception) {
    if (_disposed) return;
    error = _errorMessage(exception);
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String _errorMessage(Object exception) => switch (exception) {
    PlatformException(:final message, :final code) =>
      message ?? 'Không thể xử lý media ($code).',
    MissingPluginException() => 'Runtime Android chưa được cài vào ứng dụng.',
    FormatException(:final message) => 'Dữ liệu mô hình: $message',
    _ => 'Không thể xử lý media: $exception',
  };

  @override
  void dispose() {
    cancelRequested = true;
    _disposed = true;
    unawaited(_close());
    super.dispose();
  }

  Future<void> _close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException catch (exception) {
      debugPrint('Could not close native runtime: ${exception.code}');
    } on MissingPluginException {
      // A desktop preview has no Android runtime to close.
    }
  }
}
