/// Loads the visible status feed (own + accepted contacts', server-filtered
/// to non-expired -- see status.py's `WHERE s.expires_at > now()`) and
/// groups it by poster for the tray UI. Refetched on demand (no WS push for
/// status, matching the web app -- see routes/status.py's docstring).
library status_provider;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/local_cache.dart';
import '../auth/session.dart';

/// Statuses I've already "Added to my status" — each one only once, tracked
/// on this phone (there's no server link between a status and its re-share),
/// the same rule as the website.
class ResharedStatuses {
  static Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/veyon_cache/reshared.json');

  static Future<Set<String>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return (jsonDecode(await f.readAsString()) as List<dynamic>).cast<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  static Future<void> remember(String statusId) async {
    final ids = (await load())..add(statusId);
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      final list = ids.toList();
      await f.writeAsString(jsonEncode(list.length > 200 ? list.sublist(list.length - 200) : list));
    } catch (_) {}
  }
}

class StatusGroup {
  final String posterId;
  final String posterName;
  final String posterColor;
  final String? posterPhotoUrl;
  final bool isMine;
  final List<Map<String, dynamic>> statuses; // oldest first
  const StatusGroup({
    required this.posterId,
    required this.posterName,
    required this.posterColor,
    required this.posterPhotoUrl,
    required this.isMine,
    required this.statuses,
  });

  bool get allViewed => statuses.every((s) => s['viewed'] == true);
}

class StatusController extends StateNotifier<AsyncValue<List<StatusGroup>>> {
  final Session _session;
  final LocalCache _cache;
  StatusController(this._session, {LocalCache? cache})
      : _cache = cache ?? LocalCache(),
        super(const AsyncValue.loading()) {
    _loadFromCacheThenNetwork();
  }

  List<StatusGroup> _group(List<dynamic> raw) {
    final byPoster = <String, List<Map<String, dynamic>>>{};
    for (final r in raw) {
      final row = r as Map<String, dynamic>;
      byPoster.putIfAbsent(row['posterId'] as String, () => []).add(row);
    }
    return byPoster.entries.map((e) {
      final rows = e.value..sort((a, b) => (a['createdAt'] as String).compareTo(b['createdAt'] as String));
      final first = rows.first;
      return StatusGroup(
        posterId: e.key,
        posterName: first['posterName'] as String,
        posterColor: first['posterColor'] as String,
        posterPhotoUrl: first['posterPhotoUrl'] as String?,
        isMine: first['isMine'] as bool? ?? false,
        statuses: rows,
      );
    }).toList()
      ..sort((a, b) {
        if (a.isMine != b.isMine) return a.isMine ? -1 : 1;
        if (a.allViewed != b.allViewed) return a.allViewed ? 1 : -1;
        return 0;
      });
  }

  Future<void> _loadFromCacheThenNetwork() async {
    // Same offline-first pattern as ConversationsController: show whatever
    // was last synced immediately, no network wait, no blank tray.
    final cached = await _cache.loadStatuses();
    if (cached.isNotEmpty) {
      try {
        state = AsyncValue.data(_group(cached));
      } catch (_) {
        // Cache format mismatch -- fall through to a normal network load.
      }
    }
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final raw = await _session.api.listStatuses();
      state = AsyncValue.data(_group(raw));
      await _cache.saveStatuses(raw.cast<Map<String, dynamic>>());
    } catch (e, st) {
      // No network -- leave cached data on screen exactly as-is rather than
      // replacing it with an error/empty tray. Only surface the error if
      // there was truly nothing to show yet.
      if (state is! AsyncData || (state as AsyncData<List<StatusGroup>>).value.isEmpty) {
        state = AsyncValue.error(e, st);
      }
    }
  }
}

final statusProvider = StateNotifierProvider<StatusController, AsyncValue<List<StatusGroup>>>((ref) {
  final session = ref.watch(sessionControllerProvider);
  return StatusController(session);
});
