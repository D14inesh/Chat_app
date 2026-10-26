/// Who's online right now, plus the freshest "last seen" time per person —
/// loaded from /api/presence whenever the connection (re)opens and kept up
/// to date by the server's live 'presence' events. Drives the green dots and
/// the "online" / "last seen …" line in the chat header, like the website.
library presence_provider;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';

class PresenceState {
  final Set<String> online;
  final Map<String, String> lastSeen; // userId → ISO time
  const PresenceState({this.online = const {}, this.lastSeen = const {}});
}

class PresenceController extends StateNotifier<PresenceState> {
  final Session _session;
  StreamSubscription<Map<String, dynamic>>? _sub;

  PresenceController(this._session) : super(const PresenceState()) {
    _sub = _session.ws?.frames.listen((f) {
      // A brand-new contact (request accepted) gets no presence events until
      // the next reconnect — ask the server who's online right away.
      if (f['type'] == 'connected' || f['type'] == 'request-accepted') _load();
      if (f['type'] == 'disconnected') state = PresenceState(lastSeen: state.lastSeen); // can't know anymore
      if (f['type'] == 'presence' && f['userId'] is String) {
        final id = f['userId'] as String;
        final online = {...state.online};
        f['online'] == true ? online.add(id) : online.remove(id);
        state = PresenceState(
          online: online,
          lastSeen: {...state.lastSeen, if (f['lastSeen'] is String) id: f['lastSeen'] as String},
        );
      }
    });
    if (_session.ws?.isConnected ?? false) _load();
  }

  /// Re-asks who's online (e.g. when a chat opens with someone new).
  Future<void> refresh() => _load();

  Future<void> _load() async {
    try {
      final ids = await _session.api.presence();
      state = PresenceState(online: ids.toSet(), lastSeen: state.lastSeen);
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final presenceProvider = StateNotifierProvider<PresenceController, PresenceState>((ref) {
  return PresenceController(ref.watch(sessionControllerProvider));
});

/// "last seen today at 14:05" / "last seen yesterday" / "last seen 3 Oct".
String lastSeenLabel(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return 'offline';
  final now = DateTime.now();
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return 'last seen just now';
  if (diff.inMinutes < 60) return 'last seen ${diff.inMinutes} min ago';
  final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return 'last seen today at $hm';
  if (day == today.subtract(const Duration(days: 1))) return 'last seen yesterday at $hm';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return 'last seen ${d.day} ${months[d.month - 1]}';
}
