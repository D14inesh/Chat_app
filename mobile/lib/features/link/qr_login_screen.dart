import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api_client.dart';
import '../../core/crypto/identity.dart';
import '../../core/crypto/jwk.dart';
import '../../core/crypto/keys.dart';
import '../../models/user.dart';
import '../../theme.dart';
import '../auth/session.dart';

/// The NEW/signed-out device's half of QR linking -- generates an ephemeral
/// ECDH keypair + a throwaway device secret, shows a QR code encoding the
/// resulting link code, then polls until an already-signed-in device scans
/// it and seals over the real identity key. Mirrors app.js's QR receiver
/// flow (app.js:301-388) and server-py/routes/link.py's /start + /poll.
class QrLoginScreen extends ConsumerStatefulWidget {
  const QrLoginScreen({super.key});

  @override
  ConsumerState<QrLoginScreen> createState() => _QrLoginScreenState();
}

class _QrLoginScreenState extends ConsumerState<QrLoginScreen> {
  String? _code;
  String? _error;
  Timer? _pollTimer;
  late final String _deviceSecret;
  late final EcKeyPair _ephemeralKeyPair;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  String _randomDeviceSecret() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes);
  }

  Future<void> _start() async {
    try {
      final api = await ref.read(apiClientProvider.future);
      _deviceSecret = _randomDeviceSecret();
      _ephemeralKeyPair = await generateIdentity();
      final pub = await exportPublicKey(_ephemeralKeyPair);
      final result = await api.linkStart(ephemeralPublicKey: pub.toJson(), deviceSecret: _deviceSecret);
      setState(() => _code = result['code'] as String);
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll(api));
    } catch (e) {
      setState(() => _error = 'Could not start device linking: $e');
    }
  }

  Future<void> _poll(ApiClient api) async {
    if (_code == null) return;
    try {
      final result = await api.linkPoll(code: _code!, deviceSecret: _deviceSecret);
      if (result['status'] != 'ready') return;
      _pollTimer?.cancel();
      final keyPair = await openIdentityFromLink(
        _ephemeralKeyPair,
        EcPublicJwk.fromJson(result['publicKey'] as Map<String, dynamic>),
        result['wrappedKey'] as String,
        result['wrappedIv'] as String,
      );
      final user = AppUser.fromJson(result['user'] as Map<String, dynamic>);
      await ref.read(sessionControllerProvider.notifier).loginWithLinkedIdentity(user, keyPair);
    } catch (_) {
      // 404/expired -- keep polling silently until the 180s window itself
      // elapses (mirrors app.js, which just lets the QR go stale).
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VeyonColors.bgDark,
      appBar: AppBar(title: const Text('Log in with QR'), backgroundColor: VeyonColors.bgDark),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Text(_error!, style: const TextStyle(color: VeyonColors.danger), textAlign: TextAlign.center)
              else if (_code == null)
                const CircularProgressIndicator()
              else ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.white,
                  child: QrImageView(data: 'vesper:link:$_code', size: 220),
                ),
                const SizedBox(height: 20),
                const Text('Scan this with Veyon Chat on a device where you\'re already signed in.',
                    textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
                const SizedBox(height: 8),
                Text(_code!, style: const TextStyle(color: VeyonColors.muted, letterSpacing: 2)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
