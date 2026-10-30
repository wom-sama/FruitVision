import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:fruitvision_client/client/api.dart';

// Run from mobile_client; credentials stay in server/.local and never in output.
Future<void> main() async {
  final private = Directory('../server/.local');
  final demos = jsonDecode(await File('${private.path}/demo-accounts.json').readAsString()) as List;
  final results = <Map<String, dynamic>>[];
  final clients = <ApiClient>[];
  void check(String name, bool pass) {
    results.add({'check': name, 'pass': pass});
    if (!pass) throw StateError('Failed: $name');
  }
  Future<ApiClient> demo(String role) async {
    final row = (demos.cast<Map<String, dynamic>>()).firstWhere((r) => r['Email'] == '$role@fruitvision.test');
    final api = ApiClient(); clients.add(api);
    final login = await api.post('/auth/login', {'email': row['Email'], 'password': row['Password']});
    api.setTokens(TokenPair.fromResponse(login));
    check('$role real login', (login['user'] as Map)['approvalStatus'] == 'Approved');
    return api;
  }
  Future<void> denied(ApiClient api, String path, [Map<String, dynamic>? body]) async {
    try { if (body == null) { await api.get(path); } else { await api.post(path, body); } }
    on ApiException catch (e) { check('$path denied for role', e.status == 403); return; }
    throw StateError('Expected403: $path');
  }
  final forecast = {'title':'Kiểm tra APK API Flutter', 'body':'Tin dự kiến dùng để kiểm tra tích hợp ứng dụng.', 'productCode':'mango', 'estimatedQuantityKg':12.5};
  try {
    final admin = await demo('admin');
    final producer = await demo('producer');
    final trader = await demo('trader');
    final consumer = await demo('consumer');
    for (final client in [producer,trader,consumer]) { await denied(client, '/admin/stats'); }
    for (final client in [producer,trader]) {
      final created = await client.post('/posts', forecast);
      check('seller forecast awaits review', created['status'] == 'AwaitingReview');
    }
    await denied(consumer, '/posts', forecast);
    await denied(admin, '/posts', forecast);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final bytes = List.generate(24, (_) => Random.secure().nextInt(256));
    final password = 'Fv!9aA-${base64UrlEncode(bytes)}';
    final email = 'apk-$suffix@fruitvision.test';
    final fresh = ApiClient(); clients.add(fresh);
    final registered = await fresh.post('/auth/register', {'displayName':'Hồ sơ kiểm tra APK',
      'email':email,'password':password,'role':'Producer','region':'TP. Hồ Chí Minh'});
    check('registration Pending', registered['approvalStatus'] == 'Pending');
    await File('${private.path}/mobile-smoke-account.json').writeAsString(jsonEncode({'email':email,'password':password}));
    final login = await fresh.post('/auth/login', {'email':email,'password':password});
    fresh.setTokens(TokenPair.fromResponse(login));
    await denied(fresh, '/posts', forecast);
    final id = registered['id'];
    await admin.post('/admin/applications/$id/review', {'status':'NeedsInformation','reason':'Bổ sung tên và khu vực kiểm tra'});
    check('existing session sees NeedsInformation', (await fresh.get('/auth/me'))['approvalStatus'] == 'NeedsInformation');
    await fresh.post('/applications/resubmit', {'displayName':'Hồ sơ đã bổ sung APK','region':'TP. Hồ Chí Minh'});
    check('resubmit returns Pending', (await fresh.get('/auth/me'))['approvalStatus'] == 'Pending');
    await admin.post('/admin/applications/$id/review', {'status':'Approved','reason':'Đã kiểm tra hồ sơ demo APK'});
    check('existing session sees Approved', (await fresh.get('/auth/me'))['approvalStatus'] == 'Approved');
    check('approved user can post', (await fresh.post('/posts',forecast))['status'] == 'AwaitingReview');
    final conversations = await producer.get('/conversations');
    check('real conversations available', (conversations['items'] as List).isNotEmpty);
    check('AI unavailable honestly', (await consumer.get('/system/capabilities'))['aiReady'] == false);
    for (final api in clients) { await api.post('/auth/logout', null); }
    final receipt = {'atUtc':DateTime.now().toUtc().toIso8601String(),'origin':defaultApiUrl,
      'actualNetwork':'HTTPS public temporary tunnel','checks':results,'allPassed':true};
    final out = Directory('verification'); await out.create(recursive:true);
    await File('${out.path}/https-api-smoke.json').writeAsString(const JsonEncoder.withIndent('  ').convert(receipt));
    stdout.writeln('PASS ${results.length} actual HTTPS API checks; credentials and tokens not printed.');
  } finally { for (final api in clients) { api.close(); } }
}
