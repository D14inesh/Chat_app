import '../../theme.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/app_lock_store.dart';
import 'pattern_pad.dart';

class AppLockSetupScreen extends StatefulWidget {
  const AppLockSetupScreen({super.key});

  @override
  State<AppLockSetupScreen> createState() => _AppLockSetupScreenState();
}

class _AppLockSetupScreenState extends State<AppLockSetupScreen> {
  final _store = AppLockStore();
  AppLockMethod _method = AppLockMethod.none;
  bool _biometricAvailable = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final method = await _store.getMethod();
    bool available = false;
    try {
      final auth = LocalAuthentication();
      available = await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {
      available = false;
    }
    if (mounted) setState(() { _method = method; _biometricAvailable = available; _loading = false; });
  }

  Future<void> _setPin() async {
    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set a PIN'),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '4+ digit PIN'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (pin == null || pin.length < 4) return;
    await _store.setPin(pin);
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN lock enabled.')));
  }

  /// Draw a pattern (4+ dots), then draw it again to confirm — the website's flow.
  Future<void> _setPattern() async {
    List<int>? first;
    String hint = 'Draw a pattern connecting at least 4 dots.';
    final saved = await showDialog<List<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Set a pattern'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(hint, textAlign: TextAlign.center, style: const TextStyle(color: VeyonColors.muted)),
              const SizedBox(height: 12),
              PatternPad(
                size: 220,
                onComplete: (seq) {
                  if (seq.length < 4) {
                    setDlg(() => hint = 'Connect at least 4 dots.');
                  } else if (first == null) {
                    first = seq;
                    setDlg(() => hint = 'Draw it again to confirm.');
                  } else if (first!.join(',') != seq.join(',')) {
                    first = null;
                    setDlg(() => hint = "Patterns didn't match — try again.");
                  } else {
                    Navigator.pop(ctx, seq);
                  }
                },
              ),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        ),
      ),
    );
    if (saved == null) return;
    await _store.setPattern(saved);
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App lock enabled.')));
  }

  Future<void> _enableBiometric() async {
    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: 'Confirm to enable biometric lock',
        options: const AuthenticationOptions(biometricOnly: false),
      );
      if (!ok) return;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not verify: $e')));
      return;
    }
    await _store.enableBiometric();
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Biometric lock enabled.')));
  }

  Future<void> _disable() async {
    await _store.disable();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(appBar: AppBar(title: const Text('App lock')), body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('App lock')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "A local privacy screen for this device only -- it doesn't add real "
              'security since your chats are already unlocked on this phone; it just '
              'keeps a casual glance from reading them.',
              style: TextStyle(color: VeyonColors.muted, fontSize: 12.5),
            ),
          ),
          RadioListTile<AppLockMethod>(
            title: const Text('Off'),
            value: AppLockMethod.none,
            groupValue: _method,
            onChanged: (_) => _disable(),
          ),
          RadioListTile<AppLockMethod>(
            title: const Text('PIN'),
            value: AppLockMethod.pin,
            groupValue: _method,
            onChanged: (_) => _setPin(),
          ),
          RadioListTile<AppLockMethod>(
            title: const Text('Pattern'),
            value: AppLockMethod.pattern,
            groupValue: _method,
            onChanged: (_) => _setPattern(),
          ),
          RadioListTile<AppLockMethod>(
            title: const Text('Biometric (fingerprint / face)'),
            subtitle: _biometricAvailable ? null : const Text('Not available on this device', style: TextStyle(color: VeyonColors.muted)),
            value: AppLockMethod.biometric,
            groupValue: _method,
            onChanged: _biometricAvailable ? (_) => _enableBiometric() : null,
          ),
        ],
      ),
    );
  }
}
