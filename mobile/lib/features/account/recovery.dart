/// Recovery key + "Forgot password?" — same flow as the website.
///
/// Chats are encrypted with a key only the password unlocks. A recovery key
/// is a second way to unlock it, shown once and never sent to the server.
/// With it a password reset keeps every old message; without it a reset
/// has to start a fresh key.
library recovery;

import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api_client.dart';
import '../../core/crypto/identity.dart';
import '../../core/crypto/keys.dart';
import '../../theme.dart';
import '../auth/session.dart';

const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I

String newRecoveryKey() {
  final rnd = Random.secure();
  final chars = List.generate(24, (_) => _alphabet[rnd.nextInt(256) % _alphabet.length]).join();
  return [for (var i = 0; i < 24; i += 6) chars.substring(i, i + 6)].join('-');
}

/// What the user typed → the exact string the key was wrapped with.
String normalizeRecoveryKey(String s) {
  final clean = s.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  return [for (var i = 0; i < clean.length; i += 6) clean.substring(i, min(i + 6, clean.length))].join('-');
}

Widget _hero(BuildContext context, String title, String text) {
  final accent = Theme.of(context).colorScheme.secondary;
  return Column(children: [
    CircleAvatar(
      radius: 30,
      backgroundColor: accent.withValues(alpha: 0.16),
      child: Icon(Icons.key_rounded, color: accent, size: 30),
    ),
    const SizedBox(height: 14),
    Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
    const SizedBox(height: 6),
    Text(text, textAlign: TextAlign.center, style: const TextStyle(color: VeyonColors.muted, height: 1.4)),
  ]);
}

Widget _errorBox(String message) => Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: VeyonColors.danger.withValues(alpha: 0.12),
        border: Border.all(color: VeyonColors.danger.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: const TextStyle(color: Color(0xFFFFC2C2), fontSize: 13.5)),
    );

// ── Create a recovery key (signed in) ───────────────────────

