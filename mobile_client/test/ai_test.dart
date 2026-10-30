import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';
import 'package:fruitvision_client/client/media.dart';
import 'package:fruitvision_client/client/realtime.dart';
import 'package:fruitvision_client/client/session.dart';
import 'package:fruitvision_client/client/ui/ai.dart';
import 'package:fruitvision_client/client/ui/realtime_scope.dart';
import 'package:fruitvision_client/client/ui/visuals.dart';
import 'package:fruitvision_client/client/vault.dart';

class AiMemoryVault implements SessionVault {
  @override
  Future<Map<String, dynamic>?> read() async => null;
  @override
  Future<void> write(Map<String, dynamic> value) async {}
  @override
  Future<void> clear() async {}
}

class EventHub extends RealtimeClient {
  EventHub(ApiClient api) : super(api: api);
  final updates = StreamController<HubEvent>.broadcast();
  @override
  Stream<HubEvent> get events => updates.stream;
  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }
}

class DelayedAiTransport implements ApiTransport {
  DelayedAiTransport({required this.detail});
  final bool detail;
  final first = Completer<ApiReply>();
  int calls = 0;
  Map<String, dynamic> job(String status, int revision) => {
    'id': 'job-one',
    'mediaType': 'image',
    'status': status,
    'revision': revision,
    'progress': status == 'Succeeded' ? 100 : 0,
    'createdAt': '2026-10-30T10:00:00Z',
    'previewAvailable': false,
  };
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    if (uri.path.endsWith('/ai/capabilities')) {
      return const ApiReply(200, '{"aiReady":true}');
    }
    if (uri.path.endsWith(detail ? '/ai/jobs/job-one' : '/ai/jobs')) {
      calls++;
      if (calls == 1) return first.future;
      final current = job(detail ? 'Succeeded' : 'Queued', 2);
      return ApiReply(
        200,
        jsonEncode(
          detail
              ? current
              : {
                  'items': [current],
                },
        ),
      );
    }
    return const ApiReply(200, '{}');
  }

  @override
  void close() {}
}

SessionController aiController(ApiClient api) =>
    SessionController(api: api, vault: AiMemoryVault())
      ..loading = false
      ..user = const Account(
        id: 'approved',
        displayName: 'Minh',
        email: 'm@example.test',
        role: UserRole.consumer,
        approvalStatus: ApprovalStatus.approved,
        region: 'Đồng Tháp',
        isActive: true,
      );

class AiTestTransport implements ApiTransport {
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async => const ApiReply(200, '{}');
  @override
  void close() {}
}

class ResultTransport implements ApiTransport {
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async => ApiReply(
    200,
    jsonEncode(
      uri.path.endsWith('/ai/capabilities')
          ? {'aiReady': true}
          : uri.path.endsWith('/ai/jobs/job-one')
          ? {
              'id': 'job-one',
              'mediaType': 'image',
              'status': 'Succeeded',
              'revision': 2,
              'previewAvailable': true,
              'result': {
                'maxVisibleCount': 3,
                'gradeCounts': {
                  'Xanh / chưa chín': 3,
                  'Chín': 0,
                  'Chưa xác định': 0,
                },
                'modelName': 'Server test model',
                'modelSha256': 'a' * 64,
                'limitations': ['Cần kiểm tra lại.'],
              },
            }
          : {'items': <Object>[]},
    ),
  );
  @override
  void close() {}
}

class PreviewTransport extends TestMediaTransport {
  @override
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  ) async => BinaryReply(
    200,
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    ),
  );
}

class SelectionPicker extends NativeMediaPicker {
  @override
  Future<PickedMedia?> pick(String method) async => const PickedMedia(
    path: '/private/chosen.jpg',
    name: 'Ảnh xoài được chọn để phân tích.jpg',
    bytes: 1024,
    mediaType: 'image',
    contentType: 'image/jpeg',
  );
  @override
  Future<void> delete(PickedMedia media) async {}
}

class TestMediaTransport implements MediaTransport {
  final requests = <Map<String, String>>[];
  bool fail = true;
  @override
  Future<ApiReply> upload(
    Uri uri,
    Map<String, String> headers,
    File file,
    UploadCancellation cancellation,
    void Function(int, int)? onProgress,
  ) async {
    requests.add(headers);
    final total = await file.length();
    onProgress?.call(total, total);
    if (fail) throw const ApiException('Uncertain response');
    return ApiReply(
      202,
      jsonEncode({'id': 'job-one', 'status': 'Queued', 'revision': 1}),
    );
  }

