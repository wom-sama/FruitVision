import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'inference.dart';
import 'fruit_line_counter.dart';
import 'fruit_tracking.dart';

abstract interface class LiveCameraBackend {
  Stream<Object?> get events;
  Future<void> start({
    required int viewId,
    required String lensFacing,
    required int maxFps,
  });
  Future<void> stop();
  Future<Map<Object?, Object?>> stats();
  Future<void> annotate(int timestampMs, List<int> trackIds);
}

/// Only control messages and measurements cross this boundary; camera pixels stay native.
class PlatformLiveCameraBackend implements LiveCameraBackend {
  PlatformLiveCameraBackend({
    MethodChannel? methods,
    EventChannel? eventChannel,
  }) : _methods = methods ?? const MethodChannel('vn.mangodemo/live_camera'),
       _events =
           eventChannel ??
           const EventChannel('vn.mangodemo/live_camera/events');

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Stream<Object?> get events => _events.receiveBroadcastStream();

  @override
  Future<void> start({
    required int viewId,
    required String lensFacing,
    required int maxFps,
  }) async {
    final response = await _methods.invokeMapMethod<Object?, Object?>('start', {
      'viewId': viewId,
      'lensFacing': lensFacing,
      'maxFps': maxFps,
    });
    if (response?['started'] != true) {
      throw const FormatException('Camera chưa xác nhận khởi động.');
    }
  }

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  @override
  Future<void> annotate(int timestampMs, List<int> trackIds) =>
      _methods.invokeMethod<void>('annotate', {
        'timestampMs': timestampMs,
        'trackIds': trackIds,
      });

  @override
  Future<Map<Object?, Object?>> stats() async =>
      await _methods.invokeMapMethod<Object?, Object?>('stats') ?? {};
}

enum LiveCameraPhase { idle, starting, running, stopping, error }

enum LiveFrameStatus { ok, uncertain, noMango, unsupportedSpecies, noFruit }

double _nonnegativeNumber(Map<Object?, Object?> data, String key) {
  final value = data[key];
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException('Số đo $key không hợp lệ.');
  }
  return value.toDouble();
}

int _integer(Map<Object?, Object?> data, String key, {int minimum = 0}) {
  final value = _nonnegativeNumber(data, key);
  if (value != value.roundToDouble() || value < minimum) {
    throw FormatException('Giá trị $key không hợp lệ.');
  }
  return value.toInt();
}

class LivePerformance {
  LivePerformance.fromMap(Map<Object?, Object?> data)
    : values = Map.unmodifiable({
        for (final key in const [
          'inferenceFps',
          'analyzerFps',
          'maxFps',
          'modelP50Ms',
          'modelP95Ms',
          'pipelineP50Ms',
          'pipelineP95Ms',
          'conversionP95Ms',
          'callbackToOverlayP95Ms',
          'pssMb',
          'uptimeMs',
        ])
          key: _nonnegativeNumber(data, key),
        for (final key in const [
          'processed',
          'skipped',
          'delivered',
          'sampleCount',
        ])
          key: _integer(data, key).toDouble(),
        for (final key in const ['analysisWidth', 'analysisHeight'])
          key: _integer(data, key, minimum: 1).toDouble(),
        if (data.containsKey('effectiveMaxFps'))
          'effectiveMaxFps': _nonnegativeNumber(data, 'effectiveMaxFps'),
        if (data.containsKey('thermalStatus'))
          'thermalStatus': _integer(data, 'thermalStatus').toDouble(),
      });

  final Map<String, double> values;
  double number(String key) => values[key]!;
  int count(String key) => number(key).toInt();
}

class LiveFrame {
  const LiveFrame({
    required this.classId,
    required this.status,
    required this.probabilities,
    required this.imageWidth,
    required this.imageHeight,
    required this.modelMs,
    required this.preprocessMs,
    required this.elapsedMs,
    required this.performance,
    this.box,
    this.objects,
    this.detectorMs,
    this.classificationMs,
    this.detectionLimitReached = false,
    this.timestampMs,
    this.species,
  });

