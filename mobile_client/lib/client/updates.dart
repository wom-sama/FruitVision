import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart' show ApiClient;

class UpdateAppInfo {
  const UpdateAppInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.abis,
    required this.canRequestInstalls,
  });
  final String packageName, versionName;
  final int versionCode;
  final List<String> abis;
  final bool canRequestInstalls;
}

class UpdateProgress {
  const UpdateProgress(this.downloaded, this.total);
  final int downloaded, total;
}

class DownloadedUpdate {
  const DownloadedUpdate({
    required this.path,
    required this.versionName,
    required this.versionCode,
    required this.sizeBytes,
  });
  final String path, versionName;
  final int versionCode, sizeBytes;
}

abstract interface class UpdatePlatform {
  Stream<UpdateProgress> get progress;
  Future<UpdateAppInfo?> info();
  Future<DownloadedUpdate?> cached({
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  });
  Future<DownloadedUpdate> download({
    required String baseUrl,
    required String downloadPath,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  });
  Future<void> cancel();
  Future<void> requestPermission();
  Future<bool> install({
    required String path,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  });
  Future<void> delete(String path);
  void dispose();
}

abstract interface class UpdateManifestClient {
  Future<Map<String, dynamic>> fetch(Uri uri);
  void cancel();
  void dispose();
}

class UpdateRelease {
  const UpdateRelease({
    required this.versionName,
    required this.versionCode,
    required this.minimumCode,
    required this.sizeBytes,
    required this.sha256,
    required this.downloadPath,
    required this.notes,
    required this.mandatory,
    this.publishedAt,
  });
  final String versionName, sha256, downloadPath, notes;
  final int versionCode, minimumCode, sizeBytes;
  final bool mandatory;
  final String? publishedAt;
}

enum UpdateStatus {
  idle,
  checking,
  unsupported,
  unavailable,
  current,
  available,
  downloading,
  cancelling,
  permissionRequired,
  ready,
  installerOpened,
  error,
}

class UpdateController extends ChangeNotifier {
  UpdateController({required this.platform, required this.client}) {
    _progress = platform.progress.listen((event) {
      final update = release;
      if (!_disposed &&
          status == UpdateStatus.downloading &&
          update != null &&
          event.downloaded >= 0) {
        progress = (event.downloaded / update.sizeBytes).clamp(0.0, 1.0);
        _emit();
      }
    });
  }
  final UpdatePlatform platform;
  final UpdateManifestClient client;
  late final StreamSubscription<UpdateProgress> _progress;
  final _checked = <String>{}, _prompted = <String>{};
  UpdateStatus status = UpdateStatus.idle;
  UpdateRelease? release;
  UpdateAppInfo? installed;
  String baseUrl = '', error = '', notice = '';
  double progress = 0;
  DownloadedUpdate? candidate;
  bool _disposed = false, _infoRead = false;
  int _epoch = 0;
  Future<void>? _checkTask, _downloadTask, _installTask;
  String? _checkServer;
  bool get mandatory => release?.mandatory ?? false;
  bool get busy =>
      _downloadTask != null ||
      _installTask != null ||
      status == UpdateStatus.checking ||
      status == UpdateStatus.cancelling;
  String get startupKey => '$baseUrl:${installed?.versionCode}';
  bool prompted(String key) => _prompted.contains(key);
  void markPrompted(String key) => _prompted.add(key);
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void setServer(String url) {
    if (_disposed) return;
    final normalized = ApiClient.validateBaseUrl(url);
    if (normalized == baseUrl) return;
    ++_epoch;
    client.cancel();
    if (_downloadTask != null) unawaited(_cancelNative());
    final old = candidate;
    candidate = null;
    if (old != null) unawaited(_delete(old.path));
    baseUrl = normalized;
    release = null;
    error = '';
    notice = '';
    progress = 0;
    status = UpdateStatus.idle;
    _emit();
  }

