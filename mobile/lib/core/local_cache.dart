/// Simple on-device cache so the app has something to show immediately on
/// launch and stays usable (read-only) with no network — the same
/// "open, see everything already synced, just can't send/fetch new stuff"
/// behavior every chat app (including the web version's own IndexedDB-based
/// caching) gives you. Deliberately plain JSON files rather than a SQL
/// database (drift/sqlite) — the data shape is just "list of conversation
/// objects" / "list of message objects per conversation", which doesn't
/// need relational queries, so a simpler mechanism is the right amount of
/// engineering for what this needs to do.
library local_cache;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalCache {
  Future<Directory> _cacheDir() async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${dir.path}/veyon_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return cacheDir;
  }

  Future<File> _conversationsFile() async {
    final dir = await _cacheDir();
    return File('${dir.path}/conversations.json');
  }

  Future<File> _messagesFile(String conversationId) async {
    final dir = await _cacheDir();
    // Conversation ids are UUIDs (safe as filenames) — no sanitization needed.
    return File('${dir.path}/messages_$conversationId.json');
  }

  Future<void> saveConversations(List<Map<String, dynamic>> conversations) async {
    try {
      final file = await _conversationsFile();
      await file.writeAsString(jsonEncode(conversations));
    } catch (_) {
      // Caching is a best-effort convenience — a write failure (e.g. full
      // disk) should never crash the app or block showing live data.
    }
  }

  Future<List<Map<String, dynamic>>> loadConversations() async {
    try {
      final file = await _conversationsFile();
      if (!await file.exists()) return [];
      final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
      return raw.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Messages are cached WITH their decrypted `plaintext` already attached,
  /// so viewing cached history offline never needs to touch the crypto
  /// layer or a peer's key again.
  Future<void> saveMessages(String conversationId, List<Map<String, dynamic>> messages) async {
    try {
      final file = await _messagesFile(conversationId);
      await file.writeAsString(jsonEncode(messages));
    } catch (_) {
      // Best-effort, same reasoning as saveConversations.
    }
  }

  Future<List<Map<String, dynamic>>> loadMessages(String conversationId) async {
    try {
      final file = await _messagesFile(conversationId);
      if (!await file.exists()) return [];
      final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
      return raw.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Search all chats: the messages saved on this phone whose text matches
  /// [query] (case-insensitive), newest first. The server can't search — it
  /// only ever has the encrypted copy.
  Future<List<({String conversationId, Map<String, dynamic> message})>> searchMessages(String query, {int limit = 60}) async {
    final q = query.trim().toLowerCase();
    if (q.length < 2) return const [];
    final hits = <({String conversationId, Map<String, dynamic> message})>[];
    try {
      final dir = await _cacheDir();
      await for (final e in dir.list()) {
        final name = e.uri.pathSegments.last;
        if (e is! File || !name.startsWith('messages_') || !name.endsWith('.json')) continue;
        final convoId = name.substring('messages_'.length, name.length - '.json'.length);
        try {
          for (final m in (jsonDecode(await e.readAsString()) as List<dynamic>).cast<Map<String, dynamic>>()) {
            final kind = m['kind'];
            if (kind != 'text' && kind != 'file') continue;
            final text = m['plaintext'];
            if (text is! String) continue;
            // Files: match the file name, not the JSON around it.
            final searchable = kind == 'file' ? (RegExp(r'"name"\s*:\s*"([^"]*)"').firstMatch(text)?.group(1) ?? '') : text;
            if (searchable.toLowerCase().contains(q)) hits.add((conversationId: convoId, message: m));
          }
        } catch (_) {}
      }
    } catch (_) {}
    hits.sort((a, b) => '${b.message['createdAt']}'.compareTo('${a.message['createdAt']}'));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  Future<File> _membersFile(String conversationId) async {
    final dir = await _cacheDir();
    return File('${dir.path}/members_$conversationId.json');
  }

  /// A group's member list — so sender names show in a group chat offline.
  Future<void> saveMembers(String conversationId, List<Map<String, dynamic>> members) async {
    try {
      await (await _membersFile(conversationId)).writeAsString(jsonEncode(members));
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> loadMembers(String conversationId) async {
    try {
      final file = await _membersFile(conversationId);
      if (!await file.exists()) return [];
      return (jsonDecode(await file.readAsString()) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<File> _groupKeysFile() async {
    final dir = await _cacheDir();
    return File('${dir.path}/group_keys.json');
  }

  /// A group's content key exactly as the server hands it out — still
  /// wrapped (encrypted to this user's identity key), plus the wrapper's
  /// public key needed to unwrap it — so a group chat can be opened and
  /// replied to offline.
  Future<void> saveGroupKey(String conversationId, Map<String, dynamic> wrapped) async {
    try {
      final all = await _readGroupKeys();
      all[conversationId] = wrapped;
      await (await _groupKeysFile()).writeAsString(jsonEncode(all));
    } catch (_) {
      // Best-effort, same reasoning as saveConversations.
    }
  }

  Future<Map<String, dynamic>?> loadGroupKey(String conversationId) async {
    final all = await _readGroupKeys();
    return all[conversationId] as Map<String, dynamic>?;
  }

  Future<Map<String, dynamic>> _readGroupKeys() async {
    try {
      final file = await _groupKeysFile();
      if (!await file.exists()) return {};
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Everything cached here belongs to the signed-in account — wiped on logout.
  Future<void> clearAll() async {
    try {
      final dir = await _cacheDir();
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json') && !entity.path.endsWith('outbox.json')) {
          await entity.delete();
        }
      }
    } catch (_) {
      // Nothing to clear / unreadable — fine.
    }
  }

  Future<File> _statusesFile() async {
    final dir = await _cacheDir();
    return File('${dir.path}/statuses.json');
  }

  /// The raw (still-encrypted) status list, cached the same way
  /// conversations are -- so the status tray shows the last-known statuses
  /// instead of just disappearing when the app opens with no network. A
  /// stale cached status might have since expired server-side; the viewer
  /// screen's own decrypt/view-marking calls simply fail gracefully offline
  /// the same way any other offline action does.
  Future<void> saveStatuses(List<Map<String, dynamic>> statuses) async {
    try {
      final file = await _statusesFile();
      await file.writeAsString(jsonEncode(statuses));
    } catch (_) {
      // Best-effort, same reasoning as saveConversations.
    }
  }

  Future<List<Map<String, dynamic>>> loadStatuses() async {
    try {
      final file = await _statusesFile();
      if (!await file.exists()) return [];
      final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
      return raw.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }
}
