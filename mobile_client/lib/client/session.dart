import 'package:flutter/foundation.dart';

import 'api.dart';
import 'vault.dart';

class SessionController extends ChangeNotifier {
  SessionController({ApiClient? api, SessionVault? vault})
    : api = api ?? ApiClient(),
      _vault = vault ?? AndroidSessionVault() {
    this.api.onTokensChanged = (pair) async {
      await _persist(pair);
      if (pair == null) {
        user = null;
        error = 'Phiên đã hết hạn. Vui lòng đăng nhập lại.';
        notifyListeners();
      }
    };
  }
  final ApiClient api;
  final SessionVault _vault;
  Future<void> _vaultTail = Future<void>.value();
  Account? user;
  bool loading = true, busy = false;
  bool endingSession = false;
  String? error, notice, mfaChallenge;
  bool get signedIn => user != null;
  Future<void> _persist(TokenPair? pair) {
    final snapshot = <String, dynamic>{
      'baseUrl': api.baseUrl,
      if (pair != null) 'tokens': pair.toJson(),
    };
    // A logout/server-switch queued during rotation must be the final write.
    final write = _vaultTail.then((_) => _vault.write(snapshot));
    _vaultTail = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  Future<bool> initialize() async {
    try {
      final stored = await _vault.read();
      if (stored != null) {
        api.changeBaseUrl(stored['baseUrl'] as String);
        final pair = stored['tokens'];
        if (pair is Map<String, dynamic>) {
          api.setTokens(TokenPair.fromJson(pair));
          user = Account.fromJson(await api.get('/auth/me'));
        }
      }
      return true;
    } catch (e) {
      user = null;
      if (e is! ApiException || e.status == 401) {
        api.setTokens(null);
        try {
          await _persist(null);
        } catch (_) {
          /* Vault may be unavailable. */
        }
      }
      error = e is ApiException
          ? e.message
          : 'Không đọc được phiên an toàn. Vui lòng đăng nhập lại.';
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (busy) return false;
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      await action();
      return true;
    } catch (e) {
      error = e is ApiException
          ? e.message
          : 'Không hoàn tất được thao tác. Vui lòng thử lại.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _accept(Map<String, dynamic> response) async {
    if (response['requiresTwoFactor'] == true) {
      mfaChallenge = response['challengeToken'] as String;
      return;
    }
    final pair = TokenPair.fromResponse(response);
    final account = Account.fromJson(response['user'] as Map<String, dynamic>);
    await _persist(pair);
    api.setTokens(pair);
    mfaChallenge = null;
    user = account;
  }

  Future<bool> login(String email, String password) => _run(() async {
    await _accept(
      await api.post('/auth/login', {
        'email': email.trim(),
        'password': password,
      }),
    );
  });
  Future<bool> completeMfa(String code) => _run(() async {
    final challenge = mfaChallenge;
    if (challenge == null) {
      throw const ApiException('Hãy đăng nhập lại để lấy phiên xác thực.');
    }
    await _accept(
      await api.post('/auth/mfa/login', {
        'challengeToken': challenge,
        'code': code.trim(),
      }),
    );
  });
  Future<bool> register({
    required String displayName,
    required String email,
    required String password,
    required String region,
    required UserRole role,
  }) => _run(() async {
    if (role == UserRole.admin) {
      throw const ApiException('Không thể tự đăng ký tài khoản quản trị.');
    }
    await api.post('/auth/register', {
      'displayName': displayName.trim(),
      'email': email.trim(),
      'password': password,
      'region': region.trim(),
      'role': role.wire,
    });
    notice = 'Đăng ký thành công. Hãy đăng nhập để theo dõi xét duyệt.';
  });
  Future<bool> refreshProfile() => _run(() async {
    user = Account.fromJson(await api.get('/auth/me'));
  });
  Future<bool> resubmit({
    required String displayName,
    required String region,
  }) => _run(() async {
    await api.post('/applications/resubmit', {
      'displayName': displayName.trim(),
      'region': region.trim(),
    });
    user = Account.fromJson(await api.get('/auth/me'));
    notice = 'Đã gửi lại hồ sơ để xét duyệt.';
  });
  Future<bool> logout() {
    if (busy) return Future.value(false);
    endingSession = true;
    api.cancelUploads();
    notifyListeners();
    return _run(() async {
      try {
        await api.post('/auth/logout', null);
      } catch (_) {
        notice = 'Đã xóa phiên trên thiết bị; máy chủ chưa xác nhận đăng xuất.';
      }
      api.setTokens(null);
      user = null;
      mfaChallenge = null;
      await _persist(null);
    }).whenComplete(() {
      endingSession = false;
    });
  }

  Future<bool> changeServer(String url) => _run(() async {
    final validated = ApiClient.validateBaseUrl(url);
    if (validated == api.baseUrl) return;
    api.changeBaseUrl(validated);
    user = null;
    mfaChallenge = null;
    await _persist(null);
    notice = 'Đã đổi máy chủ. Hãy đăng nhập tại địa chỉ mới.';
  });
  void cancelMfa() {
    mfaChallenge = null;
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}
