import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'vault.dart';
import 'biometrics.dart';
import 'media.dart';

class SessionController extends ChangeNotifier {
  SessionController({
    ApiClient? api,
    SessionVault? vault,
    BiometricPlatform? biometrics,
  }) : api = api ?? ApiClient(),
       biometrics = biometrics ?? BiometricPlatform(),
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
  final BiometricPlatform biometrics;
  Future<bool> loginFace(String email, PickedMedia photo) => _run(() async {
    _lastStrongSignInAt = null;
    _passwordBackedChallenge = false;
    final normalized = email.trim().toLowerCase();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalized)) {
      throw const ApiException('Nhập email tài khoản trước khi đối chiếu ảnh.');
    }
    final encoded = await _faceImage(photo);
    final response = await api.post('/auth/face/login', {
      'email': normalized,
      'imageBase64': encoded,
    });
    if (response['requiresTwoFactor'] != true ||
        response['method'] != 'email') {
      throw const ApiException(
        'Đối chiếu ảnh chỉ được tiếp tục bằng mã email. Hãy đăng nhập bằng mật khẩu và mã xác thực.',
      );
    }
    await _accept(response);
  });
  Future<bool> enrollFace(PickedMedia photo) => _run(() async {
    if (!canEnrollBiometric) {
      throw const ApiException(
        'Đăng nhập lại bằng mật khẩu và mã email hoặc ứng dụng xác thực trong 15 phút trước khi đăng ký ảnh.',
      );
    }
    await api.post('/auth/face/enroll', {
      'imageBase64': await _faceImage(photo),
    });
    notice = 'Đã đăng ký mẫu đối chiếu ảnh khuôn mặt. Đăng nhập vẫn cần mã email; chưa có kiểm tra người thật.';
  });
  Future<String> _faceImage(PickedMedia photo) async {
    try {
      return await faceImageBase64(photo);
    } on FormatException catch (e) {
      throw ApiException(e.message);
    }
  }

  DateTime? _lastStrongSignInAt;
  bool _passwordBackedChallenge = false;
  bool get canEnrollBiometric =>
      user?.isActive == true &&
      user?.emailConfirmed == true &&
      _lastStrongSignInAt != null &&
      DateTime.now().difference(_lastStrongSignInAt!) <
          const Duration(minutes: 15);
  Future<bool> loginBiometric(String email) => _run(() async {
    _lastStrongSignInAt = null;
    _passwordBackedChallenge = false;
    final normalized = email.trim().toLowerCase(), origin = api.baseUrl;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalized)) {
      throw const ApiException('Nhập email đã đăng ký khóa sinh trắc học.');
    }
    final info = await biometrics.info(origin, normalized);
    if (!info.available) {
      throw const ApiException(
        'Thiết bị chưa hỗ trợ hoặc chưa thiết lập sinh trắc học mạnh. Hãy dùng mật khẩu và mã xác thực.',
      );
    }
    if (!info.enrolled || info.deviceId == null) {
      throw const ApiException(
        'Email này chưa có khóa trên thiết bị. Hãy đăng nhập bằng mật khẩu và mã xác thực để đăng ký.',
      );
    }
    final challenge = await api.post('/auth/biometric/challenge', {
      'email': normalized,
      'deviceId': info.deviceId,
    });
    final payload = challenge['payload'], token = challenge['challengeToken'];
    if (payload is! String ||
        payload.isEmpty ||
        payload.length > 8192 ||
        token is! String ||
        token.isEmpty) {
      throw const ApiException(
        'Thử thách đăng nhập không hợp lệ. Hãy bắt đầu lại.',
      );
    }
    String signature;
    try {
      signature = await biometrics.sign(origin, normalized, payload);
    } on PlatformException catch (e) {
      throw ApiException(
        e.code.toUpperCase().contains('CANCEL')
            ? 'Đã hủy xác thực sinh trắc học.'
            : 'Không xác thực được bằng sinh trắc học. Hãy dùng mật khẩu và mã xác thực.',
      );
    }
    await _accept(
      await api.post('/auth/biometric/login', {
        'challengeToken': token,
        'signature': signature,
      }),
    );
  });
  Future<bool> enrollBiometric() => _run(() async {
    if (!canEnrollBiometric) {
      throw const ApiException(
        'Đăng nhập lại bằng mật khẩu và mã email hoặc ứng dụng xác thực trong 15 phút để đăng ký khóa.',
      );
    }
    final origin = api.baseUrl, email = user!.email.trim().toLowerCase();
    final info = await biometrics.createKey(origin, email);
    if (!info.available || info.deviceId == null || info.publicKey == null) {
      throw const ApiException(
        'Thiết bị cần hỗ trợ và đã thiết lập sinh trắc học mạnh.',
      );
    }
    try {
      await api.post('/auth/biometric/devices', {
        'deviceId': info.deviceId,
        'label': info.label,
        'publicKey': info.publicKey,
      });
    } catch (_) {
      await biometrics.deleteKey(origin, email);
      rethrow;
    }
    notice = 'Đã đăng ký khóa công khai cho thiết bị. Khóa riêng nằm trong Android Keystore.';
  });
  final SessionVault _vault;
  Future<void> _vaultTail = Future<void>.value();
  Account? user;
  bool loading = true, busy = false;
  bool endingSession = false;
  String? error, notice, mfaChallenge;
  String mfaMethod = 'authenticator';
  String? mfaEmailHint, mfaMailSubject;
  DateTime? mfaResendAt, mfaExpiresAt;
  int get mfaResendSeconds => mfaResendAt == null
      ? 0
      : ((mfaResendAt!.difference(DateTime.now()).inMilliseconds / 1000).ceil())
            .clamp(0, 600);
  void _clearChallenge() {
    _passwordBackedChallenge = false;
    mfaChallenge = null;
    mfaMethod = 'authenticator';
    mfaEmailHint = null;
    mfaMailSubject = null;
    mfaResendAt = null;
    mfaExpiresAt = null;
  }

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
        final origin = ApiClient.validateBaseUrl(stored['baseUrl'] as String);
        if (origin ==
                'https://tips-differential-relating-validity.trycloudflare.com' &&
            origin != defaultApiUrl) {
          // A signed release may replace this exact retired origin. Never carry
          // its credentials to the replacement, or migrate a custom server.
          api.changeBaseUrl(defaultApiUrl);
          user = null;
          _lastStrongSignInAt = null;
          _clearChallenge();
          await _persist(null);
          notice = 'Địa chỉ kết nối đã được cập nhật. Vui lòng đăng nhập lại.';
          return true;
        }
        api.changeBaseUrl(origin);
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
      final method = response['method'] ?? 'authenticator';
      if (method != 'email' && method != 'authenticator') {
        throw const ApiException(
          'Phương thức xác thực này chưa được ứng dụng hỗ trợ.',
        );
      }
      mfaChallenge = response['challengeToken'] as String;
      mfaMethod = method as String;
      mfaEmailHint = response['emailHint'] as String?;
      mfaMailSubject = response['mailSubject'] as String?;
      mfaResendAt = response['resendAfter'] is num
          ? DateTime.now().add(
              Duration(
                seconds: (response['resendAfter'] as num).toInt().clamp(0, 600),
              ),
            )
          : null;
      mfaExpiresAt = response['expiresIn'] is num
          ? DateTime.now().add(
              Duration(
                seconds: (response['expiresIn'] as num).toInt().clamp(0, 600),
              ),
            )
          : null;
      return;
    }
    final pair = TokenPair.fromResponse(response);
    final account = Account.fromJson(response['user'] as Map<String, dynamic>);
    await _persist(pair);
    api.setTokens(pair);
    _clearChallenge();
    user = account;
  }

  Future<bool> login(String email, String password) => _run(() async {
    _lastStrongSignInAt = null;
    _passwordBackedChallenge = false;
    final response = await api.post('/auth/login', {
      'email': email.trim(),
      'password': password,
    });
    _passwordBackedChallenge = response['requiresTwoFactor'] == true;
    await _accept(response);
  });
  Future<bool> completeMfa(String code) => _run(() async {
    final challenge = mfaChallenge;
    if (challenge == null) {
      throw const ApiException('Hãy đăng nhập lại để lấy phiên xác thực.');
    }
    final passwordBacked = _passwordBackedChallenge;
    await _accept(
      await api.post(
        mfaMethod == 'email' ? '/auth/otp/verify' : '/auth/mfa/login',
        {'challengeToken': challenge, 'code': code.trim()},
      ),
    );
    if (user != null && passwordBacked) _lastStrongSignInAt = DateTime.now();
  });
  Future<bool> resendEmailOtp() => _run(() async {
    if (mfaChallenge == null || mfaMethod != 'email') {
      throw const ApiException('Hãy bắt đầu lại bước xác thực email.');
    }
    if (mfaResendSeconds > 0) {
      throw ApiException(
        'Hãy đợi $mfaResendSeconds giây trước khi gửi lại mã.',
      );
    }
    await _accept(
      await api.post('/auth/otp/resend', {'challengeToken': mfaChallenge}),
    );
    notice = 'Đã yêu cầu gửi lại mã. Chỉ mã mới nhất còn hiệu lực.';
  });
  Future<bool> register({
    required String displayName,
    required String email,
    required String password,
    required String countryCode,
    required String provinceCode,
  }) => _run(() async {
    _lastStrongSignInAt = null;
    _passwordBackedChallenge = false;
    final response = await api.post('/auth/register', {
      'displayName': displayName.trim(),
      'email': email.trim(),
      'password': password,
      'countryCode': countryCode,
      'provinceCode': provinceCode,
    });
    if (response['requiresTwoFactor'] == true) {
      _passwordBackedChallenge = true;
      await _accept(response);
    }
    notice = 'Đăng ký thành công. Hãy xác minh email để sử dụng tài khoản Người tiêu dùng.';
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
      _lastStrongSignInAt = null;
      user = null;
      _clearChallenge();
      await _persist(null);
    }).whenComplete(() {
      endingSession = false;
    });
  }

  Future<bool> changeServer(String url) => _run(() async {
    final validated = ApiClient.validateBaseUrl(url);
    if (validated == api.baseUrl) return;
    api.changeBaseUrl(validated);
    _lastStrongSignInAt = null;
    user = null;
    _clearChallenge();
    await _persist(null);
    notice = 'Đã đổi máy chủ. Hãy đăng nhập tại địa chỉ mới.';
  });
  void cancelMfa() {
    _clearChallenge();
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}
