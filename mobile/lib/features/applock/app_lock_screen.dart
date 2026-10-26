import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/app_lock_store.dart';
import '../../theme.dart';
import 'pattern_pad.dart';

/// Shown at startup whenever an app-lock method is configured, gating the
/// rest of the UI behind it -- mirrors app.js's gateAppLock(), which the web
/// app calls unconditionally at boot before letting the chat UI render.
class AppLockScreen extends StatefulWidget {
  final AppLockMethod method;
  final VoidCallback onUnlocked;
  const AppLockScreen({super.key, required this.method, required this.onUnlocked});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _store = AppLockStore();
  final _pinCtrl = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (widget.method == AppLockMethod.biometric) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    setState(() => _checking = true);
    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: 'Unlock Veyon Chat',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
      if (ok) {
        widget.onUnlocked();
        return;
      }
      setState(() => _error = 'Authentication cancelled.');
    } catch (e) {
      setState(() => _error = 'Biometric unlock unavailable. $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _submitPattern(List<int> dots) async {
    if (await _store.verifyPattern(dots)) {
      widget.onUnlocked();
      return;
    }
    if (mounted) setState(() => _error = 'Wrong pattern.');
  }

  /// "Forgot? Reset app lock" — removes the lock on this phone only. Same as
  /// the website: messages were never protected by this screen anyway.
  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset app lock?'),
        content: const Text(
          'This removes the PIN/pattern/biometric requirement on this device. It doesn\'t affect your messages — '
          'those were never protected by this screen in the first place, only your device\'s own storage was.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    await _store.disable();
    widget.onUnlocked();
  }

  Future<void> _submitPin() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final ok = await _store.verifyPin(_pinCtrl.text);
    if (ok) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      _checking = false;
      _error = 'Wrong PIN.';
      _pinCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VeyonColors.bgDark,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_rounded, color: Colors.white70, size: 44),
                const SizedBox(height: 18),
                const Text('Veyon Chat is locked', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 20),
                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: VeyonColors.danger)),
                  const SizedBox(height: 14),
                ],
                if (widget.method == AppLockMethod.pin) ...[
                  TextField(
                    controller: _pinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 22, letterSpacing: 6),
                    decoration: const InputDecoration(labelText: 'PIN'),
                    onSubmitted: (_) => _submitPin(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _checking ? null : _submitPin,
                      child: const Text('Unlock'),
                    ),
                  ),
                ] else if (widget.method == AppLockMethod.pattern) ...[
                  const Text('Draw your pattern', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12),
                  PatternPad(onComplete: _submitPattern),
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _checking ? null : _tryBiometric,
                      icon: const Icon(Icons.fingerprint_rounded),
                      label: const Text('Try again'),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                TextButton(onPressed: _reset, child: const Text('Forgot? Reset app lock')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
