import 'login_approval.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/branding.dart';
import '../../theme.dart';
import '../link/qr_login_screen.dart';
import '../account/recovery.dart';
import 'contact_fields.dart';
import 'session.dart';
import '../account/birth_date.dart';

/// Combined login/register screen — mirrors public/index.html's #auth-screen
/// toggle behavior (one form, a mode switch, the same fields) rather than
/// two separate routes.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _registering = false;
  bool _loading = false;
  String? _error;

  final _usernameCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  DateTime? _birth;
  final _scroll = ScrollController();

  /// Shows [message] in the banner and scrolls up to it — the sign-up form
  /// is taller than the screen, so the banner would otherwise be out of view.
  void _fail(String message) {
    setState(() => _error = message);
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    _usernameCtrl.dispose();
    _displayNameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = ref.read(sessionControllerProvider.notifier);
      if (_registering) {
        if (_otpCtrl.text.trim().length != 6) {
          _fail('Tap “Send code”, then enter the 6-digit code from your Gmail.');
          return;
        }
        await controller.register(
          birthDate: _birth == null ? null : BirthDateField.iso(_birth!),
          phone: _phoneCtrl.text,
          email: _emailCtrl.text,
          otp: _otpCtrl.text.trim(),
          username: _usernameCtrl.text.trim(),
          displayName: _displayNameCtrl.text.trim().isEmpty
              ? _usernameCtrl.text.trim()
              : _displayNameCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      } else {
        await controller.login(
          username: _usernameCtrl.text.trim(),
          password: _passwordCtrl.text,
          // New phone for this account: wait for the owner to accept it.
          onPending: (p) => waitForLoginApproval(context, ref.read(sessionControllerProvider).api, p),
        );
      }
    } on ApiException catch (e) {
      _fail(e.message);
    } on DioException catch (e) {
      // Couldn't even reach the server (wrong/unreachable address, phone not
      // on the same network, firewall, timeout) — a very different problem
      // from a rejected login, so it gets a message that says so instead of
      // the generic fallback below.
      _fail('Could not reach the server. Check that your phone is on the '
          'same network as the server and try again. (${e.type.name})');
    } catch (e) {
      _fail('Something went wrong. Please try again.\n$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgot() async {
    final result = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(builder: (_) => ForgotPasswordScreen(initialIdent: _usernameCtrl.text.trim())),
    );
    if (result == null || !mounted) return;
    _usernameCtrl.text = result.$1;
    _passwordCtrl.text = result.$2;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password changed — signing you in. Your other devices were signed out.')),
    );
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VeyonColors.bgDark,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Brand(),
                  const SizedBox(height: 28),
                  Text(
                    _registering ? 'Create your account' : 'Welcome back',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Private messaging, end to end.',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13.5),
                  ),
                  const SizedBox(height: 26),
                  if (_error != null) ...[
                    _ErrorBanner(message: _error!),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _usernameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(labelText: _registering ? 'Username' : 'Username, mobile or Gmail'),
                    autocorrect: false,
                  ),
                  if (_registering) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _displayNameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Display name'),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  if (!_registering)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _loading ? null : _forgot,
                        child: const Text('Forgot password?'),
                      ),
                    ),
                  if (_registering) ...[
                    const SizedBox(height: 14),
                    BirthDateField(value: _birth, optional: true, onChanged: (d) => setState(() => _birth = d)),
                    const SizedBox(height: 14),
                    ContactFields(
                      phone: _phoneCtrl,
                      email: _emailCtrl,
                      otp: _otpCtrl,
                      signup: true,
                      onError: _fail,
                    ),
                  ],
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                            )
                          : Text(_registering ? 'Create account' : 'Sign in'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: _loading ? null : () => setState(() => _registering = !_registering),
                    child: Text(
                      _registering ? 'Already have an account? Sign in' : "New here? Create an account",
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.75)),
                    ),
                  ),
                  if (!_registering)
                    TextButton.icon(
                      onPressed: _loading
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrLoginScreen())),
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18, color: VeyonColors.muted),
                      label: const Text('Log in with QR from another device', style: TextStyle(color: VeyonColors.muted)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = ref.watch(brandingProvider).valueOrNull ?? const Branding();
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: brand.logo == null ? VeyonColors.bubbleGradient : null,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(color: VeyonColors.bubbleMe.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: brand.logo != null
              ? Image.memory(brand.logo!, fit: BoxFit.cover, gaplessPlayback: true)
              : const Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 28),
        ),
        const SizedBox(height: 14),
        Text(
          brand.name,
          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: VeyonColors.danger.withValues(alpha: 0.12),
        border: Border.all(color: VeyonColors.danger.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: const TextStyle(color: Color(0xFFFFC2C2), fontSize: 13.5)),
    );
  }
}
