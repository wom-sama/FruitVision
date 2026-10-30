import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/updates.dart';

UpdateAppInfo buildInfo({int code = 6004, bool allowed = false}) =>
    UpdateAppInfo(
      packageName: 'vn.fruitvision.test',
      versionName: code == 6004 ? '2.2.0' : '2.2.1',
      versionCode: code,
      abis: ['x86_64', 'x86'],
      canRequestInstalls: allowed,
    );
Map<String, dynamic> manifest({int code = 6005, bool mandatory = false}) => {
  'schemaVersion': 1,
  'updateServiceEnabled': true,
  'available': true,
  'mandatory': mandatory,
  'latestVersionName': '2.2.1',
  'latestVersionCode': code,
  'minimumSupportedVersionCode': mandatory ? 6005 : 6000,
  'apkSizeBytes': 100,
  'sha256': 'a' * 64,
  'downloadPath': '/api/v1/mobile/releases/$code/x86_64.apk',
  'notes': ['Bản cập nhật để kiểm thử.'],
  'publishedAt': '2026-10-30T12:00:00Z',
};

class FakeUpdatePlatform implements UpdatePlatform {
  UpdateAppInfo? value = buildInfo();
  final events = StreamController<UpdateProgress>.broadcast();
  final downloads = <Map<String, Object>>[];
  final deleted = <String>[];
  Completer<DownloadedUpdate>? pending;
  Completer<bool>? pendingInstall;
  DownloadedUpdate? cachedValue;
  Completer<DownloadedUpdate?>? pendingCache;
  final cacheRequests = <Map<String, Object>>[];
  bool completeOnCancel = true;
  int infoCalls = 0, cancelCalls = 0, permissionCalls = 0, installCalls = 0;
  @override
  Stream<UpdateProgress> get progress => events.stream;
  @override
  Future<UpdateAppInfo?> info() async {
    infoCalls++;
    return value;
  }

