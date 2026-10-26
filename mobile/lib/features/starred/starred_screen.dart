import '../../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/key_resolver.dart';
import '../../core/crypto/keys.dart';
import '../../models/conversation.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';
import 'starred_provider.dart';

/// Cross-conversation list of everything the user has starred -- mirrors
/// app.js's openStarredMessagesPanel. Each row decrypts on the fly using
/// whichever conversation it belongs to (resolved from the already-loaded
/// conversation list), same as the web client does.
class StarredScreen extends ConsumerWidget {
  const StarredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final conversationsAsync = ref.watch(conversationsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      body: conversationsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load: $e')),
        data: (conversations) => FutureBuilder<List<dynamic>>(
          future: session.api.listStarredMessages(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snapshot.data!;
            if (rows.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('No starred messages yet.', style: TextStyle(color: VeyonColors.muted)),
                ),
              );
            }
            final byId = {for (final c in conversations) c.id: c};
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: VeyonColors.hairline),
              itemBuilder: (context, i) {
                final row = rows[i] as Map<String, dynamic>;
                final conversation = byId[row['conversationId'] as String];
                return _StarredTile(session: session, conversation: conversation, row: row);
              },
            );
          },
        ),
      ),
    );
  }
}

class _StarredTile extends ConsumerWidget {
  final Session session;
  final Conversation? conversation;
  final Map<String, dynamic> row;
  const _StarredTile({required this.session, required this.conversation, required this.row});

  Future<String> _decrypt() async {
    if (conversation == null) return '(conversation not found)';
    try {
      final key = await resolveConversationKey(session, conversation!);
      final kind = row['kind'] as String;
      if (kind == 'file') {
        final meta = await decryptFileMeta(key, row['ciphertext'] as String, row['iv'] as String);
        return '📎 ${meta['name']}';
      }
      if (kind != 'text') return '($kind message)';
      return await decryptText(key, row['ciphertext'] as String, row['iv'] as String);
    } catch (_) {
      return '🔒 Could not decrypt this message.';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starred = ref.watch(starredProvider).contains(row['id'] as String);
    return ListTile(
      title: FutureBuilder<String>(
        future: _decrypt(),
        builder: (context, snapshot) => Text(snapshot.data ?? '…', maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      subtitle: Text(conversation?.displayName('Unknown chat') ?? 'Unknown chat',
          style: const TextStyle(color: VeyonColors.muted, fontSize: 12)),
      trailing: IconButton(
        icon: Icon(starred ? Icons.star_rounded : Icons.star_border_rounded, color: Colors.amber),
        onPressed: () => ref.read(starredProvider.notifier).toggle(row['id'] as String),
      ),
    );
  }
}
