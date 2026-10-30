import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
export 'models.dart';

const defaultApiUrl = String.fromEnvironment(
  'FRUITVISION_API_URL',
  defaultValue: 'https://tips-differential-relating-validity.trycloudflare.com',
);

class ApiReply {
  const ApiReply(this.status, this.body);
  final int status;
  final String body;
}

class UploadCancellation {
  bool cancelled = false;
  void Function()? _abort;
  void cancel() {
    cancelled = true;
    _abort?.call();
  }
}

class BinaryReply {
  const BinaryReply(this.status, this.bytes);
  final int status;
  final Uint8List bytes;
}

abstract interface class MediaTransport {
  Future<ApiReply> upload(
    Uri uri,
    Map<String, String> headers,
    File file,
    UploadCancellation cancellation,
    void Function(int, int)? onProgress,
  );
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  );
  void close();
}

class IoMediaTransport implements MediaTransport {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  @override
  Future<ApiReply> upload(
    Uri uri,
    Map<String, String> headers,
    File file,
    UploadCancellation cancellation,
    void Function(int, int)? onProgress,
  ) async {
    HttpClientRequest? request;
    final timeout = Timer(
      const Duration(seconds: 90),
      () =>
          request?.abort(const ApiException('Tải lên quá thời gian 90 giây.')),
    );
    try {
      return await (() async {
        request = await _client.postUrl(uri);
        request!.followRedirects = false;
        cancellation._abort = () =>
            request?.abort(const ApiException('Đã hủy tải lên.'));
        if (cancellation.cancelled) throw const ApiException('Đã hủy tải lên.');
        headers.forEach(request!.headers.set);
        final total = await file.length();
        request!.contentLength = total;
        var sent = 0;
        await request!.addStream(
          file.openRead().map((chunk) {
            if (cancellation.cancelled) {
              throw const ApiException('Đã hủy tải lên.');
            }
            sent += chunk.length;
            onProgress?.call(sent, total);
            return chunk;
          }),
        );
        final response = await request!.close();
        final bytes = await _read(response, 1024 * 1024);
        return ApiReply(response.statusCode, utf8.decode(bytes));
      })().timeout(const Duration(seconds: 90));
    } on ApiException {
      rethrow;
    } catch (_) {
      request?.abort();
      throw ApiException(
        cancellation.cancelled ? 'Đã hủy tải lên.' : 'Tải lên chưa được xác nhận. Kiểm tra danh sách tác vụ trước khi thử lại.',
      );
    } finally {
      timeout.cancel();
      cancellation._abort = null;
    }
  }

  @override
  Future<BinaryReply> download(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
  ) async {
    HttpClientRequest? request;
    try {
      return await (() async {
        request = await _client.getUrl(uri);
        request!.followRedirects = false;
        headers.forEach(request!.headers.set);
        final response = await request!.close();
        return BinaryReply(
          response.statusCode,
          await _read(response, maxBytes),
        );
      })().timeout(const Duration(seconds: 20));
    } catch (_) {
      request?.abort();
      throw const ApiException('Không tải được ảnh kết quả. Vui lòng thử lại.');
    }
  }

  static Future<Uint8List> _read(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const ApiException('Phản hồi vượt giới hạn dung lượng.');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  void close() => _client.close(force: true);
}

abstract interface class ApiTransport {
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  );
  void close();
}

class IoApiTransport implements ApiTransport {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 6;
  @override
  Future<ApiReply> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    try {
      return await (() async {
        final request = await _client.openUrl(method, uri);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        if (body != null) request.write(body);
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const ApiException('Phản hồi quá lớn. Hãy tải từng trang.');
          }
          bytes.addAll(chunk);
        }
        return ApiReply(response.statusCode, utf8.decode(bytes));
      })().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const ApiException('Máy chủ phản hồi chậm. Vui lòng thử lại.');
    } on SocketException {
      throw const ApiException(
        'Không kết nối được máy chủ. Kiểm tra mạng và địa chỉ API.',
      );
    } on HandshakeException {
      throw const ApiException(
        'Không xác minh được kết nối HTTPS của máy chủ.',
      );
    } on HttpException {
      throw const ApiException('Kết nối bị gián đoạn. Vui lòng thử lại.');
    } on FormatException {
      throw const ApiException('Máy chủ trả về dữ liệu không hợp lệ.');
    }
  }

  @override
  void close() => _client.close(force: true);
}

