/// "Forward" — pick one or more chats; each gets its own re-encrypted copy.
/// Same rules as the website: any group, or a direct chat that's accepted
/// (or that I requested myself).
library forward_sheet;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../../models/message.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';
import 'chat_controller.dart';

Future<void> showForwardSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<ChatMessage> messages,
  required SecretKey sourceKey,
  required String sourceConversationId,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ForwardSheet(messages: messages, sourceKey: sourceKey, sourceConversationId: sourceConversationId),
  );
}

class _ForwardSheet extends ConsumerStatefulWidget {
  final List<ChatMessage> messages;
  final SecretKey sourceKey;
  final String sourceConversationId;
  const _ForwardSheet({required this.messages, required this.sourceKey, required this.sourceConversationId});

  @override
  ConsumerState<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends ConsumerState<_ForwardSheet> {
  final _selected = <String>{};
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final me = ref.read(sessionControllerProvider).user!.id;
    final all = ref.watch(conversationsProvider).valueOrNull ?? const <Conversation>[];
    final targets = all
        .where((c) => c.id != widget.sourceConversationId &&
            (c.isGroup || c.status != 'pending' || c.requestedBy == me))
        .toList();

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                widget.messages.length == 1 ? 'Forward message' : 'Forward ${widget.messages.length} messages',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              child: targets.isEmpty
                  ? const Center(child: Text('No other chat to forward this to yet.'))
                  : ListView(
                      children: [
                        for (final c in targets)
                          CheckboxListTile(
                            value: _selected.contains(c.id),
                            onChanged: _sending
                                ? null
                                : (v) => setState(() => v == true ? _selected.add(c.id) : _selected.remove(c.id)),
                            title: Text(c.displayName('Chat')),
                            secondary: CircleAvatar(child: Text(c.displayName('?').characters.first.toUpperCase())),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: _sending ? null : () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending || _selected.isEmpty ? null : () => _send(targets),
                    child: Text(_sending ? 'Forwarding…' : 'Forward'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send(List<Conversation> targets) async {
    setState(() => _sending = true);
    final session = ref.read(sessionControllerProvider);
    var ok = 0;
    var total = 0;
    for (final target in targets.where((c) => _selected.contains(c.id))) {
      for (final m in widget.messages) {
        total++;
        try {
          await forwardMessage(session: session, message: m, sourceKey: widget.sourceKey, target: target);
          ok++;
        } catch (_) {
          // Keep going — one failing target shouldn't stop the rest.
        }
      }
    }
    if (!mounted) return;
    Navigator.pop(context);
    final text = ok == total
        ? (_selected.length == 1 ? 'Forwarded.' : 'Forwarded to ${_selected.length} chats.')
        : ok == 0
            ? 'Could not forward — check your connection.'
            : 'Forwarded $ok of $total — some failed.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
