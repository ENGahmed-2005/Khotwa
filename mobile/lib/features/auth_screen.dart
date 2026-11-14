import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/auth_state.dart';
import '../core/khotwa_theme.dart';
import '../widgets/khotwa_ui.dart';
import '../widgets/common.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.auth});
  final AuthState auth;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false, _busy = false, _showPassword = false;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.auth.authenticate(
        email: _email.text,
        password: _password.text,
        register: _register,
      );
    } catch (e) {
      if (mounted) {
        if (e is ApiException && e.code == 'ACCOUNT_UNAVAILABLE') {
          setState(() => _register = false);
        }
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(22),
            children: [
              const SizedBox(height: 12),
              Row(
                children: [
                  const KhotwaBrandMark(size: 72),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'خطوة',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'معًا.. نحو تعلّم أفضل',
                          style: TextStyle(
                            color: KhotwaPalette.muted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Text(
                'عملكِ التربوي، خطوة بخطوة.',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'ملفات منظمة وخطط تراجعينها بنفسكِ، لتكون متابعة كل طالب أوضح وأسهل.',
                style: TextStyle(color: KhotwaPalette.muted, height: 1.8),
              ),
              const SizedBox(height: 24),
              const PrototypeNote(),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _register ? 'إنشاء حساب المختصة' : 'تسجيل الدخول',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _register
                              ? 'ابدئي مساحة عمل خاصة بملفات طلابكِ.'
                              : 'أهلاً بعودتكِ. لنكمل من حيث توقفتِ.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _register = !_register),
                            child: Text(
                              _register ? 'لدي حساب بالفعل' : 'إنشاء حساب جديد',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _email,
                          enabled: !_busy,
                          autocorrect: false,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          textDirection: TextDirection.ltr,
                          autofillHints: const [AutofillHints.username],
                          decoration: const InputDecoration(
                            labelText: 'البريد الإلكتروني للمختصة',
                            prefixIcon: Icon(Icons.mail_outline_rounded),
                          ),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _password,
                          enabled: !_busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          obscureText: !_showPassword,
                          textDirection: TextDirection.ltr,
                          textInputAction: TextInputAction.done,
                          onSubmitted: _busy ? null : (_) => _submit(),
                          autofillHints: [
                            _register
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          maxLength: 128,
                          decoration: InputDecoration(
                            labelText: 'كلمة المرور — 12 حرفًا على الأقل',
                            counterText: '',
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              tooltip: _showPassword
                                  ? 'إخفاء كلمة المرور'
                                  : 'إظهار كلمة المرور',
                              onPressed: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (!_register)
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (_) => PasswordResetScreen(
                                          auth: widget.auth,
                                        ),
                                      ),
                                    ),
                              child: const Text('استعادة كلمة المرور'),
                            ),
                          ),
                        if (widget.auth.error != null &&
                            widget.auth.error != widget.auth.cleanupWarning)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              widget.auth.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          style: _busy
                              ? FilledButton.styleFrom(
                                  disabledBackgroundColor: KhotwaPalette.navy,
                                  disabledForegroundColor: Colors.white,
                                )
                              : null,
                          child: _busy
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const SizedBox(
                                      width: 17,
                                      height: 17,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Flexible(
                                      child: Text(
                                        widget.auth.busyMessage ??
                                            'جارٍ التحقق…',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ],
                                )
                              : Text(_register ? 'إنشاء الحساب' : 'ابدأ الآن'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 17,
                    color: KhotwaPalette.muted,
                  ),
                  SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      'ملفات الطلبة برموز مجهّلة',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: KhotwaPalette.muted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'يلزم الاتصال لأول دخول. بعدها يمكنكِ حفظ العمل على هذا الجهاز ومزامنته عند عودة الاتصال.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.8,
                  color: KhotwaPalette.muted,
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    ),
  );
}

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key, required this.auth});
  final AuthState auth;
  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _email = TextEditingController(),
      _token = TextEditingController(),
      _password = TextEditingController();
  bool _busy = false;
  @override
  void dispose() {
    _email.dispose();
    _token.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _perform(bool confirm) async {
    setState(() => _busy = true);
    try {
      if (confirm) {
        await widget.auth.confirmReset(_token.text, _password.text);
      } else {
        await widget.auth.requestReset(_email.text);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              confirm
                  ? 'تم تحديث كلمة المرور؛ سجّل الدخول مجددًا.'
                  : 'إذا كان البريد مسجلًا فستصلك تعليمات الاستعادة عند تفعيل خدمة البريد.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('استعادة كلمة المرور')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'بريد الحساب'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : () => _perform(false),
          child: const Text('طلب رابط الاستعادة'),
        ),
        const SectionHeading('لدي رمز الاستعادة'),
        TextField(
          controller: _token,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'الرمز الوارد في الرابط',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'كلمة المرور الجديدة (12 حرفًا على الأقل)',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : () => _perform(true),
          child: const Text('تحديث كلمة المرور'),
        ),
      ],
    ),
  );
}
