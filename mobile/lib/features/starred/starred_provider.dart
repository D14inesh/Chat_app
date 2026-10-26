/// Tracks which message ids the current user has starred, app-wide (not
/// per-conversation) -- mirrors app.js's loadStarredIds/toggleStarMessage.
/// Starring is private to the starrer and never fans out over the socket
/// (see server-py/routes/messages.py), so a plain fetch-once-then-optimistic-
/// update Set is all this needs.
library starred_provider;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';

class StarredController extends StateNotifier<Set<String>> {
  final Session _session;
  StarredController(this._session) : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _session.api.listStarredMessages();
      state = rows.map((r) => (r as Map<String, dynamic>)['id'] as String).toSet();
    } catch (_) {
      // Best-effort -- an empty starred set just means the star icons start
      // unfilled until the next successful load, never a hard error.
    }
  }

  Future<void> toggle(String messageId) async {
    final starred = state.contains(messageId);
    // Optimistic -- flip locally first, matching every other write in this
    // app's UI (sendText's optimistic bubble, wallpaper picker, etc.).
    state = starred ? ({...state}..remove(messageId)) : ({...state}..add(messageId));
    try {
      if (starred) {
        await _session.api.unstarMessage(messageId);
      } else {
        await _session.api.starMessage(messageId);
      }
    } catch (_) {
      // Revert on failure (e.g. offline) so the icon doesn't lie about state.
      state = starred ? ({...state}..add(messageId)) : ({...state}..remove(messageId));
    }
  }

  Future<void> refresh() => _load();
}

final starredProvider = StateNotifierProvider<StarredController, Set<String>>((ref) {
  final session = ref.watch(sessionControllerProvider);
  return StarredController(session);
});
