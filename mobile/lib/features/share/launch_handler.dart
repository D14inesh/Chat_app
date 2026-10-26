/// "Share into Veyon" (from the gallery or any app) and the home-screen
/// widget. Android hands shared text/files (copied into the app's cache)
/// and widget taps to MainActivity, which passes them here; this keeps the
/// widget's unread list up to date.
library launch_handler;

import '../../theme.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/avatar.dart';
import '../../core/nav_key.dart';
import '../../models/conversation.dart';
import '../auth/session.dart';
import '../chat/chat3_tools.dart';
import '../chat/chat_screen.dart';
import '../conversations/conversations_provider.dart';
import '../groups/group_tools.dart';

const _native = MethodChannel('veyon/call');

/// What was shared: text and/or files ({path, name, mime}).
class SharedPayload {
  final String text;
  final List<Map<String, String>> files;
  const SharedPayload(this.text, this.files);
  bool get isEmpty => text.trim().isEmpty && files.isEmpty;

  String get summary {
    if (files.isEmpty) return text.length > 60 ? '${text.substring(0, 60)}…' : text;
    final n = files.length;
    return n == 1 ? files.first['name'] ?? '1 file' : '$n files';
  }
}

/// Mounted at the app root (signed in).
class LaunchHandler extends ConsumerStatefulWidget {
  const LaunchHandler({super.key});
  @override
  ConsumerState<LaunchHandler> createState() => _LaunchHandlerState();
}

class _LaunchHandlerState extends ConsumerState<LaunchHandler> {
  String _lastWidgetData = '';

  @override
  void initState() {
    super.initState();
    _native.setMethodCallHandler((call) async {
      if (call.method == 'launchItems') _handle(call.arguments);
      return null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        _handle(await _native.invokeMethod('takeLaunchItems'));
      } catch (_) {/* not Android */}
    });
  }

  Object? _waiting; // shared before signing in

  void _handle(Object? raw) {
    if (raw is! Map) return;
    if (!ref.read(sessionControllerProvider).isSignedIn) {
      _waiting = raw;
      return;
    }
    final nav = veyonNavigatorKey.currentState;
    final ctx = veyonNavigatorKey.currentContext;
    if (nav == null || ctx == null) return;
    final chatId = raw['chatId'] as String?;
    if (chatId != null) {
      openChatById(ctx, ref, chatId);
      return;
    }
    final payload = SharedPayload(
      raw['text'] as String? ?? '',
      [for (final f in (raw['files'] as List? ?? const [])) Map<String, String>.from(f as Map)],
    );
    if (payload.isEmpty) return;
    nav.push(MaterialPageRoute(builder: (_) => ShareTargetScreen(payload: payload)));
  }

  /// Unread chats for the widget — names and counts only, never message text.
  void _updateWidget(List<Conversation> list, bool signedIn) {
    final unread = list.where((c) => c.unread > 0).toList()
      ..sort((a, b) => (b.lastMessage?.createdAt ?? '').compareTo(a.lastMessage?.createdAt ?? ''));
    final data = jsonEncode({
      'signedIn': signedIn,
      'total': unread.fold<int>(0, (n, c) => n + c.unread),
      'items': [
        for (final c in unread.take(4))
          {'id': c.id, 'title': c.locked ? '🔒 Locked chat' : c.displayName('Chat'), 'unread': c.unread},
      ],
    });
    if (data == _lastWidgetData) return;
    _lastWidgetData = data;
    _native.invokeMethod('updateWidget', data).catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(sessionControllerProvider.select((s) => s.isSignedIn));
    if (signedIn && _waiting != null) {
      final raw = _waiting;
      _waiting = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _handle(raw));
    }
    final list = signedIn ? (ref.watch(conversationsProvider).valueOrNull ?? const <Conversation>[]) : const <Conversation>[];
    _updateWidget(list, signedIn);
    return const SizedBox.shrink();
  }
}

/// "Send to…" — pick the chat for what was shared.
class ShareTargetScreen extends ConsumerStatefulWidget {
  final SharedPayload payload;
  const ShareTargetScreen({super.key, required this.payload});
  @override
  ConsumerState<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends ConsumerState<ShareTargetScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final lockOpen = ref.watch(chatLockProvider).open;
    final all = ref.watch(conversationsProvider).valueOrNull ?? const <Conversation>[];
    final chats = all
        .where((c) => (lockOpen || !c.locked) && !c.sendLocked && !(c.isPending && c.requestedBy != ref.read(sessionControllerProvider).user?.id))
        .where((c) => _q.isEmpty || c.displayName('').toLowerCase().contains(_q.toLowerCase()))
        .toList()
      ..sort((a, b) => (b.lastMessage?.createdAt ?? '').compareTo(a.lastMessage?.createdAt ?? ''));
    final accent = Theme.of(context).colorScheme.secondary;
    final p = widget.payload;
    return Scaffold(
      appBar: AppBar(title: const Text('Send to…')),
      body: Column(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Icon(p.files.isEmpty ? Icons.notes_rounded : Icons.attach_file_rounded, color: accent),
            const SizedBox(width: 10),
            Expanded(child: Text(p.summary, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search chats'),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Expanded(
          child: chats.isEmpty
              ? const Center(child: Text('No chats to send to.', style: TextStyle(color: VeyonColors.muted)))
              : ListView(children: [
                  for (final c in chats)
                    ListTile(
                      leading: c.isGroup
                          ? Avatar(label: c.title ?? 'Group', color: c.avatarColor)
                          : Avatar(label: c.peer?.displayName ?? '?', color: c.peer?.avatarColor, photoUrl: c.peer?.photoUrl),
                      title: Text(c.displayName('Chat')),
                      subtitle: Text(c.isGroup ? 'Group' : '@${c.peer?.username ?? ''}', style: const TextStyle(color: VeyonColors.muted)),
                      trailing: Icon(Icons.send_rounded, color: accent),
                      onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => ChatScreen(conversation: c, initialShare: p)),
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }
}
