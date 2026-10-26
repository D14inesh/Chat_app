/// "Storage & data" — this phone is the storage for the chats. Shows what it
/// keeps by type (messages, voice notes, photos, videos, cache) and clears
/// each type on its own, or everything at once (the website's Storage panel).
/// Unsent (queued offline) messages and this account's login are never touched.
library storage_screen;

import '../../theme.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/auto_download.dart';
import '../../core/storage_clear.dart';
import '../../models/message.dart';
import '../conversations/conversations_provider.dart';

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  int? _bytes;
  Map<String, ({int count, int bytes})>? _parts;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<Directory> _cacheDir() async => Directory('${(await getApplicationSupportDirectory()).path}/veyon_cache');

  /// Every saved message's bucket, by message id (attachments are saved as `<id>.bin`).
  Future<Map<String, String>> _messageKinds(Directory dir, {Map<String, int>? sizes}) async {
    final kinds = <String, String>{};
    await for (final e in dir.list()) {
      if (e is! File || !e.uri.pathSegments.last.startsWith('messages_')) continue;
      try {
        for (final j in (jsonDecode(await e.readAsString()) as List<dynamic>).cast<Map<String, dynamic>>()) {
          final kind = messageCategory(ChatMessage.fromJson(j));
          kinds[j['id'] as String] = kind;
          if (sizes != null) sizes[kind] = (sizes[kind] ?? 0) + jsonEncode(j).length;
        }
      } catch (_) {}
    }
    return kinds;
  }

  Future<void> _measure() async {
    var total = 0;
    final counts = <String, int>{};
    final sizes = <String, int>{};
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final e in dir.list(recursive: true)) {
          if (e is File) total += await e.length();
        }
        final kinds = await _messageKinds(dir, sizes: sizes);
        for (final k in kinds.values) {
          counts[k] = (counts[k] ?? 0) + 1;
        }
        final files = Directory('${dir.path}/files');
        if (await files.exists()) {
          await for (final f in files.list()) {
            if (f is! File) continue;
            final id = f.uri.pathSegments.last.replaceAll('.bin', '');
            final kind = kinds[id] ?? 'cache';
            if (!kinds.containsKey(id)) counts[kind] = (counts[kind] ?? 0) + 1;
            sizes[kind] = (sizes[kind] ?? 0) + await f.length();
          }
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _bytes = total;
        _parts = {for (final (k, _) in storageKinds) k: (count: counts[k] ?? 0, bytes: sizes[k] ?? 0)};
      });
    }
  }

  Future<void> _clear(Set<String> kinds, String what) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete from this phone?'),
        content: Text('Delete all $what from this phone?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _clearing = true);
    markCleared(kinds);
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        final kindOf = await _messageKinds(dir);
        // Drop those messages from each chat's saved history…
        await for (final e in dir.list()) {
          if (e is! File || !e.uri.pathSegments.last.startsWith('messages_')) continue;
          try {
            final rows = (jsonDecode(await e.readAsString()) as List<dynamic>).cast<Map<String, dynamic>>();
            final keep = rows.where((j) => !kinds.contains(kindOf[j['id']])).toList();
            if (keep.length != rows.length) await e.writeAsString(jsonEncode(keep));
          } catch (_) {}
        }
        // …and their saved files.
        final files = Directory('${dir.path}/files');
        if (await files.exists()) {
          await for (final f in files.list()) {
            if (f is! File) continue;
            final id = f.uri.pathSegments.last.replaceAll('.bin', '');
            if (kinds.contains(kindOf[id] ?? 'cache')) await f.delete();
          }
        }
      }
    } catch (_) {}
    // The chat list drops previews of what was just cleared.
    ref.read(conversationsProvider.notifier).refresh();
    await _measure();
    if (mounted) {
      setState(() => _clearing = false);
      final label = '${what[0].toUpperCase()}${what.substring(1)}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label cleared from this phone.')));
    }
  }

  Future<void> _pickAutoDownload(String kind, String label) async {
    final current = autoDownloadSetting(kind);
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('$label: automatic download'),
        children: [
          for (final (value, text) in autoDownloadChoices)
            ListTile(
              title: Text(text),
              leading: Icon(value == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              onTap: () => Navigator.pop(ctx, value),
            ),
        ],
      ),
    );
    if (picked != null) setState(() => setAutoDownload(kind, picked));
  }

  String _fmt(int? b) {
    if (b == null) return '…';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Storage & data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This phone is the storage for your chats. Messages, voice notes, photos and videos you\'ve opened '
            'are saved here, so chats load instantly and work offline. Clearing them deletes them from this phone.',
            style: TextStyle(color: VeyonColors.muted),
          ),
          const SizedBox(height: 16),
          ListTile(title: const Text('On this phone'), trailing: Text(_fmt(_bytes))),
          const Divider(height: 1),
          for (final (kind, label) in storageKinds)
            ListTile(
              title: Text(label),
              subtitle: Text(_parts == null
                  ? '…'
                  : '${_parts![kind]!.count} ${_parts![kind]!.count == 1 ? 'item' : 'items'} · ${_fmt(_parts![kind]!.bytes)}'),
              trailing: OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: VeyonColors.danger),
                onPressed: _clearing ? null : () => _clear({kind}, label.toLowerCase()),
                child: const Text('Clear'),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VeyonColors.danger),
            onPressed: _clearing
                ? null
                : () => _clear({for (final (k, _) in storageKinds) k}, 'messages, voice notes, photos, videos and cache'),
            child: Text(_clearing ? 'Clearing…' : 'Clear all'),
          ),
          const SizedBox(height: 24),
          Text('Automatic download', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Choose what downloads on its own when you open a chat. Anything else shows “tap to download”.',
            style: TextStyle(color: VeyonColors.muted),
          ),
          for (final (kind, label, _) in autoDownloadKinds)
            ListTile(
              title: Text(label),
              subtitle: Text(autoDownloadChoices.firstWhere((c) => c.$1 == autoDownloadSetting(kind)).$2),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _pickAutoDownload(kind, label),
            ),
        ],
      ),
    );
  }
}
