import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fruitvision_client/client/api.dart';

class FakeTransport implements ApiTransport {
  int refreshes = 0;
  int calls = 0;
  @override Future<ApiReply> send(String method, Uri uri, Map<String,String> headers, String? body) async {
    calls++;
    expect(uri.path.startsWith('/api/v1/'), isTrue);
    if (uri.path.endsWith('/auth/refresh')) {
      refreshes++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return ApiReply(200, jsonEncode({'accessToken':'new-access', 'refreshToken':'new-refresh', 'expiresIn':900}));
    }
    if (uri.path.endsWith('/auth/logout')) return const ApiReply(204, '');
    if (headers['Authorization'] != 'Bearer new-access') return const ApiReply(401, '');
    return const ApiReply(200, '{"id":"my-account"}');
  }
  @override void close() {}
}
void main() {
  test('parallel protected requests share one refresh and retry with rotated tokens', () async {
    final transport = FakeTransport();
    final api = ApiClient(transport: transport);
    api.setTokens(TokenPair('old-access','old-refresh',DateTime.now()));
    final results = await Future.wait([api.get('/auth/me'),api.get('/history')]);
    expect(results.every((r) => r['id'] == 'my-account'), isTrue);
    expect(transport.refreshes, 1);
    expect(api.tokens?.refreshToken, 'new-refresh');
  });
  test('logout accepts an empty 204 response', () async {
    final api = ApiClient(transport: FakeTransport());
    expect(await api.post('/auth/logout', null), isEmpty);
  });
}