  Future<void> check(String url, {bool force = false}) {
    if (_disposed) return Future.value();
    try {
      setServer(url);
    } catch (_) {
      status = UpdateStatus.error;
      error = 'Địa chỉ máy chủ cần là gốc HTTPS hợp lệ.';
      _emit();
      return Future.value();
    }
    if (_installTask != null ||
        status == UpdateStatus.downloading ||
        status == UpdateStatus.cancelling) {
      return Future.value();
    }
    if (_checkTask != null && _checkServer == baseUrl) return _checkTask!;
    final task = _runCheck(force: force);
    _checkTask = task;
    _checkServer = baseUrl;
    return task.whenComplete(() {
      if (identical(_checkTask, task)) {
        _checkTask = null;
        _checkServer = null;
      }
    });
  }

  Future<void> _runCheck({required bool force}) async {
    final epoch = _epoch, server = baseUrl;
    final previous = status;
    status = UpdateStatus.checking;
    error = '';
    notice = '';
    _emit();
    try {
      final info = !_infoRead || force ? await platform.info() : installed;
      if (!_current(epoch)) return;
      _infoRead = true;
      installed = info;
      if (info == null) {
        status = UpdateStatus.unsupported;
        _emit();
        return;
      }
      final key = startupKey;
      if (!force && _checked.contains(key)) {
        status = previous;
        _emit();
        return;
      }
      final abi = info.abis
          .where(const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains)
          .firstOrNull;
      if (abi == null) {
        status = UpdateStatus.unsupported;
        _checked.add(key);
        _emit();
        return;
      }
      _checked.add(key);
      final response = await client.fetch(
        Uri.parse('$server/api/v1/mobile/update').replace(
          queryParameters: {'versionCode': '${info.versionCode}', 'abi': abi},
        ),
      );
      if (!_current(epoch)) return;
      if (response['schemaVersion'] != 1) throw const FormatException('schema');
      if (response['updateServiceEnabled'] != true) {
        release = null;
        status = UpdateStatus.unavailable;
        _emit();
        return;
      }
      final code = response['latestVersionCode'];
      if (code is int && code <= info.versionCode) {
        release = null;
        status = UpdateStatus.current;
        _emit();
        return;
      }
      if (response['available'] != true) {
        release = null;
        status = UpdateStatus.unavailable;
        _emit();
        return;
      }
      final next = _parse(response, info.versionCode, abi);
      release = next;
      if (candidate?.versionCode != next.versionCode ||
          candidate?.sizeBytes != next.sizeBytes) {
        final previousCandidate = candidate;
        candidate = null;
        if (previousCandidate != null) await _delete(previousCandidate.path);
        if (!_current(epoch)) return;
        DownloadedUpdate? restored;
        try {
          restored = await platform.cached(
            sha256: next.sha256,
            sizeBytes: next.sizeBytes,
            versionCode: next.versionCode,
          );
        } catch (_) {
          if (_current(epoch)) {
            notice = 'Không khôi phục được gói tải trước. Bạn có thể tải lại.';
          }
        }
        if (!_current(epoch)) {
          if (restored != null && restored.path.isNotEmpty) {
            await _delete(restored.path);
          }
          return;
        }
        if (restored != null) {
          if (restored.path.isNotEmpty &&
              restored.versionCode == next.versionCode &&
              restored.sizeBytes == next.sizeBytes) {
            candidate = restored;
            progress = 1;
            notice = 'Đã khôi phục gói cập nhật đã xác minh trên thiết bị.';
          } else if (restored.path.isNotEmpty) {
            await _delete(restored.path);
          }
        }
        if (!_current(epoch)) return;
      }
      status = candidate?.versionCode == next.versionCode
          ? _readyStatus()
          : UpdateStatus.available;
      _emit();
    } catch (_) {
      if (_current(epoch)) {
        status = UpdateStatus.error;
        error = 'Không kiểm tra được cập nhật. Kiểm tra mạng hoặc thử lại sau.';
        _emit();
      }
    }
  }

