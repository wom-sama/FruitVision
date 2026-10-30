import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../session.dart';
import 'components.dart';

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
  final _region = TextEditingController(), _code = TextEditingController();
  bool _register = false, _obscure = true;
  UserRole _role = UserRole.producer;
  @override
  void dispose() {
    for (final field in [_email, _password, _confirm, _name, _region, _code]) {
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
        region: _region.text.trim(),
        role: _role,
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
                            ? 'Xác thực hai bước'
                            : _register
                            ? 'Tạo tài khoản'
                            : 'Chào mừng trở lại',
                        subtitle: mfa
                            ? 'Nhập mã 6 chữ số từ ứng dụng xác thực của bạn.'
                            : _register
                            ? 'Chọn vai trò của bạn. Hồ sơ mới cần được quản trị xét duyệt.'
                            : 'Đăng nhập để theo dõi hồ sơ, tin dự kiến và trao đổi.',
                      ),
                      if (c.error != null) ...[
                        MessageBox(c.error!, error: true),
                        const SizedBox(height: 16),
                      ],
                      if (c.notice != null) ...[
                        MessageBox(c.notice!),
                        const SizedBox(height: 16),
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
                          DropdownButtonFormField<UserRole>(
                            initialValue: _role,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Vai trò',
                            ),
                            items:
                                [
                                      UserRole.producer,
                                      UserRole.trader,
                                      UserRole.consumer,
                                    ]
                                    .map(
                                      (role) => DropdownMenuItem(
                                        value: role,
                                        child: Text(role.label),
                                      ),
                                    )
                                    .toList(),
                            onChanged: c.busy
                                ? null
                                : (role) => setState(() => _role = role!),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _region,
                            enabled: !c.busy,
                            maxLength: 120,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Khu vực / tỉnh thành',
                            ),
                            validator: requiredText,
                            onFieldSubmitted: (_) => _submit(),
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
                        'Tin dự kiến chưa phải tồn kho sẵn bán. Phân tích ảnh/video chạy tại máy chủ khi dịch vụ AI sẵn sàng.',
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
