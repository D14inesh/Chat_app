/// Sign-in approval, same as the website: a sign-in from a phone the
/// account hasn't used before waits until the owner accepts it — from the
/// email to their Gmail, or from a device they're already signed in on.
/// Server side: backend/app/utils/login_approval.py.
library login_approval;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/app_visibility.dart';
import '../../core/local_notifications.dart';
import '../../core/nav_key.dart';
import '../../theme.dart';
import 'session.dart';

/// On the new phone: "Check your Gmail" until accepted. Returns the normal
/// login result; throws [ApiException] if rejected, expired or cancelled.
Future<Map<String, dynamic>> waitForLoginApproval(BuildContext context, ApiClient api, Map<String, dynamic> pending) async {
  final result = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WaitDialog(api: api, pending: pending),
  );
  if (result is Map<String, dynamic>) return result;
  if (result is ApiException) throw result;
  throw ApiException(0, 'Sign-in cancelled.');
}

class _WaitDialog extends StatefulWidget {
  final ApiClient api;
  final Map<String, dynamic> pending;
  const _WaitDialog({required this.api, required this.pending});
  @override
  State<_WaitDialog> createState() => _WaitDialogState();
}

class _WaitDialogState extends State<_WaitDialog> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final res = await widget.api.postJson('/api/auth/login/pending', {'approvalId': widget.pending['approvalId']});
      if (res['pending'] == true || !mounted) return;
      _timer?.cancel();
      Navigator.pop(context, res);
    } on ApiException catch (e) {
      _timer?.cancel();
      if (mounted) Navigator.pop(context, e);
    } catch (_) {
      // Offline for a moment — keep waiting.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending;
    return AlertDialog(
      icon: Icon(Icons.mark_email_unread_outlined, color: Theme.of(context).colorScheme.primary, size: 32),
      title: const Text('Check your Gmail'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          'This phone is new for this account, so we sent a sign-in request to ${p['email'] ?? 'your Gmail'}. '
          'Tap Accept in that email — or on a device you’re already signed in on — and the app continues by itself.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: VeyonColors.muted, height: 1.4),
        ),
        const SizedBox(height: 18),
        const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4)),
          SizedBox(width: 10),
          Text('Waiting for approval…'),
        ]),
        if (p['emailed'] != true && p['devApproveUrl'] == null)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: Text('Email isn’t set up on this server — accept it from a device you’re already signed in on.',
                textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted, fontSize: 12.5)),
          ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}

/// Mounted at the app root: when someone tries to sign in to this account
/// on a new device, ask right here — accept or reject.
class LoginApprovalListener extends ConsumerStatefulWidget {
  const LoginApprovalListener({super.key});
  @override
  ConsumerState<LoginApprovalListener> createState() => _LoginApprovalListenerState();
}

class _LoginApprovalListenerState extends ConsumerState<LoginApprovalListener> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  final _asked = <String>{}; // one question per request

  void _listen() {
    _sub?.cancel();
    _sub = ref.read(sessionControllerProvider).ws?.frames.listen((f) {
      if (f['type'] == 'login-approval') {
        final a = Map<String, dynamic>.from(f['approval'] as Map);
        // App in the background: a phone notification brings the person here.
        if (!AppVisibility.inForeground.value) {
          LocalNotifications.showLoginApproval(id: '${a['id']}', device: '${a['device'] ?? 'a new device'}');
        }
        _ask(a);
      }
      if (f['type'] == 'connected') _checkPending();
    });
    _checkPending();
  }

  /// Requests that came while this phone was closed or offline.
  Future<void> _checkPending() async {
    final session = ref.read(sessionControllerProvider);
    if (session.user == null) return;
    try {
      final res = await session.api.getJson('/api/auth/login-approvals');
      for (final a in (res['approvals'] as List<dynamic>? ?? const [])) {
        await _ask(Map<String, dynamic>.from(a as Map));
      }
    } catch (_) {/* offline — asked again on reconnect */}
  }

  void _onVisibility() {
    if (AppVisibility.inForeground.value) _checkPending();
  }

  Future<void> _ask(Map<String, dynamic> a) async {
    final id = '${a['id']}';
    if (!_asked.add(id)) return;
    final ctx = veyonNavigatorKey.currentContext;
    if (ctx == null) {
      _asked.remove(id);
      return;
    }
    final where = '${a['device'] ?? 'a new device'}${a['ip'] != null ? ' (${a['ip']})' : ''}';
    final action = await showDialog<String>(
      context: ctx,
      builder: (d) => AlertDialog(
        icon: Icon(Icons.shield_outlined, color: Theme.of(d).colorScheme.primary, size: 30),
        title: const Text('Is this you signing in?'),
        content: Text('Someone is trying to sign in to your account on $where.',
            textAlign: TextAlign.center, style: const TextStyle(color: VeyonColors.muted, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, 'reject'),
            style: TextButton.styleFrom(foregroundColor: VeyonColors.danger),
            child: const Text('No — reject'),
          ),
          FilledButton(onPressed: () => Navigator.pop(d, 'approve'), child: const Text('Yes, it’s me')),
        ],
      ),
    );
    LocalNotifications.clearLoginApproval(id);
    if (action == null) return;
    String note;
    try {
      await ref.read(sessionControllerProvider).api.postJson('/api/auth/login-approval/${a['id']}', {'action': action});
      note = action == 'approve' ? 'Sign-in accepted.' : 'Sign-in rejected. If it wasn’t you, change your password.';
    } on ApiException catch (e) {
      note = e.message;
    } catch (_) {
      note = 'Could not reach the server — try again.';
    }
    final now = veyonNavigatorKey.currentContext;
    if (now != null && now.mounted) ScaffoldMessenger.maybeOf(now)?.showSnackBar(SnackBar(content: Text(note)));
  }

  @override
  void initState() {
    super.initState();
    _listen();
    AppVisibility.inForeground.addListener(_onVisibility);
  }

  @override
  void dispose() {
    AppVisibility.inForeground.removeListener(_onVisibility);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionControllerProvider.select((s) => s.ws), (_, __) => _listen());
    return const SizedBox.shrink();
  }
}
