import 'package:flutter/material.dart';

import 'dart:async';

import 'package:flutter/services.dart';

import '../session.dart';
import 'components.dart';
import 'location_picker.dart';
import 'face_photo.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, required this.controller});
  final SessionController controller;
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(), _password = TextEditingController();
  final _confirm = TextEditingController(), _name = TextEditingController();
  final _code = TextEditingController();
  LocationSelection? _location;
  bool _register = false, _obscure = true;
  Timer? _clock;
  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          widget.controller.mfaChallenge != null &&
          widget.controller.mfaMethod == 'email') {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    for (final field in [_email, _password, _confirm, _name, _code]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = widget.controller;
    if (controller.busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    if (controller.mfaChallenge != null) {
      await controller.completeMfa(_code.text);
    } else if (_register) {
      final success = await controller.register(
        displayName: _name.text.trim(),
        email: _email.text.trim(),
        password: _password.text,
        countryCode: _location!.countryCode,
        provinceCode: _location!.provinceCode,
      );
      if (success && mounted) {
        setState(() {
          _register = false;
          _password.clear();
          _confirm.clear();
        });
      }
    } else {
      await controller.login(_email.text.trim(), _password.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final mfa = c.mfaChallenge != null;
    final emailOtp = mfa && c.mfaMethod == 'email';
    return Scaffold(
      appBar: AppBar(
        title: const Text('FruitVision'),
        actions: [
          IconButton(
            tooltip: 'Cài đặt máy chủ',
            onPressed: c.busy ? null : () => openServerSettings(context, c),
            icon: const Icon(Icons.dns_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        mfa ? Icons.verified_user_outlined : Icons.eco_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      SectionTitle(
                        mfa
                            ? emailOtp
                                  ? 'Xác thực email'
                                  : 'Xác thực hai bước'
                            : _register
                            ? 'Tạo tài khoản'
                            : 'Chào mừng trở lại',
                        subtitle: mfa
                            ? emailOtp
                                  ? 'Nhập mã 6 chữ số gửi đến ${c.mfaEmailHint ?? 'email của bạn'}.'
                                  : 'Nhập mã 6 chữ số từ ứng dụng xác thực của bạn.'
                            : _register
                            ? 'Bắt đầu với tài khoản Người tiêu dùng. Bạn có thể gửi hồ sơ nâng vai trò sau khi xác minh email.'
                            : 'Đăng nhập để học về xoài, chia sẻ cùng cộng đồng và dùng chức năng theo vai trò.',
                      ),
                      if (c.error != null) ...[
                        MessageBox(c.error!, error: true),
                        const SizedBox(height: 16),
                      ],
                      if (c.notice != null) ...[
                        MessageBox(c.notice!),
                        const SizedBox(height: 16),
                      ],
                      if (emailOtp && c.mfaMailSubject != null) ...[
                        MessageBox(
                          'Tìm email có tiêu đề “${c.mfaMailSubject}”. Mã này dùng để xác thực FruitVision.',
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (mfa)
                        TextFormField(
                          controller: _code,
                          enabled: !c.busy,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          autofillHints: const [AutofillHints.oneTimeCode],
                          decoration: const InputDecoration(
                            labelText: 'Mã xác thực',
                          ),
                          validator: (v) => RegExp(r'^\d{6}$').hasMatch(v ?? '')
                              ? null
                              : 'Nhập đủ 6 chữ số.',
                          onFieldSubmitted: (_) => _submit(),
                        )
                      else ...[
                        if (_register) ...[
                          TextFormField(
                            controller: _name,
                            enabled: !c.busy,
                            textCapitalization: TextCapitalization.words,
                            maxLength: 100,
                            decoration: const InputDecoration(
                              labelText: 'Tên hiển thị',
                            ),
                            validator: requiredText,
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextFormField(
                          controller: _email,
                          enabled: !c.busy,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          autofillHints: const [AutofillHints.email],
                          maxLength: 254,
                          decoration: const InputDecoration(labelText: 'Email'),
                          validator: (v) =>
                              RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                  .hasMatch(v?.trim() ?? '')
                              ? null
                              : 'Nhập địa chỉ email hợp lệ.',
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _password,
                          enabled: !c.busy,
                          obscureText: _obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLength: 128,
                          autofillHints: [
                            _register
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          decoration: InputDecoration(
                            labelText: 'Mật khẩu',
                            helperText: _register
                                ? 'Ít nhất 12 ký tự; có chữ hoa, chữ thường, số và ký hiệu.'
                                : null,
                            helperMaxLines: 3,
                            suffixIcon: IconButton(
                              tooltip: _obscure
                                  ? 'Hiện mật khẩu'
                                  : 'Ẩn mật khẩu',
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (v) =>
                              (v?.length ?? 0) < (_register ? 12 : 1)
                              ? _register
                                    ? 'Mật khẩu cần ít nhất 12 ký tự.'
                                    : 'Vui lòng nhập mật khẩu.'
                              : null,
                          textInputAction: _register
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onFieldSubmitted: (_) {
                            if (!_register) _submit();
                          },
                        ),
                        if (_register) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _confirm,
                            enabled: !c.busy,
                            obscureText: _obscure,
                            autocorrect: false,
                            enableSuggestions: false,
                            maxLength: 128,
                            decoration: const InputDecoration(
                              labelText: 'Xác nhận mật khẩu',
                            ),
                            validator: (v) => v == _password.text
                                ? null
                                : 'Mật khẩu xác nhận chưa khớp.',
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 12),
                          CountryProvincePicker(
                            api: c.api,
                            enabled: !c.busy,
                            onChanged: (location) => _location = location,
                          ),
                        ],
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: c.busy ? null : _submit,
                        child: Text(
                          c.busy
                              ? 'Đang xử lý…'
                              : mfa
                              ? 'Xác thực và đăng nhập'
                              : _register
                              ? 'Gửi đăng ký'
                              : 'Đăng nhập',
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (!mfa && !_register)
                        OutlinedButton.icon(
                          onPressed: c.busy
                              ? null
                              : () {
                                  final email = _email.text.trim();
                                  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                      .hasMatch(email)) {
                                    _form.currentState!.validate();
                                    return;
                                  }
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => FacePhotoPage(
                                        controller: c,
                                        enroll: false,
                                        email: email,
                                      ),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.face_outlined),
                          label: const Text('Đối chiếu ảnh + mã email'),
                        ),
                      if (!mfa && !_register && c.biometrics.supported)
                        OutlinedButton.icon(
                          onPressed: c.busy
                              ? null
                              : () => c.loginBiometric(_email.text),
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Đăng nhập bằng sinh trắc học'),
                        ),
                      if (emailOtp) ...[
                        TextButton.icon(
                          onPressed: c.busy || c.mfaResendSeconds > 0
                              ? null
                              : () async {
                                  final sent = await c.resendEmailOtp();
                                  if (sent) _code.clear();
                                },
                          icon: const Icon(Icons.mark_email_unread_outlined),
                          label: Text(
                            c.mfaResendSeconds > 0
                                ? 'Gửi lại sau ${c.mfaResendSeconds} giây'
                                : 'Gửi lại mã email',
                          ),
                        ),
                        const Text(
                          'Mã hết hạn sau 10 phút, tối đa 5 lần nhập sai. Gửi lại không đặt lại số lần nhập sai.',
                        ),
                      ],
                      TextButton(
                        onPressed: c.busy
                            ? null
                            : () {
                                if (mfa) {
                                  c.cancelMfa();
                                  _code.clear();
                                } else {
                                  setState(() {
                                    _register = !_register;
                                    _form.currentState?.reset();
                                  });
                                }
                              },
                        child: Text(
                          mfa
                              ? 'Quay lại đăng nhập'
                              : _register
                              ? 'Đã có tài khoản? Đăng nhập'
                              : 'Chưa có tài khoản? Đăng ký',
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Nhận diện xoài từ ảnh/video chạy trên máy chủ. Kết quả chỉ để tham khảo, không thay thế kiểm tra chất lượng thực tế.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
