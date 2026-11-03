import 'package:flutter/material.dart';
import '../core/auth_state.dart';
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
  void dispose() { _email.dispose(); _password.dispose(); super.dispose(); }
  Future<void> _submit() async {
    setState(() => _busy = true);
    try { await widget.auth.authenticate(email: _email.text, password: _password.text, register: _register); }
    catch (e) { if (mounted) showError(context, e); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
    const Icon(Icons.spa_outlined, size: 64, color: Color(0xFF0A6B78)),
    const SizedBox(height: 16),
    Text('خطوة', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineLarge),
    const SizedBox(height: 10),
    const Text('لكل طالب طريقته في التعلم، ولكل خطوة أثر في التقدم', textAlign: TextAlign.center),
    const SizedBox(height: 24), const PrototypeNote(),
    const SizedBox(height: 20),
    Text(_register ? 'إنشاء حساب المختصة' : 'تسجيل الدخول', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 16),
    TextField(controller: _email, keyboardType: TextInputType.emailAddress, textDirection: TextDirection.ltr, autofillHints: const [AutofillHints.username], decoration: const InputDecoration(labelText: 'البريد الإلكتروني للمختصة')),
    const SizedBox(height: 12),
    TextField(controller: _password, obscureText: !_showPassword, textDirection: TextDirection.ltr, autofillHints: const [AutofillHints.password], maxLength: 128, decoration: InputDecoration(labelText: 'كلمة المرور — 12 حرفًا على الأقل', suffixIcon: IconButton(onPressed: () => setState(() => _showPassword = !_showPassword), icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility)))),
    const SizedBox(height: 12),
    FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'جارٍ التحقق…' : _register ? 'إنشاء الحساب' : 'ابدأ الآن')),
    TextButton(onPressed: _busy ? null : () => setState(() => _register = !_register), child: Text(_register ? 'لدي حساب بالفعل' : 'إنشاء حساب جديد')),
    TextButton(onPressed: _busy ? null : () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PasswordResetScreen(auth: widget.auth))), child: const Text('استعادة كلمة المرور')),
    if (widget.auth.error != null) Text(widget.auth.error!),
    const SizedBox(height: 12),
    const Text('يلزم الاتصال لأول دخول. بعد ذلك تُحفظ ملفات هذا الحساب مشفّرة على الجهاز للعمل دون اتصال، وتتم مزامنتها من زر المزامنة أو عند العودة للتطبيق.', style: TextStyle(fontSize: 12)),
  ])))));
}

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key, required this.auth});
  final AuthState auth;
  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}
class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _email = TextEditingController(), _token = TextEditingController(), _password = TextEditingController();
  bool _busy = false;
  @override
  void dispose() { _email.dispose(); _token.dispose(); _password.dispose(); super.dispose(); }
  Future<void> _perform(bool confirm) async {
    setState(() => _busy = true);
    try {
      if (confirm) { await widget.auth.confirmReset(_token.text, _password.text); }
      else { await widget.auth.requestReset(_email.text); }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(confirm ? 'تم تحديث كلمة المرور؛ سجّل الدخول مجددًا.' : 'إذا كان البريد مسجلًا فستصلك تعليمات الاستعادة عند تفعيل خدمة البريد.')));
    } catch (e) { if (mounted) showError(context, e); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('استعادة كلمة المرور')), body: ListView(padding: const EdgeInsets.all(24), children: [
    TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'بريد الحساب')),
    const SizedBox(height: 12), FilledButton(onPressed: _busy ? null : () => _perform(false), child: const Text('طلب رابط الاستعادة')),
    const SectionHeading('لدي رمز الاستعادة'),
    TextField(controller: _token, obscureText: true, decoration: const InputDecoration(labelText: 'الرمز الوارد في الرابط')),
    const SizedBox(height: 12), TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور الجديدة (12 حرفًا على الأقل)')),
    const SizedBox(height: 12), FilledButton(onPressed: _busy ? null : () => _perform(true), child: const Text('تحديث كلمة المرور')),
  ]));
}