  factory LiveFrame.fromMap(Map<Object?, Object?> data) {
    final status = switch (data['status']) {
      'OK' => LiveFrameStatus.ok,
      'UNCERTAIN' => LiveFrameStatus.uncertain,
      'NO_MANGO' => LiveFrameStatus.noMango,
      'UNSUPPORTED_SPECIES' => LiveFrameStatus.unsupportedSpecies,
      'NO_FRUIT' => LiveFrameStatus.noFruit,
      _ => throw const FormatException('Trạng thái mô hình không hợp lệ.'),
    };
    final grade = parseSceneGrade(
      data,
      ungraded:
          status == LiveFrameStatus.unsupportedSpecies ||
          status == LiveFrameStatus.noFruit,
    );
    final box = parseNormalizedBox(data['box']);
    final rawStats = data['stats'];
    if (rawStats is! Map) {
      throw const FormatException('Thiếu số đo phiên camera.');
    }
    return LiveFrame(
      classId: grade.classId,
      status: status,
      probabilities: grade.probabilities,
      box: box,
      imageWidth: _integer(data, 'imageWidth', minimum: 1),
      imageHeight: _integer(data, 'imageHeight', minimum: 1),
      modelMs: _nonnegativeNumber(data, 'modelMs'),
      preprocessMs: _nonnegativeNumber(data, 'preprocessMs'),
      elapsedMs: _nonnegativeNumber(data, 'elapsedMs'),
      performance: LivePerformance.fromMap(
        Map<Object?, Object?>.from(rawStats),
      ),
      objects: SceneObject.listFromMap(data),
      detectorMs: optionalSceneMeasurement(data, 'detectorMs'),
      classificationMs: optionalSceneMeasurement(data, 'classificationMs'),
      detectionLimitReached: parseDetectionLimit(data),
      timestampMs: parseSceneTimestamp(data),
      species: parseSpecies(data),
    );
  }

  final int? classId;
  final LiveFrameStatus status;
  final List<double> probabilities;
  final Rect? box;
  final int imageWidth;
  final int imageHeight;
  final double modelMs;
  final double preprocessMs;
  final double elapsedMs;
  final LivePerformance performance;
  final List<SceneObject>? objects;
  final double? detectorMs;
  final double? classificationMs;
  final bool detectionLimitReached;
  final int? timestampMs;
  final String? species;
  bool get graded => classId != null;
  List<SceneObject> get sceneObjects =>
      objects ??
      [
        if (box != null &&
            status != LiveFrameStatus.noMango &&
            status != LiveFrameStatus.noFruit)
          SceneObject(
            box: box!,
            detectionScore: 1,
            classId: classId,
            probabilities: probabilities,
            status: switch (status) {
              LiveFrameStatus.ok => AnalysisStatus.ok,
              LiveFrameStatus.unsupportedSpecies =>
                AnalysisStatus.unsupportedSpecies,
              _ => AnalysisStatus.uncertain,
            },
            species: species,
          ),
      ];
  double? get confidence => graded ? probabilities[classId!] : null;
}

/// Serializes native ownership and invalidates callbacks before releasing a session.
class LiveCameraController extends ChangeNotifier {
  LiveCameraController({LiveCameraBackend? backend})
    : _backend = backend ?? PlatformLiveCameraBackend();

