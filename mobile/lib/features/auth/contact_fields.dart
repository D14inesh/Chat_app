import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../theme.dart';
import 'session.dart';

/// Mobile number + Gmail + the 6-digit code emailed to that Gmail — the
/// same three fields as the website's sign-up form. One account per number
/// and per Gmail; the server checks both.
class ContactFields extends ConsumerStatefulWidget {
  final TextEditingController phone;
  final TextEditingController email;
  final TextEditingController otp;

  /// true on the sign-up form (no account yet), false when an existing
  /// account adds or changes its number + Gmail.
  final bool signup;
  final void Function(String message) onError;

  const ContactFields({
    super.key,
    required this.phone,
    required this.email,
    required this.otp,
    required this.signup,
    required this.onError,
  });

  @override
  ConsumerState<ContactFields> createState() => _ContactFieldsState();
}

class _ContactFieldsState extends ConsumerState<ContactFields> {
  static const _resendSeconds = 45;
  bool _sending = false;
  int _wait = 0;
  String? _hint;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    if (widget.phone.text.trim().isEmpty || widget.email.text.trim().isEmpty) {
      widget.onError('Enter your mobile number and Gmail first.');
      return;
    }
    setState(() {
      _sending = true;
      _hint = null;
    });
    try {
      final res = await ref.read(sessionControllerProvider).api.sendContactCode(
            phone: widget.phone.text,
            email: widget.email.text,
            signup: widget.signup,
          );
      final dev = res['devCode'] as String?;
      setState(() {
        _hint = dev != null
            ? 'Test mode (no email set up): your code is $dev'
            : 'Code sent to ${widget.email.text.trim()} — check your inbox (and Spam).';
        _wait = _resendSeconds;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        setState(() => _wait--);
        if (_wait <= 0) t.cancel();
      });
    } on ApiException catch (e) {
      widget.onError(e.message);
    } catch (_) {
      widget.onError('Could not reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _sending
        ? 'Sending…'
        : _wait > 0
            ? 'Resend ${_wait}s'
            : _hint == null
                ? 'Send code'
                : 'Resend';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.phone,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(labelText: 'Mobile number', hintText: '98765 43210'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: widget.email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(labelText: 'Gmail', hintText: 'you@gmail.com'),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: widget.otp,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                style: const TextStyle(color: Colors.white, letterSpacing: 4),
                decoration: const InputDecoration(labelText: 'Code from your Gmail'),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 50,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: VeyonColors.line),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _sending || _wait > 0 ? null : _send,
                child: Text(label),
              ),
            ),
          ],
        ),
        if (_hint != null) ...[
          const SizedBox(height: 8),
          Text(_hint!, style: const TextStyle(color: VeyonColors.online, fontSize: 12.5)),
        ],
      ],
    );
  }
}

/// Add / change my mobile number + Gmail. `blocking`: an older account
/// must finish this before using the app (its only way out is Sign out).
class VerifyContactScreen extends ConsumerStatefulWidget {
  final bool blocking;
  const VerifyContactScreen({super.key, this.blocking = false});

  @override
  ConsumerState<VerifyContactScreen> createState() => _VerifyContactScreenState();
}

class _VerifyContactScreenState extends ConsumerState<VerifyContactScreen> {
  late final TextEditingController _phone;
  late final TextEditingController _email;
  final _otp = TextEditingController();
  bool _saving = false;
  String? _error;
  final _scroll = ScrollController();

  void _fail(String message) {
    setState(() => _error = message);
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  void initState() {
    super.initState();
    final me = ref.read(sessionControllerProvider).user;
    _phone = TextEditingController(text: me?.phone ?? '');
    _email = TextEditingController(text: me?.email ?? '');
  }

  @override
  void dispose() {
    _phone.dispose();
    _email.dispose();
    _otp.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_otp.text.trim().length != 6) {
      _fail('Tap “Send code”, then enter the 6-digit code from your Gmail.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(sessionControllerProvider.notifier).updateContact(phone: _phone.text, email: _email.text, otp: _otp.text);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(widget.blocking ? 'Account verified — thank you!' : 'Mobile number and Gmail updated.'),
      ));
      // The blocking version disappears by itself once the session says verified.
      if (!widget.blocking) Navigator.of(context).pop();
    } on ApiException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('Could not reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return PopScope(
      canPop: !widget.blocking,
      child: Scaffold(
        backgroundColor: widget.blocking ? VeyonColors.bgDark : null,
        appBar: widget.blocking ? null : AppBar(title: const Text('Mobile number & Gmail')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: CircleAvatar(
                        radius: 30,
                        backgroundColor: accent.withValues(alpha: 0.16),
                        child: Icon(Icons.verified_user_rounded, color: accent, size: 30),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (widget.blocking)
                      const Text('Verify your account',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(
                      widget.blocking
                          ? 'Each account now needs its own mobile number and Gmail — one account per number. We’ll email you a code.'
                          : 'One account per mobile number and Gmail. Changing them needs a new code from your Gmail.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: VeyonColors.muted, height: 1.4),
                    ),
                    const SizedBox(height: 22),
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: VeyonColors.danger.withValues(alpha: 0.12),
                          border: Border.all(color: VeyonColors.danger.withValues(alpha: 0.5)),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_error!, style: const TextStyle(color: Color(0xFFFFC2C2), fontSize: 13.5)),
                      ),
                      const SizedBox(height: 16),
                    ],
                    ContactFields(
                      phone: _phone,
                      email: _email,
                      otp: _otp,
                      signup: false,
                      onError: _fail,
                    ),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      child: _saving
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                          : Text(widget.blocking ? 'Verify & continue' : 'Save'),
                    ),
                    if (widget.blocking) ...[
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _saving ? null : () => ref.read(sessionControllerProvider.notifier).logout(),
                        child: const Text('Sign out', style: TextStyle(color: VeyonColors.muted)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