  @override
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  ) async {
    requests.add(headers);
    expect(maxBytes, 12 * 1024 * 1024);
    return BinaryReply(200, Uint8List.fromList([255, 216, 255, 217]));
  }

  @override
  void close() {}
}

void main() {
  for (final detail in [false, true]) {
    testWidgets(
      '${detail ? 'job detail' : 'job list'} coalesces events during stale GET into one trailing refresh',
      (tester) async {
        final transport = DelayedAiTransport(detail: detail);
        final c = aiController(
          ApiClient(baseUrl: 'https://example.test', transport: transport),
        );
        final hub = EventHub(c.api);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          hub.dispose();
          c.dispose();
        });
        await tester.pumpWidget(
          RealtimeScope(
            client: hub,
            child: MaterialApp(
              home: detail
                  ? AiJobPage(
                      controller: c,
                      id: 'job-one',
                      initial: transport.job('Queued', 1),
                    )
                  : Scaffold(
                      body: AiPage(
                        controller: c,
                        header: const SizedBox.shrink(),
                      ),
                    ),
            ),
          ),
        );
        await tester.pump();
        expect(transport.calls, 1);
        hub.updates.add(
          const HubEvent('AiJobChanged', {
            'id': 'job-one',
            'revision': 2,
            'status': 'Succeeded',
          }),
        );
        hub.updates.add(
          const HubEvent('AiJobChanged', {
            'id': 'job-one',
            'revision': 3,
            'status': 'Succeeded',
          }),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(transport.calls, 1);
        transport.first.complete(
          ApiReply(
            200,
            jsonEncode(
              detail ? transport.job('Queued', 1) : {'items': <Object>[]},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          transport.calls,
          2,
          reason: 'One trailing GET must recover the event after the older snapshot.',
        );
        final label = find.text(detail ? 'Hoàn tất' : 'Ảnh · Đang chờ xử lý');
        await tester.scrollUntilVisible(label, 150);
        expect(label, findsOneWidget);
        if (!detail) {
          hub.updates.add(
            const HubEvent('AiJobChanged', {
              'id': 'job-one',
              'revision': 3,
              'status': 'Running',
              'progress': 25,
              'framesProcessed': 10,
            }),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('Ảnh · Đang phân tích'), findsOneWidget);
          expect(find.text('25%'), findsOneWidget);
        }
        await tester.pump(const Duration(milliseconds: 800));
        expect(
          transport.calls,
          2,
          reason: 'A burst of events must not start an unbounded refresh loop.',
        );
      },
    );
  }

  test('explicit upload retry preserves request ID; oversize upload is rejected locally', () async {
    final folder = await Directory.systemTemp.createTemp(
      'fruitvision-media-test',
    );
    addTearDown(() => folder.delete(recursive: true));
    final file = await File('${folder.path}/image.jpg')
        .writeAsBytes([255, 216, 255, 217]);
    final media = TestMediaTransport();
    final api =
        ApiClient(
          baseUrl: 'https://example.test',
          transport: AiTestTransport(),
          mediaTransport: media,
        )..setTokens(
          TokenPair(
            'access',
            'refresh',
            DateTime.now().toUtc().add(const Duration(minutes: 15)),
          ),
        );
    addTearDown(api.close);
    Future<Map<String, dynamic>> upload() => api.uploadAiFile(
      file,
      mediaType: 'image',
      contentType: 'image/jpeg',
      requestId: 'request_same_123',
    );
    await expectLater(upload(), throwsA(isA<ApiException>()));
    expect(media.requests, hasLength(1));
    media.fail = false;
    expect((await upload())['id'], 'job-one');
    expect(media.requests.map((headers) => headers['X-Client-Request-Id']), [
      'request_same_123',
      'request_same_123',
    ]);
    expect(
      media.requests.every(
        (headers) => headers['Authorization'] == 'Bearer access',
      ),
      isTrue,
    );
    final oversized = await file.open(mode: FileMode.write);
    await oversized.truncate(12 * 1024 * 1024 + 1);
    await oversized.close();
    await expectLater(upload(), throwsA(isA<ApiException>()));
    expect(media.requests, hasLength(2));
    expect(await api.aiPreview('job-one'), [255, 216, 255, 217]);
    expect(media.requests.last['Authorization'], 'Bearer access');
  });

  test(
    'job revisions reject older snapshots and accept completion after upload',
    () {
      final running = {'id': 'one', 'revision': 4, 'status': 'Running'};
      expect(
        newerJob({'id': 'one', 'revision': 3, 'status': 'Queued'}, running),
        isFalse,
      );
      expect(
        newerJob({'id': 'one', 'revision': 5, 'status': 'Succeeded'}, running),
        isTrue,
      );
    },
  );

  testWidgets(
    'video results keep visible counts, tracks and crossings distinct',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiResultCard(
                mediaType: 'video',
                result: {
                  'schema': 'fruitvision-ai-v1',
                  'modelName': 'Test server model',
                  'modelSha256': 'abc123',
                  'maxVisibleCount': 7,
                  'confirmedTrackCount': 11,
                  'lineCrossingCount': 4,
                  'framesProcessed': 50,
                  'gradeCounts': {'Chín': 3, 'Xanh': 4},
                  'objects': <Object>[],
                  'limitations': ['Vật bị che có thể bị bỏ sót.'],
                },
              ),
            ),
          ),
        ),
      );
      expect(
        find.bySemanticsLabel('Số quả thấy đồng thời nhiều nhất: 7'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Track đã xác nhận: 11'), findsOneWidget);
      expect(find.bySemanticsLabel('Lượt cắt đường đếm: 4'), findsOneWidget);
      final explanation = find.text('Cách hiểu kết quả');
      await tester.ensureVisible(explanation);
      await tester.tap(explanation);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('không cộng lại thành tổng số quả'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'annotated preview precedes accessible count and collapsed technical details',
    (tester) async {
      final c = aiController(
        ApiClient(
          baseUrl: 'https://example.test',
          transport: ResultTransport(),
          mediaTransport: PreviewTransport(),
        ),
      );
      c.api.setTokens(
        TokenPair(
          'test-access',
          'test-refresh',
          DateTime.now().toUtc().add(const Duration(minutes: 15)),
        ),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AiJobPage(controller: c, id: 'job-one'),
        ),
      );
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('ai-annotated-preview'));
      expect(preview, findsOneWidget);
      final children =
          (tester.widget<ListView>(find.byType(ListView)).childrenDelegate
                  as SliverChildListDelegate)
              .children;
      expect(
        children.indexWhere((child) => child is AnnotatedPreview),
        lessThan(children.indexWhere((child) => child is AiResultCard)),
      );
      expect(
        tester.widget<CountMetric>(find.byType(CountMetric).first).value,
        '3',
      );
      expect(find.text('Mô hình: Server test model'), findsNothing);
      final technical = find.byKey(const ValueKey('ai-technical-info'));
      await tester.scrollUntilVisible(technical, 180);
      expect(tester.getSize(technical).height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(find.text('Thông tin kỹ thuật'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thông tin kỹ thuật'));
      await tester.pumpAndSettle();
      expect(find.text('Mô hình: Server test model'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected-file primary action stays above navigation on narrow large text screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final c = aiController(
        ApiClient(
          baseUrl: 'https://example.test',
          transport: ResultTransport(),
        ),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ),
          home: Scaffold(
            body: AiPage(
              controller: c,
              header: const SizedBox(height: 96),
              picker: SelectionPicker(),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: 1,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.eco), label: 'Khám phá'),
                NavigationDestination(
                  icon: Icon(Icons.auto_awesome),
                  label: 'AI',
                ),
                NavigationDestination(
                  icon: Icon(Icons.forum),
                  label: 'Trao đổi',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person),
                  label: 'Tài khoản',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Chọn ảnh'), 150);
      await tester.tap(find.text('Chọn ảnh'));
      await tester.pumpAndSettle();
      final action = find.widgetWithText(FilledButton, 'Gửi phân tích');
      expect(
        tester.getRect(action).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(NavigationBar)).top),
      );
      expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
      expect(
        tester.getRect(find.widgetWithText(TextButton, 'Bỏ')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
