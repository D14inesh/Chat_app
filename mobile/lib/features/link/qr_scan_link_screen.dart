import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/crypto/jwk.dart';
import '../../core/crypto/keys.dart';
import '../../theme.dart';
import '../auth/session.dart';

/// The ALREADY-signed-in device's half of QR linking -- scans the code shown
/// by qr_login_screen.dart on a new/signed-out device, claims it to get that
/// device's ephemeral public key, then seals a copy of this device's own
/// identity private key for it. Mirrors app.js's scanner flow
/// (app.js:391-484) and server-py/routes/link.py's /claim + /complete.
class QrScanLinkScreen extends ConsumerStatefulWidget {
  const QrScanLinkScreen({super.key});

  @override
  ConsumerState<QrScanLinkScreen> createState() => _QrScanLinkScreenState();
}

class _QrScanLinkScreenState extends ConsumerState<QrScanLinkScreen> {
  final MobileScannerController _scanner = MobileScannerController();
  bool _busy = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _restartCamera() async {
    try {
      await _scanner.stop();
      await _scanner.start();
    } catch (_) {
      // The error builder below shows whatever went wrong.
    }
  }

  /// Shows the real camera error instead of the plugin's generic "An
  /// unexpected error occurred", so a failure on a given phone is diagnosable.
  Widget _cameraError(BuildContext context, MobileScannerException error, Widget? child) {
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'Camera permission is off. Allow it in Settings > Apps > veyon_chat_mobile > Permissions.',
      MobileScannerErrorCode.unsupported => 'This device has no usable camera for scanning.',
      _ => 'Camera could not start (${error.errorCode.name})'
          '${error.errorDetails?.message != null ? ':\n${error.errorDetails!.message}' : ''}',
    };
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, color: Colors.white, size: 40),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _restartCamera, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    final raw = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (raw == null || !raw.startsWith('vesper:link:')) return;
    await _link(raw.substring('vesper:link:'.length));
  }

  /// The website's fallback: type the code shown under the other device's QR.
  Future<void> _enterCode() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter the code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'Code shown on the other device'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toUpperCase()), child: const Text('Link')),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) await _link(code);
  }

  Future<void> _link(String code) async {
    if (_busy || _success != null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final session = ref.read(sessionControllerProvider);
      final claim = await session.api.linkClaim(code);
      final ephemeralJwk = EcPublicJwk.fromJson(claim['ephemeralPublicKey'] as Map<String, dynamic>);
      final sealed = await sealIdentityForLink(session.identityKeyPair!, ephemeralJwk);
      await session.api.linkComplete(code: code, wrappedKey: sealed.wrappedKey, wrappedIv: sealed.wrappedIv);
      setState(() => _success = 'Device linked! It will sign in automatically.');
    } catch (e) {
      setState(() => _error = 'Could not link that device: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Linked devices')),
      body: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.smartphone_rounded),
            title: Text('This device'),
            subtitle: Text('Signed in here'),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'To link another device: open Veyon Chat there, choose "Link this device", and scan its QR code here. '
              'Linking copies your encryption key straight to the other device — the server never sees it. '
              'Only link devices you own and trust.',
              style: TextStyle(color: Colors.white60, fontSize: 12.5),
            ),
          ),
          Expanded(child: _scannerArea()),
          SafeArea(
            top: false,
            child: TextButton.icon(
              onPressed: _busy || _success != null ? null : _enterCode,
              icon: const Icon(Icons.keyboard_rounded),
              label: const Text('Type the code instead'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scannerArea() {
    return Stack(
        children: [
          if (_success == null)
            MobileScanner(controller: _scanner, onDetect: _onDetect, errorBuilder: _cameraError),
          if (_success != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded, color: Colors.green, size: 48),
                    const SizedBox(height: 12),
                    Text(_success!, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          if (_error != null)
            Positioned(
              bottom: 24,
              left: 24,
              right: 24,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
                child: Text(_error!, style: const TextStyle(color: VeyonColors.danger), textAlign: TextAlign.center),
              ),
            ),
          if (_busy) const Center(child: CircularProgressIndicator()),
        ],
    );
  }
}
