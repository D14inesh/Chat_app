import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_cache.dart';
import '../../core/prefs_store.dart';
import '../../models/conversation.dart';
import '../auth/session.dart';

class ConversationsController extends StateNotifier<AsyncValue<List<Conversation>>> {
  final Session _session;
  final LocalCache _cache;
  StreamSubscription<Map<String, dynamic>>? _wsSub;

  ConversationsController(this._session, {LocalCache? cache})
      : _cache = cache ?? LocalCache(),
        super(const AsyncValue.loading()) {
    _loadFromCacheThenNetwork();
    // Simplest-correct MVP approach: any of these frame types can change
    // what the list should show (new message + preview, unread count,
    // accept/decline flipping a pending request) — just refetch rather
    // than hand-maintaining incremental state for every case up front.
    _wsSub = _session.ws?.frames.listen((frame) {
      // 'connected' = back online after being offline: catch up.
      const relevant = {
        'connected', 'message', 'receipts', 'read-cleared', 'request-accepted', 'request-declined',
        'message-deleted', 'message-edited',
        // Groups: settings, members, joins, leaves, communities.
        'group-updated', 'members-changed', 'group-joined', 'group-left', 'join-request', 'communities-changed',
      };
      if (relevant.contains(frame['type'])) _fetchFromNetwork();
    });
  }

  Future<void> _loadFromCacheThenNetwork() async {
    // Show whatever's already on-device immediately — no spinner if we have
    // something to show, matching how every chat app opens instantly to
    // your last-known chat list before it finishes syncing.
    final cached = await _cache.loadConversations();
    if (cached.isNotEmpty) {
      try {
        state = AsyncValue.data(cached.map((j) => Conversation.fromJson(j)).toList());
      } catch (_) {
        // Cache format mismatch (e.g. after an app update) — ignore it and
        // fall through to a normal network load below.
      }
    }
    await _fetchFromNetwork();
  }

  Future<void> _fetchFromNetwork() async {
    try {
      final raw = await _session.api.listConversations();
      final list = raw.map((j) => Conversation.fromJson(j as Map<String, dynamic>)).toList();
      state = AsyncValue.data(list);
      await _cache.saveConversations(raw.cast<Map<String, dynamic>>());
    } catch (e, st) {
      // No network (or the server is down) — if we already have cached
      // data on screen, leave it exactly as-is rather than replacing a
      // useful chat list with an error page. Only surface the error if
      // there was truly nothing to show yet.
      if (state is! AsyncData || (state as AsyncData<List<Conversation>>).value.isEmpty) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  Future<void> refresh() => _fetchFromNetwork();

  Conversation? byId(String id) => state.valueOrNull?.where((c) => c.id == id).firstOrNull;

  void _patch(String id, Conversation Function(Conversation) change) {
    final list = state.valueOrNull;
    if (list == null) return;
    state = AsyncValue.data([for (final c in list) c.id == id ? change(c) : c]);
  }

  /// Optimistic, reverted if the server refuses — same as the website.
  Future<void> setFavorite(String id, bool favorite) async {
    _patch(id, (c) => c.copyWith(favorite: favorite));
    try {
      await _session.api.setFavorite(id, favorite);
    } catch (_) {
      _patch(id, (c) => c.copyWith(favorite: !favorite));
      rethrow;
    }
  }

  /// [hours]: mute for that long (8 hours, 1 week); null = always.
  Future<void> setMuted(String id, bool muted, {double? hours}) async {
    final before = byId(id);
    _patch(id, (c) => c.copyWith(muted: muted, clearMutedUntil: true));
    try {
      final res = await _session.api.setMuted(id, muted, hours: hours);
      _patch(id, (c) => c.copyWith(mutedUntil: res['mutedUntil'] as String?, clearMutedUntil: res['mutedUntil'] == null));
    } catch (_) {
      if (before != null) _patch(id, (_) => before);
      rethrow;
    }
  }

  /// Pin to the top of the chat list (the server allows up to 3).
  Future<void> setPinned(String id, bool pinned) async {
    final before = byId(id);
    _patch(id, (c) => pinned ? c.copyWith(pinnedAt: DateTime.now().toUtc().toIso8601String()) : c.copyWith(clearPinnedAt: true));
    try {
      final at = await _session.api.setPinned(id, pinned);
      _patch(id, (c) => at == null ? c.copyWith(clearPinnedAt: true) : c.copyWith(pinnedAt: at));
    } catch (_) {
      if (before != null) _patch(id, (_) => before);
      rethrow;
    }
  }

  // ── Mark as unread (this phone only; cleared when the chat is opened) ──
  static Set<String> get markedUnread {
    final raw = PrefsStore.instance.get('markedUnread');
    return raw is List ? raw.map((e) => '$e').toSet() : <String>{};
  }

  static bool isMarkedUnread(String id) => markedUnread.contains(id);

  void markUnread(Iterable<String> ids) {
    PrefsStore.instance.put('markedUnread', {...markedUnread, ...ids}.toList());
    state = AsyncValue.data([...?state.valueOrNull]); // repaint the dots
  }

  static void clearMarkedUnread(String id) {
    final marks = markedUnread;
    if (marks.remove(id)) PrefsStore.instance.put('markedUnread', marks.toList());
  }

  /// Marks chats read (the server clears unread + sends blue ticks).
  int markRead(Iterable<String> ids) {
    var n = 0;
    for (final id in ids) {
      if (isMarkedUnread(id)) {
        clearMarkedUnread(id);
        _patch(id, (c) => c); // repaint the dot away
        n++;
      }
      final c = byId(id);
      if (c == null || c.unread == 0) continue;
      _session.ws?.sendRead(conversationId: id);
      _patch(id, (c) => c.copyWith(unread: 0));
      n++;
    }
    return n;
  }

  /// Archive / unarchive (per person; stays archived when messages arrive).
  Future<void> setArchived(String id, bool archived) async {
    _patch(id, (c) => c.copyWith(archived: archived));
    try {
      await _session.api.patchJson('/api/conversations/$id/archive', {'archived': archived});
    } catch (_) {
      _patch(id, (c) => c.copyWith(archived: !archived));
      rethrow;
    }
  }

  /// Applies a change made from this phone (e.g. group settings) at once.
  void patch(String id, Conversation Function(Conversation) change) => _patch(id, change);

  /// Gone from my list (deleted chat, left group, declined request).
  void remove(String id) {
    final list = state.valueOrNull;
    if (list == null) return;
    state = AsyncValue.data(list.where((c) => c.id != id).toList());
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }
}

final conversationsProvider =
    StateNotifierProvider<ConversationsController, AsyncValue<List<Conversation>>>((ref) {
  final session = ref.watch(sessionControllerProvider);
  return ConversationsController(session);
});
