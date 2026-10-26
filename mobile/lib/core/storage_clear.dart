/// What "Storage & data" clears, by type. This phone is the storage for the
/// chats: once a type is cleared here, every message of that type up to that
/// moment is gone from this phone and isn't shown again (same rule as the
/// website's localstore.js).
library storage_clear;

import '../models/message.dart';
import 'prefs_store.dart';

/// (bucket, label) in the order the Storage screen lists them.
const storageKinds = [
  ('messages', 'Messages'),
  ('voice', 'Voice notes'),
  ('photos', 'Photos'),
  ('videos', 'Videos'),
  ('cache', 'Cache'),
];

/// 'messages' | 'voice' | 'photos' | 'videos' | 'cache' (stickers, GIFs, documents).
String messageCategory(ChatMessage m) {
  if (m.kind == 'voice') return 'voice';
  if (m.kind != 'file') return 'messages';
  if (m.isSticker || m.isGif) return 'cache';
  final mime = (m.payload?['mime'] as String? ?? '').toLowerCase();
  if (mime.startsWith('image/')) return 'photos';
  if (mime.startsWith('video/')) return 'videos';
  return 'cache';
}

const _key = 'clearedBefore';

Map<String, dynamic> _cleared() {
  final raw = PrefsStore.instance.get(_key);
  return raw is Map ? Map<String, dynamic>.from(raw) : {};
}

void markCleared(Iterable<String> kinds) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final cur = _cleared();
  for (final k in kinds) {
    cur[k] = now;
  }
  PrefsStore.instance.put(_key, cur);
}

/// True when a message of [kind] created at [createdAt] was cleared from this phone.
bool isClearedAt(String kind, String createdAt) {
  final at = _cleared()[kind] as num?;
  final created = DateTime.tryParse(createdAt);
  return at != null && created != null && created.millisecondsSinceEpoch <= at;
}

bool isCleared(ChatMessage m) => isClearedAt(messageCategory(m), m.createdAt);