  @override
  Future<DownloadedUpdate?> cached({
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async {
    cacheRequests.add({
      'sha256': sha256,
      'sizeBytes': sizeBytes,
      'versionCode': versionCode,
    });
    return pendingCache == null ? cachedValue : pendingCache!.future;
  }

  @override
  Future<DownloadedUpdate> download({
    required String baseUrl,
    required String downloadPath,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async {
    downloads.add({
      'baseUrl': baseUrl,
      'downloadPath': downloadPath,
      'sha256': sha256,
      'sizeBytes': sizeBytes,
      'versionCode': versionCode,
    });
    return pending == null
        ? DownloadedUpdate(
            path: '/private/update.apk',
            versionName: '2.2.1',
            versionCode: versionCode,
            sizeBytes: sizeBytes,
          )
        : pending!.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (completeOnCancel && pending != null && !pending!.isCompleted) {
      pending!.completeError(PlatformException(code: 'UPDATE_CANCELLED'));
    }
  }

  @override
  Future<void> requestPermission() async {
    permissionCalls++;
  }

  @override
  Future<bool> install({
    required String path,
    required String sha256,
    required int sizeBytes,
    required int versionCode,
  }) async {
    installCalls++;
    return pendingInstall?.future ?? true;
  }

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
  }

  @override
  void dispose() {
    unawaited(events.close());
  }
}

class FakeManifestClient implements UpdateManifestClient {
  Map<String, dynamic> value = manifest();
  final requests = <Uri>[];
  bool fail = false;
  @override
  Future<Map<String, dynamic>> fetch(Uri uri) async {
    requests.add(uri);
    if (fail) throw const SocketException('offline');
    return uri.host == 'second.test' ? manifest(code: 6006) : value;
  }

  @override
  void cancel() {}
  @override
  void dispose() {}
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('startup checks once per server and installed code, sharing concurrent checks', () async {
    final native = FakeUpdatePlatform();
    final client = FakeManifestClient();
    final updater = UpdateController(platform: native, client: client);
    addTearDown(updater.dispose);
    await Future.wait([
      updater.check('https://first.test'),
      updater.check('https://first.test'),
    ]);
    await updater.check('https://first.test');
    expect(client.requests, hasLength(1));
    expect(client.requests.single.queryParameters, {
      'versionCode': '6004',
      'abi': 'x86_64',
    });
    expect(updater.release?.versionCode, 6005);
    expect(updater.mandatory, isFalse);
    await updater.check('https://second.test');
    expect(client.requests, hasLength(2));
  });
  test('older manifest and no publication never force an update; offline check fails open', () async {
    final native = FakeUpdatePlatform();
    final client = FakeManifestClient()..value = manifest(code: 6003);
    final updater = UpdateController(platform: native, client: client);
    addTearDown(updater.dispose);
    await updater.check('https://first.test');
    expect(updater.status, UpdateStatus.current);
    expect(updater.release, isNull);
    client.value = {
      'schemaVersion': 1,
      'updateServiceEnabled': false,
      'available': false,
    };
    await updater.check('https://first.test', force: true);
    expect(updater.status, UpdateStatus.unavailable);
    expect(updater.mandatory, isFalse);
    client.fail = true;
    await updater.check('https://first.test', force: true);
    expect(updater.status, UpdateStatus.error);
    expect(updater.mandatory, isFalse);
    expect(native.downloads, isEmpty);
  });
  test('unsupported platform makes no network call and mandatory metadata is validated', () async {
    final native = FakeUpdatePlatform()..value = null;
    final client = FakeManifestClient();
    final updater = UpdateController(platform: native, client: client);
    addTearDown(updater.dispose);
    await updater.check('https://first.test');
    expect(client.requests, isEmpty);
    expect(updater.status, UpdateStatus.unsupported);
    native.value = buildInfo();
    client.value = manifest(mandatory: true);
    await updater.check('https://first.test', force: true);
    expect(updater.mandatory, isTrue);
    client.fail = true;
    await updater.check('https://first.test', force: true);
    expect(updater.mandatory, isTrue);
  });
  test(
    'invalid relative path, digest or byte size cannot reach native download',
    () async {
      final native = FakeUpdatePlatform();
      final client = FakeManifestClient();
      final updater = UpdateController(platform: native, client: client);
      addTearDown(updater.dispose);
      for (final invalid in [
        {'downloadPath': 'https://other.test/app.apk'},
        {'downloadPath': '/../app.apk'},
        {'downloadPath': '/api/v1/mobile/releases/6005/other.apk'},
        {'sha256': 'bad'},
        {'apkSizeBytes': -1},
        {'apkSizeBytes': 81 * 1024 * 1024},
        {'minimumSupportedVersionCode': 0},
      ]) {
        client.value = {...manifest(), ...invalid};
        await updater.check('https://first.test', force: true);
        await updater.download();
        expect(updater.status, UpdateStatus.error);
        expect(native.downloads, isEmpty);
      }
    },
  );
  test('single native download reports progress and can be cancelled without a duplicate', () async {
    final native = FakeUpdatePlatform()
      ..pending = Completer<DownloadedUpdate>();
    final client = FakeManifestClient();
    final updater = UpdateController(platform: native, client: client);
    addTearDown(updater.dispose);
    await updater.check('https://first.test');
    final first = updater.download();
    final second = updater.download();
    await tick();
    expect(native.downloads, hasLength(1));
    native.events.add(const UpdateProgress(40, 100));
    await tick();
    expect(updater.progress, .4);
    await updater.cancelDownload();
    await Future.wait([first, second]);
    expect(updater.candidate, isNull);
    expect(updater.release?.versionCode, 6005);
  });
  test(
    'permission is explicit and opening installer is not installation success',
    () async {
      final native = FakeUpdatePlatform();
      final client = FakeManifestClient();
      final updater = UpdateController(platform: native, client: client);
      addTearDown(updater.dispose);
      await updater.check('https://first.test');
      await updater.download();
      expect(updater.status, UpdateStatus.permissionRequired);
      expect(native.downloads.single.keys.toSet(), {
        'baseUrl',
        'downloadPath',
        'sha256',
        'sizeBytes',
        'versionCode',
      });
      await updater.install();
      expect(native.installCalls, 0);
      await updater.requestPermission();
      expect(native.permissionCalls, 1);
      native.value = buildInfo(allowed: true);
      await updater.resume();
      await updater.install();
      expect(native.installCalls, 1);
      expect(updater.status, UpdateStatus.installerOpened);
      expect(native.deleted, isEmpty);
      native.value = buildInfo(code: 6005, allowed: true);
      await updater.resume();
      expect(updater.status, UpdateStatus.current);
      expect(native.deleted, ['/private/update.apk']);
      expect(updater.release, isNull);
    },
  );
  test('server change cancels in-flight native work and deletes late old-server artifact', () async {
    final native = FakeUpdatePlatform()
      ..pending = Completer<DownloadedUpdate>()
      ..completeOnCancel = false;
    final client = FakeManifestClient();
    final updater = UpdateController(platform: native, client: client);
    addTearDown(updater.dispose);
    await updater.check('https://first.test');
    final task = updater.download();
    await tick();
    updater.setServer('https://second.test');
    await updater.check('https://second.test');
    native.pending!.complete(
      const DownloadedUpdate(
        path: '/private/old.apk',
        versionName: '2.2.1',
        versionCode: 6005,
        sizeBytes: 100,
      ),
    );
    await task;
    expect(native.cancelCalls, greaterThan(0));
    expect(native.deleted, contains('/private/old.apk'));
    expect(updater.baseUrl, 'https://second.test');
    expect(updater.release?.versionCode, 6006);
    expect(updater.candidate, isNull);
  });
  test(
    'repeated install presses share one pending Android installer request',
    () async {
      final native = FakeUpdatePlatform()
        ..value = buildInfo(allowed: true)
        ..pendingInstall = Completer<bool>();
      final updater = UpdateController(
        platform: native,
        client: FakeManifestClient(),
      );
      addTearDown(updater.dispose);
      await updater.check('https://first.test');
      await updater.download();
      final first = updater.install(), second = updater.install();
      await tick();
      expect(native.installCalls, 1);
      expect(updater.busy, isTrue);
      native.pendingInstall!.complete(true);
      await Future.wait([first, second]);
      expect(updater.status, UpdateStatus.installerOpened);
    },
  );
  test('new process restores verified native cache after permission change without redownloading', () async {
    final native = FakeUpdatePlatform()
      ..value = buildInfo(allowed: true)
      ..cachedValue = const DownloadedUpdate(
        path: '/private/retained.apk',
        versionName: '2.2.1',
        versionCode: 6005,
        sizeBytes: 100,
      );
    final client = FakeManifestClient();
    final updater = UpdateController(platform: native, client: client);
    addTearDown(updater.dispose);
    await updater.check('https://first.test');
    expect(client.requests, hasLength(1));
    expect(native.cacheRequests.single, {
      'sha256': 'a' * 64,
      'sizeBytes': 100,
      'versionCode': 6005,
    });
    expect(updater.candidate?.path, '/private/retained.apk');
    expect(updater.status, UpdateStatus.ready);
    expect(
      updater.notice,
      'Đã khôi phục gói cập nhật đã xác minh trên thiết bị.',
    );
    expect(native.downloads, isEmpty);
    expect(native.installCalls, 0);
    await updater.install();
    expect(native.installCalls, 1);
    expect(native.downloads, isEmpty);
  });
  test('incorrect or late old-server cache is deleted and never becomes a candidate', () async {
    final native = FakeUpdatePlatform()
      ..cachedValue = const DownloadedUpdate(
        path: '/private/wrong.apk',
        versionName: 'wrong',
        versionCode: 6003,
        sizeBytes: 99,
      );
    final updater = UpdateController(
      platform: native,
      client: FakeManifestClient(),
    );
    addTearDown(updater.dispose);
    await updater.check('https://first.test');
    expect(native.deleted, contains('/private/wrong.apk'));
    expect(updater.candidate, isNull);
    expect(updater.status, UpdateStatus.available);
    native.cachedValue = null;
    native.pendingCache = Completer<DownloadedUpdate?>();
    final firstCheck = updater.check('https://first.test', force: true);
    await tick();
    final oldCache = native.pendingCache!;
    native.pendingCache = null;
    updater.setServer('https://second.test');
    await updater.check('https://second.test');
    oldCache.complete(
      const DownloadedUpdate(
        path: '/private/late.apk',
        versionName: '2.2.1',
        versionCode: 6005,
        sizeBytes: 100,
      ),
    );
    await firstCheck;
    expect(native.deleted, contains('/private/late.apk'));
    expect(updater.candidate, isNull);
    expect(updater.release?.versionCode, 6006);
    expect(native.downloads, isEmpty);
  });
}
