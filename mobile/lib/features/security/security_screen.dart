/// Security & logins — recent sign-ins to the account, "Log out all other
/// devices", and the banner that pops up on this phone whenever the account
/// signs in somewhere else (same as the website).
library security_screen;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav_key.dart';
import '../../theme.dart';
import '../account/recovery.dart';
import '../auth/contact_fields.dart';
import '../auth/session.dart';
import '../link/qr_scan_link_screen.dart';
import '../chat/chat3_tools.dart';

const _methodLabel = {'password': 'Password', 'qr': 'QR code (linked device)', 'register': 'New account'};

String _when(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${two(d.minute)} ${d.hour < 12 ? 'am' : 'pm'}';
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today $time';
  final y = now.subtract(const Duration(days: 1));
  if (d.year == y.year && d.month == y.month && d.day == y.day) return 'Yesterday $time';
  return '${d.day}/${d.month}/${d.year} $time';
}

IconData _deviceIcon(String device) =>
    RegExp('Android|iPhone|app', caseSensitive: false).hasMatch(device) ? Icons.smartphone_rounded : Icons.computer_rounded;

class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});
  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  List<Map<String, dynamic>>? _logins;
  String? _error;
  bool _signingOut = false;
  bool _done = false;
  bool _releasing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(sessionControllerProvider).api.recentLogins();
      if (mounted) setState(() => _logins = rows.cast<Map<String, dynamic>>());
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load your logins — check your connection.');
    }
  }

  Future<void> _logoutOthers() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out all other devices?'),
        content: const Text('Every other device signed in to your account is signed out. They’ll need your password (or a QR link) to sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VeyonColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out others'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _signingOut = true);
    try {
      await ref.read(sessionControllerProvider).api.logoutOthers();
      // This phone's own connection was closed too; it reconnects with the
      // fresh session it was just given.
      ref.read(sessionControllerProvider).ws?.reconnectNow();
      if (mounted) {
        setState(() => _done = true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All other devices are signed out.')));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not do that — check your connection.')));
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Future<void> _releaseDevice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Release this phone?'),
        content: const Text('You’ll be signed out, and another account will be able to sign in on this phone. You can still sign back in as yourself.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VeyonColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Release & sign out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _releasing = true);
    final navigator = Navigator.of(context);
    try {
      await ref.read(sessionControllerProvider.notifier).logout(releaseDevice: true);
      navigator.popUntil((r) => r.isFirst);
    } catch (_) {
      if (mounted) {
        setState(() => _releasing = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not release — you need a connection for this.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      appBar: AppBar(title: const Text('Security & logins')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Center(
              child: CircleAvatar(
                radius: 30,
                backgroundColor: accent.withValues(alpha: 0.16),
                child: Icon(Icons.verified_user_rounded, color: accent, size: 30),
              ),
            ),
            const SizedBox(height: 10),
            const Text('Every sign-in to your account. You get an alert on your other devices each time.',
                textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
            const SizedBox(height: 16),
            Builder(builder: (context) {
              final me = ref.watch(sessionControllerProvider).user;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(backgroundColor: VeyonColors.hairline, child: Icon(Icons.alternate_email_rounded, color: accent, size: 20)),
                  title: Text(me?.phone ?? 'No mobile number yet'),
                  subtitle: Text(
                    '${me?.email ?? 'No Gmail yet'}${me?.contactVerified == true ? ' · Verified' : ''}',
                    style: const TextStyle(color: VeyonColors.muted),
                  ),
                  trailing: TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VerifyContactScreen())),
                    child: const Text('Change'),
                  ),
                ),
              );
            }),
            Builder(builder: (context) {
              final has = ref.watch(sessionControllerProvider).user?.hasRecoveryKey ?? false;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(backgroundColor: VeyonColors.hairline, child: Icon(Icons.key_rounded, color: accent, size: 20)),
                  title: const Text('Recovery key'),
                  subtitle: Text(
                    has ? 'Saved · reset your password without losing messages' : 'Not set · a forgotten password would lose old messages',
                    style: TextStyle(color: has ? VeyonColors.muted : const Color(0xFFF5A524)),
                  ),
                  trailing: TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecoveryKeyScreen())),
                    child: Text(has ? 'New key' : 'Create'),
                  ),
                ),
              );
            }),
            Card(
              child: ListTile(
                leading: CircleAvatar(backgroundColor: VeyonColors.hairline, child: Icon(Icons.lock_rounded, color: accent, size: 20)),
                title: const Text('Chat lock'),
                subtitle: const Text('Hide chats behind a PIN — lock one from its ⋮ menu', style: TextStyle(color: VeyonColors.muted)),
                trailing: TextButton(onPressed: () => openChatLockSettings(context, ref), child: const Text('Settings')),
              ),
            ),
            const SizedBox(height: 10),
            if (_error != null) Text(_error!, textAlign: TextAlign.center),
            if (_logins == null && _error == null) const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator())),
            if (_logins != null)
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < _logins!.length; i++)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: VeyonColors.hairline,
                          child: Icon(_deviceIcon(_logins![i]['device'] as String), color: accent, size: 20),
                        ),
                        title: Row(children: [
                          Flexible(child: Text(_logins![i]['device'] as String, overflow: TextOverflow.ellipsis)),
                          if (i == 0)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                              decoration: BoxDecoration(color: VeyonColors.online.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99)),
                              child: const Text('Latest', style: TextStyle(color: VeyonColors.online, fontSize: 10.5, fontWeight: FontWeight.w800)),
                            ),
                        ]),
                        subtitle: Text(
                          '${_methodLabel[_logins![i]['method']] ?? _logins![i]['method']}${_logins![i]['ip'] != null ? ' · ${_logins![i]['ip']}' : ''}',
                          style: const TextStyle(color: VeyonColors.muted),
                        ),
                        trailing: Text(_when(_logins![i]['createdAt'] as String), style: const TextStyle(color: VeyonColors.muted, fontSize: 12)),
                      ),
                    if (_logins!.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No sign-ins recorded yet.')),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: VeyonColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VeyonColors.danger.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Don’t recognise a login?', style: TextStyle(color: Color(0xFFFFC2C2), fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  const Text('Sign out every device except this one, straight away.', style: TextStyle(color: VeyonColors.muted)),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: VeyonColors.danger),
                      onPressed: _signingOut || _done ? null : _logoutOthers,
                      child: Text(_done ? 'Done — others signed out' : _signingOut ? 'Signing out…' : 'Log out all other devices'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VeyonColors.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.phonelink_lock_rounded, color: accent, size: 18),
                    const SizedBox(width: 6),
                    const Expanded(child: Text('This phone is locked to your account', style: TextStyle(fontWeight: FontWeight.w800))),
                  ]),
                  const SizedBox(height: 4),
                  const Text('Only one account can be used on a phone. Giving it to someone else? Release it — you’ll be signed out and another account can sign in here.',
                      style: TextStyle(color: VeyonColors.muted)),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: VeyonColors.danger, side: BorderSide(color: VeyonColors.danger.withValues(alpha: 0.6))),
                      onPressed: _releasing ? null : _releaseDevice,
                      child: Text(_releasing ? 'Releasing…' : 'Release this phone'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrScanLinkScreen())),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Link a device'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mounted at the app root: a banner slides in when the account signs in
