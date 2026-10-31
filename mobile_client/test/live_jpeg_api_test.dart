import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';

import 'session_test.dart' show FakeApiTransport;

const framePath =
    '/ai/live/sessions/11111111-1111-4111-8111-111111111111/frames';
Uint8List frame() => Uint8List.fromList([255, 216, 255, 217]);

class MemoryJpegFake implements JpegTransport {
  final calls = <(Uri, Map<String, String>, Uint8List)>[];
  FutureOr<ApiReply> Function(int)? handle;
  @override
  Future<ApiReply> sendJpeg(
    Uri uri,
    Map<String, String> headers,
    Uint8List bytes,
    UploadCancellation cancellation,
  ) async {
    calls.add((uri, Map.from(headers), Uint8List.fromList(bytes)));
    return handle == null
        ? const ApiReply(200, '{"accepted":true}')
        : await handle!(calls.length);
  }

  @override
  void close() {}
}

ApiClient client(MemoryJpegFake jpeg) =>
    ApiClient(
      baseUrl: 'https://example.test',
      jpegTransport: jpeg,
      transport: FakeApiTransport(
        (_) => ApiReply(
          200,
          jsonEncode({
            'accessToken': 'rotated',
            'refreshToken': 'refresh-new',
            'expiresIn': 900,
          }),
        ),
      ),
    )..setTokens(
      TokenPair(
        'access',
        'refresh',
        DateTime.now().add(const Duration(minutes: 10)),
      ),
    );
void main() {
  test('memory JPEG keeps origin, forced authentication and exact bytes/sequence through one 401 refresh', () async {
    final jpeg = MemoryJpegFake(), bytes = frame();
    final actual = client(jpeg);
    addTearDown(actual.close);
    jpeg.handle = (call) {
      if (call == 1) {
        bytes[3] = 0;
        return const ApiReply(401, '');
      }
      return const ApiReply(200, '{"accepted":true}');
    };
    expect(
      (await actual.sendJpeg(
        framePath,
        bytes,
        headers: {'X-Frame-Sequence': '7'},
        cancellation: UploadCancellation(),
      ))['accepted'],
      isTrue,
    );
    expect(jpeg.calls, hasLength(2));
    expect(
      jpeg.calls[0].$1.toString(),
      'https://example.test/api/v1$framePath',
    );
    expect(jpeg.calls[0].$2['Authorization'], 'Bearer access');
    expect(jpeg.calls[1].$2['Authorization'], 'Bearer rotated');
    expect(jpeg.calls[1].$2['Content-Type'], 'image/jpeg');
    expect(
      jpeg.calls.every((call) => call.$2['X-Frame-Sequence'] == '7'),
      isTrue,
    );
    expect(jpeg.calls[0].$3, orderedEquals(jpeg.calls[1].$3));
  });
  test('memory JPEG rejects oversized bytes, non JPEG, bad sequence and reserved headers before transport', () async {
    final jpeg = MemoryJpegFake();
    final actual = client(jpeg);
    addTearDown(actual.close);
    for (final bytes in [
      Uint8List(1024 * 1024 + 1),
      Uint8List.fromList([1, 2, 3, 4]),
    ]) {
      await expectLater(
        actual.sendJpeg(
          framePath,
          bytes,
          headers: {'X-Frame-Sequence': '1'},
          cancellation: UploadCancellation(),
        ),
        throwsA(isA<ApiException>()),
      );
    }
    for (final headers in [
      <String, String>{},
      {'X-Frame-Sequence': '0'},
      {'X-Frame-Sequence': '1', 'authorization': 'Bearer attacker'},
      {'X-Frame-Sequence': '1', 'Content-Type': 'text/plain'},
    ]) {
      await expectLater(
        actual.sendJpeg(
          framePath,
          frame(),
          headers: headers,
          cancellation: UploadCancellation(),
        ),
        throwsA(isA<ApiException>()),
      );
    }
    await expectLater(
      actual.sendJpeg(
        'https://other.test/frames',
        frame(),
        headers: {'X-Frame-Sequence': '1'},
        cancellation: UploadCancellation(),
      ),
      throwsA(isA<ApiException>()),
    );
    expect(jpeg.calls, isEmpty);
  });
  test('memory JPEG is cancelled on server change and never returns a late successful frame', () async {
    final jpeg = MemoryJpegFake();
    final actual = client(jpeg);
    addTearDown(actual.close);
    final response = Completer<ApiReply>(), cancel = UploadCancellation();
    jpeg.handle = (_) => response.future;
    final sending = actual.sendJpeg(
      framePath,
      frame(),
      headers: {'X-Frame-Sequence': '1'},
      cancellation: cancel,
    );
    final failed = expectLater(sending, throwsA(isA<ApiException>()));
    await Future<void>.delayed(Duration.zero);
    actual.changeBaseUrl('https://other.test');
    expect(cancel.cancelled, isTrue);
    response.complete(const ApiReply(200, '{"accepted":true}'));
    await failed;
    expect(jpeg.calls, hasLength(1));
  });
}