  UpdateRelease _parse(Map<String, dynamic> json, int currentCode, String abi) {
    final code = json['latestVersionCode'],
        minimum = json['minimumSupportedVersionCode'],
        size = json['apkSizeBytes'];
    final name = json['latestVersionName'],
        hash = json['sha256'],
        path = json['downloadPath'];
    if (code is! int ||
        code <= currentCode ||
        minimum is! int ||
        minimum < 1 ||
        minimum > code ||
        size is! int ||
        size <= 0 ||
        size > 80 * 1024 * 1024 ||
        name is! String ||
        name.trim().isEmpty ||
        hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
        path is! String) {
      throw const FormatException('descriptor');
    }
    if (path != '/api/v1/mobile/releases/$code/$abi.apk') {
      throw const FormatException('path');
    }
    final notesValue = json['notes'];
    var notes = notesValue is String
        ? notesValue
        : notesValue is List
        ? notesValue.whereType<String>().join('\n')
        : '';
    if (notes.length > 4000) notes = notes.substring(0, 4000);
    return UpdateRelease(
      versionName: name,
      versionCode: code,
      minimumCode: minimum,
      sizeBytes: size,
      sha256: hash.toLowerCase(),
      downloadPath: path,
      notes: notes,
      mandatory: json['mandatory'] == true || currentCode < minimum,
      publishedAt: json['publishedAt'] is String
          ? json['publishedAt'] as String
          : null,
    );
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  UpdateStatus _readyStatus() => installed?.canRequestInstalls == true
      ? UpdateStatus.ready
      : UpdateStatus.permissionRequired;
  Future<void> download() {
    if (_disposed || release == null || candidate != null) {
      return Future.value();
    }
    if (_downloadTask != null) return _downloadTask!;
    final task = _download();
    _downloadTask = task;
    return task.whenComplete(() {
      if (identical(_downloadTask, task)) {
        _downloadTask = null;
        _emit();
      }
    });
  }

  Future<void> _download() async {
    final update = release!, server = baseUrl, epoch = _epoch;
    error = '';
    notice = '';
    progress = 0;
    status = UpdateStatus.downloading;
    _emit();
    try {
      final info = await platform.info();
      if (!_current(epoch)) return;
      installed = info;
      if (info == null) throw const FormatException('platform');
      if (info.versionCode >= update.versionCode) {
        release = null;
        status = UpdateStatus.current;
        _emit();
        return;
      }
      final artifact = await platform.download(
        baseUrl: server,
        downloadPath: update.downloadPath,
        sha256: update.sha256,
        sizeBytes: update.sizeBytes,
        versionCode: update.versionCode,
      );
      if (!_current(epoch)) {
        await _delete(artifact.path);
        return;
      }
      if (artifact.path.isEmpty ||
          artifact.versionCode != update.versionCode ||
          artifact.sizeBytes != update.sizeBytes) {
        if (artifact.path.isNotEmpty) await _delete(artifact.path);
        throw const FormatException('native descriptor mismatch');
      }
      candidate = artifact;
      progress = 1;
      status = _readyStatus();
      _emit();
    } catch (e) {
      if (!_current(epoch)) return;
      if (e is PlatformException && e.code == 'UPDATE_CANCELLED') {
        status = UpdateStatus.available;
        notice = 'Đã hủy tải bản cập nhật.';
      } else {
        status = UpdateStatus.error;
        error =
            'Không tải được gói cập nhật hoặc gói không hợp lệ. Hãy thử lại.';
      }
      _emit();
    }
  }

  Future<void> _cancelNative() async {
    try {
      await platform.cancel();
    } catch (_) {
      if (!_disposed) {
        notice = 'Chưa xác nhận dừng tải. Hãy đợi tác vụ hiện tại kết thúc.';
        _emit();
      }
    }
  }

  Future<void> _delete(String path) async {
    try {
      await platform.delete(path);
    } catch (_) {
      if (!_disposed) {
        notice = 'Chưa xóa được tệp cập nhật tạm trên thiết bị.';
        _emit();
      }
    }
  }

  Future<void> cancelDownload() async {
    if (_disposed) return;
    final epoch = ++_epoch;
    status = UpdateStatus.cancelling;
    error = '';
    _emit();
    if (_downloadTask != null) await _cancelNative();
    final old = candidate;
    candidate = null;
    if (old != null) await _delete(old.path);
    if (!_current(epoch)) return;
    progress = 0;
    status = release == null ? UpdateStatus.current : UpdateStatus.available;
    notice = 'Đã hủy tải hoặc bỏ gói cập nhật tạm.';
    _emit();
  }

  Future<void> requestPermission() async {
    if (_disposed || candidate == null) return;
    try {
      await platform.requestPermission();
      notice = 'Cho phép ứng dụng này cài APK, rồi quay lại để tiếp tục.';
    } catch (_) {
      error = 'Không mở được cài đặt quyền. Bạn có thể thử lại.';
    }
    _emit();
  }

  Future<void> resume() async {
    if (_disposed || candidate == null || release == null) return;
    final epoch = _epoch;
    try {
      final info = await platform.info();
      if (!_current(epoch) || info == null) return;
      installed = info;
      if (info.versionCode >= release!.versionCode) {
        final old = candidate;
        candidate = null;
        release = null;
        status = UpdateStatus.current;
        notice = 'Đã xác nhận phiên bản mới trên thiết bị.';
        if (old != null) await _delete(old.path);
      } else {
        status = _readyStatus();
      }
      _emit();
    } catch (_) {
      if (_current(epoch)) {
        error = 'Không đọc được quyền cài đặt. Hãy kiểm tra lại.';
        _emit();
      }
    }
  }

  Future<void> install() {
    if (_installTask != null) return _installTask!;
    if (_disposed || candidate == null || release == null || busy) {
      return Future.value();
    }
    final task = _install();
    _installTask = task;
    _emit();
    return task.whenComplete(() {
      if (identical(_installTask, task)) {
        _installTask = null;
        _emit();
      }
    });
  }

  Future<void> _install() async {
    await resume();
    if (_disposed || candidate == null || release == null) return;
    if (installed?.canRequestInstalls != true) {
      status = UpdateStatus.permissionRequired;
      _emit();
      return;
    }
    final artifact = candidate!, update = release!, epoch = _epoch;
    try {
      final started = await platform.install(
        path: artifact.path,
        sha256: update.sha256,
        sizeBytes: update.sizeBytes,
        versionCode: update.versionCode,
      );
      if (!_current(epoch)) return;
      if (!started) throw const FormatException('installer not started');
      status = UpdateStatus.installerOpened;
      error = '';
      notice = 'Android đã mở trình cài đặt. Bạn cần tự xác nhận việc cài.';
      _emit();
    } catch (e) {
      if (!_current(epoch)) return;
      if (e is PlatformException && e.code == 'UPDATE_PERMISSION') {
        status = UpdateStatus.permissionRequired;
        error = 'Cần cho phép ứng dụng này cài APK trước.';
      } else {
        status = UpdateStatus.error;
        error = 'Không mở được trình cài đặt hoặc gói chưa đạt xác minh.';
      }
      _emit();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_epoch;
    client.dispose();
    unawaited(_progress.cancel());
    if (_downloadTask != null) unawaited(_cancelNative());
    final old = candidate;
    candidate = null;
    if (old != null) unawaited(_delete(old.path));
    platform.dispose();
    super.dispose();
  }
}

UpdateController createUpdateController() => UpdateController(
  platform: !kIsWeb && Platform.isAndroid
      ? AndroidUpdatePlatform()
      : DisabledUpdatePlatform(),
  client: PublicUpdateManifestClient(),
);

class DisabledUpdatePlatform implements UpdatePlatform {
  @override
  Stream<UpdateProgress> get progress => const Stream.empty();
  @override
  Future<UpdateAppInfo?> info() async => null;
  @override
  Future<DownloadedUpdate?> cached({
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async => null;
  @override
  Future<DownloadedUpdate> download({
    required String baseUrl,
    required String downloadPath,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async => throw UnsupportedError('Android only');
  @override
  Future<void> cancel() async {}
  @override
  Future<void> requestPermission() async {}
  @override
  Future<bool> install({
    required String path,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async => false;
  @override
  Future<void> delete(String path) async {}
  @override
  void dispose() {}
}

class AndroidUpdatePlatform implements UpdatePlatform {
  AndroidUpdatePlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vn.fruitvision/updates') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' &&
          call.arguments is Map &&
          !_events.isClosed) {
        final values = call.arguments as Map,
            downloaded = (call.arguments as Map)['downloaded'],
            total = (call.arguments as Map)['total'];
        if (downloaded is num && total is num && values.isNotEmpty) {
          _events.add(UpdateProgress(downloaded.toInt(), total.toInt()));
        }
      }
    });
  }
  final MethodChannel _channel;
  final _events = StreamController<UpdateProgress>.broadcast();
  @override
  Stream<UpdateProgress> get progress => _events.stream;
  @override
  Future<UpdateAppInfo?> info() async {
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('info');
      if (value == null) return null;
      final code = value['versionCode'];
      if (code is! num ||
          code <= 0 ||
          value['packageName'] is! String ||
          value['versionName'] is! String) {
        throw const FormatException('native info');
      }
      return UpdateAppInfo(
        packageName: value['packageName'] as String,
        versionName: value['versionName'] as String,
        versionCode: code.toInt(),
        abis: (value['abis'] as List? ?? []).whereType<String>().toList(),
        canRequestInstalls: value['canRequestInstalls'] == true,
      );
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<DownloadedUpdate?> cached({
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>('cached', {
      'sha256': sha256,
      'sizeBytes': sizeBytes,
      'versionCode': versionCode,
    });
    if (value == null) return null;
    return DownloadedUpdate(
      path: value['path'] as String,
      versionName: value['versionName'] as String,
      versionCode: (value['versionCode'] as num).toInt(),
      sizeBytes: (value['sizeBytes'] as num).toInt(),
    );
  }

  @override
  Future<DownloadedUpdate> download({
    required String baseUrl,
    required String downloadPath,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>('download', {
      'baseUrl': baseUrl,
      'downloadPath': downloadPath,
      'sha256': sha256,
      'sizeBytes': sizeBytes,
      'versionCode': versionCode,
    });
    if (value == null) throw const FormatException('native download');
    return DownloadedUpdate(
      path: value['path'] as String,
      versionName: value['versionName'] as String,
      versionCode: (value['versionCode'] as num).toInt(),
      sizeBytes: (value['sizeBytes'] as num).toInt(),
    );
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
  @override
  Future<void> requestPermission() =>
      _channel.invokeMethod<void>('requestPermission');
  @override
  Future<bool> install({
    required String path,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'install',
      {
        'path': path,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'versionCode': versionCode,
      },
    );
    return response?['started'] == true;
  }

  @override
  Future<void> delete(String path) =>
      _channel.invokeMethod<void>('delete', {'path': path});
  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }
}

class PublicUpdateManifestClient implements UpdateManifestClient {
  final _active = <HttpClient>{};
  bool _closed = false;
  @override
  Future<Map<String, dynamic>> fetch(Uri uri) async {
    if (_closed) throw StateError('Update client disposed');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _active.add(client);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set('Accept', 'application/json');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const HttpException('Update manifest unavailable');
        }
        var bytes = 0;
        final bounded = response.map((chunk) {
          bytes += chunk.length;
          if (bytes > 64 * 1024) {
            throw const FormatException('Manifest too large');
          }
          return chunk;
        });
        final json = jsonDecode(await utf8.decoder.bind(bounded).join());
        if (json is! Map<String, dynamic>) {
          throw const FormatException('Manifest object required');
        }
        return json;
      })().timeout(const Duration(seconds: 15));
    } finally {
      _active.remove(client);
      client.close(force: true);
    }
  }

  @override
  void cancel() {
    for (final client in _active.toList()) {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _closed = true;
    cancel();
  }
}