class ApiClient {
  ApiClient({
    String baseUrl = defaultApiUrl,
    ApiTransport? transport,
    MediaTransport? mediaTransport,
  }) : _baseUrl = validateBaseUrl(baseUrl),
       _transport = transport ?? IoApiTransport(),
       _mediaTransport = mediaTransport ?? IoMediaTransport();
  String _baseUrl;
  final ApiTransport _transport;
  final MediaTransport _mediaTransport;
  final _uploads = <UploadCancellation>{};
  TokenPair? _tokens;
  Future<void>? _refreshing;
  int _generation = 0;
  Future<void> Function(TokenPair?)? onTokensChanged;
  static String validateBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const ApiException(
        'Nhập địa chỉ gốc HTTPS, ví dụ https://api.example.com',
      );
    }
    return uri.replace(path: '').toString();
  }

  String get baseUrl => _baseUrl;
  void changeBaseUrl(String value) {
    _baseUrl = validateBaseUrl(value);
    setTokens(null);
  }

  TokenPair? get tokens => _tokens;
  void setTokens(TokenPair? value) {
    _generation++;
    _tokens = value;
    _refreshing = null;
    if (value == null) cancelUploads();
  }

  void cancelUploads() {
    for (final upload in _uploads.toList()) {
      upload.cancel();
    }
  }

  Future<String> authenticatedToken() async {
    final generation = _generation;
    final current = _tokens;
    if (current == null) {
      throw const ApiException('Vui lòng đăng nhập lại.', status: 401);
    }
    if (current.expiresAt.isBefore(
      DateTime.now().toUtc().add(const Duration(seconds: 30)),
    )) {
      await _refresh(generation);
    }
    if (generation != _generation || _tokens == null) {
      throw const ApiException('Phiên đã thay đổi.', status: 401);
    }
    return _tokens!.accessToken;
  }

  Future<Map<String, dynamic>> uploadAiFile(
    File file, {
    required String mediaType,
    required String contentType,
    required String requestId,
    UploadCancellation? cancellation,
    void Function(int, int)? onProgress,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(requestId) ||
        !((mediaType == 'image' &&
                {'image/jpeg', 'image/png'}.contains(contentType)) ||
            (mediaType == 'video' && contentType == 'video/mp4'))) {
      throw const ApiException('Định dạng tệp hoặc mã yêu cầu không hợp lệ.');
    }
    final size = await file.length();
    final maxSize = (mediaType == 'image' ? 12 : 80) * 1024 * 1024;
    if (size <= 0 || size > maxSize) {
      throw const ApiException('Ảnh tối đa 12 MiB; video MP4 tối đa 80 MiB.');
    }
    final cancel = cancellation ?? UploadCancellation();
    final generation = _generation;
    final token = await authenticatedToken();
    _uploads.add(cancel);
    try {
      final reply = await _mediaTransport.upload(
        Uri.parse('$_baseUrl/api/v1/ai/jobs?mediaType=$mediaType'),
        {
          'Authorization': 'Bearer $token',
          'Content-Type': contentType,
          'Accept': 'application/json',
          'X-Client-Request-Id': requestId,
        },
        file,
        cancel,
        onProgress,
      );
      if (generation != _generation) {
        throw const ApiException('Phiên đã thay đổi.', status: 401);
      }
      return _decode(reply);
    } finally {
      _uploads.remove(cancel);
    }
  }

  Future<Uint8List> aiPreview(String id) async {
    final generation = _generation;
    var token = await authenticatedToken();
    final uri = Uri.parse(
      '$_baseUrl/api/v1/ai/jobs/${Uri.encodeComponent(id)}/preview',
    );
    var response = await _mediaTransport.download(uri, {
      'Authorization': 'Bearer $token',
    }, 12 * 1024 * 1024);
    if (response.status == 401 && generation == _generation) {
      await _refresh(generation);
      token = await authenticatedToken();
      response = await _mediaTransport.download(uri, {
        'Authorization': 'Bearer $token',
      }, 12 * 1024 * 1024);
    }
    if (generation != _generation) {
      throw const ApiException('Phiên đã thay đổi.', status: 401);
    }
    if (response.status != 200) {
      _decode(
        ApiReply(
          response.status,
          utf8.decode(response.bytes, allowMalformed: true),
        ),
      );
      throw const ApiException('Ảnh kết quả chưa sẵn sàng.');
    }
    return response.bytes;
  }

  Future<Map<String, dynamic>> get(String path) => _request('GET', path, null);
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic>? body) =>
      _request('POST', path, body);
  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body) =>
      _request('PUT', path, body);
  Future<Map<String, dynamic>> delete(String path) =>
      _request('DELETE', path, null);

  Future<Map<String, dynamic>> uploadSecretCipher({
    required String conversationId,
    required String senderDeviceId,
    required String recipientDeviceId,
    required File ciphertext,
    UploadCancellation? cancellation,
  }) async {
    final length = await ciphertext.length();
    if (length < 17 || length > 5 * 1024 * 1024 + 16) {
      throw const ApiException('Ảnh mã hóa vượt giới hạn.');
    }
    final generation = _generation,
        cancel = cancellation ?? UploadCancellation();
    final token = await authenticatedToken();
    _uploads.add(cancel);
    try {
      final result = await _mediaTransport.upload(
        Uri.parse(
          '$_baseUrl/api/v1/secret/conversations/${Uri.encodeComponent(conversationId)}/attachments',
        ).replace(
          queryParameters: {
            'senderDeviceId': senderDeviceId,
            'recipientDeviceId': recipientDeviceId,
          },
        ),
        {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/octet-stream',
          'Accept': 'application/json',
        },
        ciphertext,
        cancel,
        null,
      );
      if (generation != _generation) {
        throw const ApiException('Phiên đã thay đổi.', status: 401);
      }
      return _decode(result);
    } finally {
      _uploads.remove(cancel);
    }
  }

  Future<Uint8List> secretCipherBytes(
    String conversationId,
    String attachmentId,
    String deviceId,
  ) => _privateBytes(
    '/secret/conversations/${Uri.encodeComponent(conversationId)}/attachments/${Uri.encodeComponent(attachmentId)}?deviceId=${Uri.encodeQueryComponent(deviceId)}',
    5 * 1024 * 1024 + 65536,
  );

  Future<Map<String, dynamic>> uploadArticleImage(
    File file,
    String contentType, {
    UploadCancellation? cancellation,
  }) => _uploadPlainImage('/articles/images', file, contentType, cancellation);
  Future<Map<String, dynamic>> sendChatImage(
    String conversationId,
    String clientMessageId,
    File file,
    String contentType, {
    UploadCancellation? cancellation,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(clientMessageId)) {
      throw const ApiException('Mã yêu cầu gửi ảnh không hợp lệ.');
    }
    return _uploadPlainImage(
      '/conversations/${Uri.encodeComponent(conversationId)}/images?clientMessageId=${Uri.encodeQueryComponent(clientMessageId)}',
      file,
      contentType,
      cancellation,
    );
  }

  Future<Map<String, dynamic>> _uploadPlainImage(
    String path,
    File file,
    String contentType,
    UploadCancellation? cancellation,
  ) async {
    if (!{'image/jpeg', 'image/png'}.contains(contentType)) {
      throw const ApiException('Ảnh cần là JPEG hoặc PNG.');
    }
    final length = await file.length();
    if (length < 3 || length > 5 * 1024 * 1024) {
      throw const ApiException('Ảnh tối đa 5 MiB.');
    }
    final generation = _generation,
        cancel = cancellation ?? UploadCancellation(),
        token = await authenticatedToken();
    _uploads.add(cancel);
    try {
      final response = await _mediaTransport.upload(
        Uri.parse('$_baseUrl/api/v1$path'),
        {
          'Authorization': 'Bearer $token',
          'Content-Type': contentType,
          'Accept': 'application/json',
        },
        file,
        cancel,
        null,
      );
      if (generation != _generation) {
        throw const ApiException('Phiên đã thay đổi.', status: 401);
      }
      return _decode(response);
    } finally {
      _uploads.remove(cancel);
    }
  }

  Future<Uint8List> articleImageBytes(String articleId) => _privateBytes(
    '/articles/${Uri.encodeComponent(articleId)}/image',
    5 * 1024 * 1024,
  );
  Future<Uint8List> chatImageBytes(
    String conversationId,
    String imageId,
  ) => _privateBytes(
    '/conversations/${Uri.encodeComponent(conversationId)}/images/${Uri.encodeComponent(imageId)}',
    5 * 1024 * 1024,
  );

  Future<Uint8List> _privateBytes(String path, int limit) async {
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('://')) {
      throw const ApiException('Đường dẫn tải xuống không hợp lệ.');
    }
    final generation = _generation, uri = Uri.parse('$_baseUrl/api/v1$path');
    var token = await authenticatedToken();
    var response = await _mediaTransport.download(uri, {
      'Authorization': 'Bearer $token',
    }, limit);
    if (response.status == 401 && generation == _generation) {
      await _refresh(generation);
      token = await authenticatedToken();
      response = await _mediaTransport.download(uri, {
        'Authorization': 'Bearer $token',
      }, limit);
    }
    if (generation != _generation) {
      throw const ApiException('Phiên đã thay đổi.', status: 401);
    }
    if (response.status != 200) {
      _decode(
        ApiReply(
          response.status,
          utf8.decode(response.bytes, allowMalformed: true),
        ),
      );
      throw const ApiException('Không tải được dữ liệu.');
    }
    if (response.bytes.length > limit) {
      throw const ApiException('Dữ liệu vượt giới hạn.');
    }
    return response.bytes;
  }

  Future<Map<String, dynamic>> uploadEvidence({
    required String applicationId,
    required String category,
    required int expectedRevision,
    required File file,
    required String contentType,
    UploadCancellation? cancellation,
  }) async {
    if (!{'ProductionEvidence', 'BusinessEvidence'}.contains(category) ||
        expectedRevision < 1 ||
        !{'image/jpeg', 'image/png', 'application/pdf'}.contains(contentType)) {
      throw const ApiException('Chứng từ không hợp lệ.');
    }
    final length = await file.length();
    if (length < 1 || length > 5 * 1024 * 1024) {
      throw const ApiException('Chứng từ tối đa 5 MiB.');
    }
    final generation = _generation,
        cancel = cancellation ?? UploadCancellation();
    final token = await authenticatedToken();
    _uploads.add(cancel);
    try {
      final response = await _mediaTransport.upload(
        Uri.parse(
          '$_baseUrl/api/v1/role-applications/${Uri.encodeComponent(applicationId)}/evidence',
        ).replace(
          queryParameters: {
            'category': category,
            'expectedRevision': '$expectedRevision',
          },
        ),
        {
          'Authorization': 'Bearer $token',
          'Content-Type': contentType,
          'Accept': 'application/json',
        },
        file,
        cancel,
        null,
      );
      if (generation != _generation) {
        throw const ApiException('Phiên đã thay đổi.', status: 401);
      }
      return _decode(response);
    } finally {
      _uploads.remove(cancel);
    }
  }

  Future<Uint8List> evidenceBytes(
    String applicationId,
    String evidenceId, {
    bool admin = false,
  }) async {
    final generation = _generation;
    final uri = Uri.parse(
      '$_baseUrl/api/v1/${admin ? 'admin/' : ''}role-applications/${Uri.encodeComponent(applicationId)}/evidence/${Uri.encodeComponent(evidenceId)}',
    );
    var token = await authenticatedToken();
    var response = await _mediaTransport.download(uri, {
      'Authorization': 'Bearer $token',
    }, 5 * 1024 * 1024);
    if (response.status == 401 && generation == _generation) {
      await _refresh(generation);
      token = await authenticatedToken();
      response = await _mediaTransport.download(uri, {
        'Authorization': 'Bearer $token',
      }, 5 * 1024 * 1024);
    }
    if (generation != _generation) {
      throw const ApiException('Phiên đã thay đổi.', status: 401);
    }
    if (response.status != 200) {
      _decode(
        ApiReply(
          response.status,
          utf8.decode(response.bytes, allowMalformed: true),
        ),
      );
      throw const ApiException('Không tải được chứng từ.');
    }
    return response.bytes;
  }

  static const _publicPaths = {
    '/auth/login',
    '/auth/register',
    '/auth/mfa/login',
    '/auth/methods',
    '/auth/otp/verify',
    '/auth/otp/resend',
    '/auth/biometric/challenge',
    '/auth/biometric/login',
    '/auth/face/login',
    '/auth/refresh',
  };
  Future<ApiReply> _send(
    String method,
    String path,
    Map<String, dynamic>? body, {
    String? access,
  }) {
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('://')) {
      throw const ApiException('Đường dẫn API không hợp lệ.');
    }
    return _transport.send(method, Uri.parse('$_baseUrl/api/v1$path'), {
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      if (access != null) 'Authorization': 'Bearer $access',
    }, body == null ? null : jsonEncode(body));
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final generation = _generation;
    final public = _publicPaths.contains(path.split('?').first);
    final sentToken = public ? null : _tokens?.accessToken;
    var reply = await _send(method, path, body, access: sentToken);
    if (reply.status == 401 &&
        !public &&
        sentToken != null &&
        generation == _generation) {
      if (_tokens?.accessToken == sentToken) await _refresh(generation);
      if (generation != _generation || _tokens == null) {
        throw const ApiException('Phiên đăng nhập đã kết thúc.', status: 401);
      }
      reply = await _send(method, path, body, access: _tokens!.accessToken);
    }
    if (generation != _generation && !public) {
      throw const ApiException('Phiên đăng nhập đã thay đổi.', status: 401);
    }
    return _decode(reply);
  }

  Future<void> _refresh(int generation) {
    final existing = _refreshing;
    if (existing != null) return existing;
    final future = _rotate(generation);
    _refreshing = future;
    return future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
  }

  Future<void> _rotate(int generation) async {
    final current = _tokens;
    if (current == null) {
      throw const ApiException('Vui lòng đăng nhập lại.', status: 401);
    }
    final reply = await _send('POST', '/auth/refresh', {
      'refreshToken': current.refreshToken,
    });
    if (generation != _generation) {
      throw const ApiException('Phiên đã thay đổi.', status: 401);
    }
    if (reply.status == 401 || reply.status == 403) {
      _tokens = null;
      await onTokensChanged?.call(null);
      throw const ApiException(
        'Phiên đã hết hạn. Vui lòng đăng nhập lại.',
        status: 401,
      );
    }
    final next = TokenPair.fromResponse(_decode(reply));
    // Persist the rotated pair before any protected request retries.
    try {
      await onTokensChanged?.call(next);
    } catch (_) {
      _tokens = null;
      throw const ApiException(
        'Không lưu được phiên an toàn. Vui lòng đăng nhập lại.',
        status: 401,
      );
    }
    if (generation != _generation) {
      throw const ApiException('Phiên đã thay đổi.', status: 401);
    }
    _tokens = next;
  }

  Map<String, dynamic> _decode(ApiReply reply) {
    Map<String, dynamic> json = {};
    if (reply.body.trim().isNotEmpty) {
      try {
        final data = jsonDecode(reply.body);
        if (data is Map<String, dynamic>) {
          json = data;
        } else if (reply.status < 400) {
          throw const FormatException();
        }
      } on FormatException {
        if (reply.status < 400) {
          throw const ApiException('Dữ liệu máy chủ không hợp lệ.');
        }
      }
    }
    if (reply.status >= 200 && reply.status < 300) return json;
    final fallback = switch (reply.status) {
      400 || 422 => 'Thông tin chưa hợp lệ. Kiểm tra các trường đã nhập.',
      401 => 'Email, mật khẩu, mã xác thực hoặc phiên đăng nhập không hợp lệ.',
      403 => 'Tài khoản chưa được phép thực hiện thao tác này.',
      404 => 'Không tìm thấy dữ liệu.',
      409 => 'Dữ liệu đã thay đổi hoặc bị trùng. Hãy tải lại.',
      429 => 'Thao tác quá nhanh. Vui lòng chờ một lát.',
      _ => 'Máy chủ tạm thời không sẵn sàng. Vui lòng thử lại.',
    };
    final detail = json['detail'];
    final safe =
        reply.status < 500 &&
            detail is String &&
            detail.length <= 400 &&
            !detail.contains('<') &&
            !detail.contains('Exception')
        ? detail
        : fallback;
    throw ApiException(safe, status: reply.status);
  }

  void close() {
    cancelUploads();
    _transport.close();
    _mediaTransport.close();
  }
}