  final LiveCameraBackend _backend;
  StreamSubscription<Object?>? _subscription;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  bool _foreground = true;
  bool _sessionOpen = false;
  int _generation = 0;
  int _intent = 0;
  int? _viewId;
  LiveCameraPhase phase = LiveCameraPhase.idle;
  String lensFacing = 'back';
  String? error;
  LiveFrame? result;
  final FruitTracker _tracker = FruitTracker();
  FruitLineCounter? _lineCounter;
  FruitLineCounter? get lineCounter => _lineCounter;
  FruitCountSummary get countSummary =>
      _lineCounter?.summary ?? _tracker.summary;
  FruitCountSummary get trackingSummary => _tracker.summary;
  int? _lastTrackingTimestamp;
  bool get sessionActive => _sessionOpen;
  bool get busy =>
      phase == LiveCameraPhase.starting || phase == LiveCameraPhase.stopping;
  bool get canStart =>
      !_disposed &&
      _foreground &&
      _viewId != null &&
      !busy &&
      !_sessionOpen &&
      phase != LiveCameraPhase.running;
  bool get canStop =>
      !_disposed && _sessionOpen && phase != LiveCameraPhase.stopping;
  bool get canSwitchLens => !_disposed && _foreground && !busy;
  Future<void> get settled => _tail;
  Future<void> get closed => _tail;

  /// Configure counting only while idle with the native session closed.
  /// Session restarts reset counts while retaining this line configuration.
  void setCountingLine(FruitLineCounter? counter) {
    if (_disposed || busy || _sessionOpen || phase != LiveCameraPhase.idle) {
      throw StateError('Stop the live camera before changing counts');
    }
    _tracker.reset();
    _lastTrackingTimestamp = null;
    _lineCounter = counter;
    _lineCounter?.reset();
    _changed();
  }

  void attachPreview(int viewId) {
    if (_disposed || viewId < 0) return;
    _viewId = viewId;
    _changed();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _tail = _tail.then((_) => operation());
    return _tail;
  }

  Future<void> start() {
    if (!canStart) return Future.value();
    _intent++;
    final generation = ++_generation;
    phase = LiveCameraPhase.starting;
    error = null;
    result = null;
    _tracker.reset();
    _lineCounter?.reset();
    _lastTrackingTimestamp = null;
    _sessionOpen = true;
    _changed();
    return _enqueue(() async {
      try {
        if (generation != _generation || _disposed) return;
        // Subscribe before starting: native can publish state while the method is pending.
        if (generation == _generation && !_disposed) {
          _subscription = _backend.events.listen(
            (event) => _onEvent(event, generation),
            onError: (Object exception) =>
                _onStreamError(exception, generation),
          );
        }
        await _backend.start(
          viewId: _viewId!,
          lensFacing: lensFacing,
          maxFps: 30,
        );
        if (generation == _generation && !_disposed) {
          phase = LiveCameraPhase.running;
          _changed();
        }
      } catch (exception) {
        if (generation != _generation || _disposed) return;
        error = _friendlyError(exception);
        final cleanupGeneration = ++_generation;
        await _cancelSubscription();
        try {
          await _backend.stop();
          _sessionOpen = false;
        } catch (stopError) {
          error = '${error!}\n${_friendlyError(stopError)}';
        }
        if (cleanupGeneration == _generation && !_disposed) {
          phase = LiveCameraPhase.error;
        }
        _changed();
      }
    });
  }

  Future<void> stop() {
    _intent++;
    return _stop();
  }

  Future<void> _cancelSubscription() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  Future<void> _stop({String? failure}) {
    if (phase == LiveCameraPhase.stopping) return _tail;
    if (!_sessionOpen) return _tail;
    _generation++;
    if (failure != null) {
      result = null;
      error = failure;
    }
    final cancellation = _cancelSubscription();
    phase = LiveCameraPhase.stopping;
    final pendingStart = _tail;
    // Android stop cancels a permission/first-frame start reply before draining work.
    // Sending it now prevents a start reply from blocking privacy-related shutdown.
    final nativeStop = Future<void>.sync(_backend.stop);
    _tail = () async {
      try {
        await nativeStop;
        await cancellation;
        await pendingStart;
        _sessionOpen = false;
        phase = failure == null ? LiveCameraPhase.idle : LiveCameraPhase.error;
        error = failure;
      } catch (exception) {
        phase = LiveCameraPhase.error;
        error = _friendlyError(exception);
      }
      _changed();
    }();
    _changed();
    return _tail;
  }