/// on another device.
class LoginAlertOverlay extends ConsumerStatefulWidget {
  const LoginAlertOverlay({super.key});
  @override
  ConsumerState<LoginAlertOverlay> createState() => _LoginAlertOverlayState();
}

class _LoginAlertOverlayState extends ConsumerState<LoginAlertOverlay> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic>? _login;
  Timer? _hide;

  void _listen() {
    _sub?.cancel();
    _sub = ref.read(sessionControllerProvider).ws?.frames.listen((f) {
      if (f['type'] != 'login-alert' || !mounted) return;
      setState(() => _login = Map<String, dynamic>.from(f['login'] as Map));
      _hide?.cancel();
      _hide = Timer(const Duration(seconds: 15), () {
        if (mounted) setState(() => _login = null);
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionControllerProvider.select((s) => s.ws), (_, __) => _listen());
    final login = _login;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      top: login == null ? -160 : 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: login == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.all(10),
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  elevation: 10,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: VeyonColors.danger.withValues(alpha: 0.45)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(color: VeyonColors.danger.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                          child: const Icon(Icons.shield_outlined, color: VeyonColors.danger, size: 21),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('New login to your account', style: TextStyle(fontWeight: FontWeight.w800)),
                              Text('${login['device']} · ${_when(login['createdAt'] as String)}',
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: VeyonColors.muted, fontSize: 12.5)),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() => _login = null);
                            veyonNavigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const SecurityScreen()));
                          },
                          child: const Text('Review'),
                        ),
                        IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(() => _login = null)),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