class RecoveryKeyScreen extends ConsumerStatefulWidget {
  const RecoveryKeyScreen({super.key});
  @override
  ConsumerState<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends ConsumerState<RecoveryKeyScreen> {
  final _password = TextEditingController();
  String? _key;
  String? _error;
  bool _busy = false;
  bool _saved = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(sessionControllerProvider).api;
      // Unlock the account's copy of the key with the password (that also checks it).
      final me = await api.me();
      final EcKeyPair pair;
      try {
        pair = await unwrapPrivateKey(WrappedPrivateKey.fromJson(me['encPrivateKey'] as Map<String, dynamic>), _password.text);
      } catch (_) {
        throw ApiException(400, 'That password isn’t right.');
      }
      final key = newRecoveryKey();
      final wrapped = await wrapPrivateKey(pair, key);
      await api.postJson('/api/auth/recovery-key', {'encPrivateKeyRecovery': wrapped.toJson()});
      await ref.read(sessionControllerProvider.notifier).markRecoveryKeySaved();
      setState(() => _key = key);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionControllerProvider).user;
    final key = _key;
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery key')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: [
          _hero(
            context,
            me?.hasRecoveryKey == true && key == null ? 'Make a new recovery key' : 'Your recovery key',
            'If you ever forget your password, this key lets you reset it and keep all your old messages. '
                'Only you will have it — it can’t be shown again.',
          ),
          const SizedBox(height: 22),
          if (_error != null) _errorBox(_error!),
          if (key == null) ...[
            TextField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Your password'),
              onSubmitted: (_) => _busy ? null : _make(),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : _make,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: Text(_busy ? 'Creating…' : 'Create key'),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: VeyonColors.line),
              ),
              child: SelectableText(
                key,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1.4),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: key));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recovery key copied.')));
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Share.share(
                    'Veyon Chat recovery key for @${me?.username}:\n$key\n\nUse it with "Forgot password?" to keep your messages. Keep it private.',
                    subject: 'Veyon Chat recovery key',
                  ),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Save / share'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            CheckboxListTile(
              value: _saved,
              onChanged: (v) => setState(() => _saved = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('I’ve saved it somewhere safe (not only on this phone)', style: TextStyle(fontSize: 14)),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saved ? () => Navigator.of(context).pop() : null,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: const Text('Done'),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Forgot password (signed out) ────────────────────────────

/// Pops with (username, newPassword) once the reset is done, so the sign-in
/// screen can sign in straight away.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  final String initialIdent;
  const ForgotPasswordScreen({super.key, this.initialIdent = ''});
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  late final _ident = TextEditingController(text: widget.initialIdent);
  final _otp = TextEditingController();
  final _password = TextEditingController();
  final _recovery = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _sentTo;
  String? _error;
  Map<String, dynamic>? _verified; // {resetToken, username, recoveryWrapped}

  ApiClient get _api => ref.read(sessionControllerProvider).api;

  @override
  void dispose() {
    for (final c in [_ident, _otp, _password, _recovery]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await _api.postJson('/api/auth/reset/otp', {'ident': _ident.text});
      setState(() {
        _codeSent = true;
        _sentTo = res['devCode'] != null
            ? 'Test mode (no email set up): your code is ${res['devCode']}'
            : 'Code sent to ${res['email']} — check your inbox (and Spam).';
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmFresh() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reset without a recovery key?'),
          content: const Text('Your account gets a new encryption key. Messages from before can’t be opened any more — '
              'on any device. New messages work normally.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: VeyonColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset anyway'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _reset() async {
    if (_password.text.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _verified ??= await _api.postJson('/api/auth/reset/verify', {'ident': _ident.text, 'otp': _otp.text});
      final v = _verified!;
      final recovery = normalizeRecoveryKey(_recovery.text);
      final Map<String, dynamic> payload;
      if (recovery.isNotEmpty) {
        final wrapped = v['recoveryWrapped'];
        if (wrapped == null) throw ApiException(400, 'This account has no recovery key. Clear the box to reset without it.');
        final EcKeyPair pair;
        try {
          pair = await unwrapPrivateKey(WrappedPrivateKey.fromJson(Map<String, dynamic>.from(wrapped as Map)), recovery);
        } catch (_) {
          throw ApiException(400, 'That recovery key isn’t right — check it, or clear the box to reset without it.');
        }
        payload = {'encPrivateKey': (await wrapPrivateKey(pair, _password.text)).toJson(), 'newIdentity': false};
      } else {
        if (!await _confirmFresh()) {
          setState(() => _error = 'Enter your recovery key to keep your old messages.');
          return;
        }
        final pair = await generateIdentity();
        payload = {
          'encPrivateKey': (await wrapPrivateKey(pair, _password.text)).toJson(),
          'publicKey': (await exportPublicKey(pair)).toJson(),
          'newIdentity': true,
        };
      }
      await _api.postJson('/api/auth/reset/complete', {'resetToken': v['resetToken'], 'password': _password.text, ...payload});
      if (mounted) Navigator.of(context).pop((v['username'] as String, _password.text));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: [
          _hero(context, 'Reset your password', 'We’ll email a code to the Gmail on your account.'),
          const SizedBox(height: 22),
          if (_error != null) _errorBox(_error!),
          TextField(
            controller: _ident,
            enabled: !_codeSent,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Username, mobile or Gmail'),
          ),
          if (!_codeSent) ...[
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : _send,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: Text(_busy ? 'Sending…' : 'Send code'),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(_sentTo ?? '', style: const TextStyle(color: VeyonColors.online, fontSize: 12.5)),
            const SizedBox(height: 14),
            TextField(
              controller: _otp,
              enabled: _verified == null,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              style: const TextStyle(letterSpacing: 4),
              decoration: const InputDecoration(labelText: 'Code from your Gmail'),
            ),
            const SizedBox(height: 14),
            TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
            const SizedBox(height: 14),
            TextField(
              controller: _recovery,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Recovery key (keeps your old messages)', hintText: 'XXXXXX-XXXXXX-XXXXXX-XXXXXX'),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _reset,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: Text(_busy ? 'Resetting…' : 'Reset password'),
            ),
          ],
        ],
      ),
    );
  }
}