  Future<void> switchLens() async {
    if (!canSwitchLens) return;
    final intent = ++_intent;
    final restart = phase == LiveCameraPhase.running;
    final nextLens = lensFacing == 'back' ? 'front' : 'back';
    await _stop();
    if (_disposed || !_foreground || intent != _intent || _sessionOpen) return;
    lensFacing = nextLens;
    _changed();
    if (restart) await start();
  }

  Future<void> handleLifecycle(AppLifecycleState state) {
    if (_disposed) return Future.value();
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _changed();
      return Future.value();
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      return stop();
    }
    // Permission dialogs may make the app inactive while camera start is pending.
    return Future.value();
  }

  void _onStreamError(Object exception, int generation) {
    if (!_disposed && generation == _generation) {
      unawaited(_stop(failure: _friendlyError(exception)));
    }
  }

  void _onEvent(Object? event, int generation) {
    if (_disposed || generation != _generation || !_sessionOpen) return;
    try {
      if (event is! Map) {
        throw const FormatException('Sự kiện camera không hợp lệ.');
      }
      final data = Map<Object?, Object?>.from(event);
      if (data['type'] == 'frame') {
        result = LiveFrame.fromMap(data);
        // Native timestamps are monotonic. Legacy events have no tracking timestamp.
        final timestamp = result!.timestampMs;
        if (timestamp != null &&
            (_lastTrackingTimestamp == null ||
                timestamp > _lastTrackingTimestamp!)) {
          final tracks = _tracker.update(timestamp, [
            for (final object in result!.sceneObjects)
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
          _lineCounter?.update(timestamp, [
            for (final track in tracks)
              if (track.observations >= _tracker.minimumObservations)
                FruitLineObservation(
                  trackId: track.id,
                  box: track.box,
                  grade: track.grade,
                ),
          ]);
          _lastTrackingTimestamp = timestamp;
          unawaited(
            _annotate(
              timestamp,
              tracks.map((track) => track.id).toList(),
              generation,
            ),
          );
        }
        error = null;
        _changed();
      } else if (data['type'] == 'state') {
        switch (data['state']) {
          case 'error':
            final message = data['message'];
            unawaited(
              _stop(
                failure: message is String && message.isNotEmpty
                    ? message
                    : 'Camera gặp lỗi. Hãy thử khởi động lại.',
              ),
            );
          case 'stopped':
            unawaited(_stop());
          case 'starting':
          case 'running':
            // The serialized start response owns the state transition.
            break;
          default:
            throw const FormatException('Trạng thái camera không hợp lệ.');
        }
      } else {
        throw const FormatException('Sự kiện camera không hợp lệ.');
      }
    } catch (exception) {
      unawaited(_stop(failure: _friendlyError(exception)));
    }
  }

  Future<void> _annotate(int timestampMs, List<int> ids, int generation) async {
    try {
      await _backend.annotate(timestampMs, ids);
    } catch (exception) {
      if (!_disposed && generation == _generation && _sessionOpen) {
        await _stop(failure: _friendlyError(exception));
      }
    }
  }

  String _friendlyError(Object exception) => switch (exception) {
    PlatformException(code: 'PERMISSION') => 'Cần quyền camera để xem trực tiếp. Hãy cho phép camera khi thử lại; nếu đã từ chối vĩnh viễn, mở Cài đặt ứng dụng để cấp quyền.',
    PlatformException(code: 'NO_CAMERA') =>
      'Không tìm thấy camera đã chọn. Thử đổi camera hoặc kiểm tra thiết bị.',
    PlatformException(code: 'BUSY') =>
      'Một tác vụ xử lý khác đang chạy. Hãy dừng tác vụ đó rồi thử lại.',
    PlatformException(:final message) =>
      message ?? 'Camera chưa sẵn sàng. Hãy thử lại.',
    MissingPluginException() =>
      'Camera trực tiếp cần ứng dụng Android trên thiết bị thật.',
    FormatException(:final message) => message,
    _ => 'Camera gặp lỗi: $exception',
  };

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _foreground = false;
    _intent++;
    unawaited(_stop());
    super.dispose();
  }
}
