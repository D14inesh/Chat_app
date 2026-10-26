/// Chat actions shared by the chat list, the chat screen menu and chat info:
/// mute for a while (8 hours / 1 week / always) and pin to the top.
library chat_list_actions;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../models/conversation.dart';
import 'conversations_provider.dart';

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

String _err(Object e) => e is ApiException ? e.message : 'Could not change that — check your connection.';

/// Muted → unmute. Not muted → ask for how long, then mute.
Future<void> chooseMute(BuildContext context, WidgetRef ref, Conversation c) async {
  final convos = ref.read(conversationsProvider.notifier);
  if (c.muted) {
    try {
      await convos.setMuted(c.id, false);
      if (context.mounted) _toast(context, 'Notifications unmuted.');
    } catch (e) {
      if (context.mounted) _toast(context, _err(e));
    }
    return;
  }
  final hours = await showModalBottomSheet<double>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Mute notifications for…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          ListTile(leading: const Icon(Icons.schedule_rounded), title: const Text('8 hours'), onTap: () => Navigator.pop(ctx, 8.0)),
          ListTile(leading: const Icon(Icons.date_range_rounded), title: const Text('1 week'), onTap: () => Navigator.pop(ctx, 168.0)),
          ListTile(leading: const Icon(Icons.notifications_off_rounded), title: const Text('Always'), onTap: () => Navigator.pop(ctx, 0.0)),
        ],
      ),
    ),
  );
  if (hours == null) return;
  try {
    await convos.setMuted(c.id, true, hours: hours > 0 ? hours : null);
    if (context.mounted) {
      _toast(context, hours == 8 ? 'Muted for 8 hours.' : hours == 168 ? 'Muted for 1 week.' : 'Muted.');
    }
  } catch (e) {
    if (context.mounted) _toast(context, _err(e));
  }
}

Future<void> togglePin(BuildContext context, WidgetRef ref, Conversation c) async {
  try {
    await ref.read(conversationsProvider.notifier).setPinned(c.id, !c.pinned);
    if (context.mounted) _toast(context, c.pinned ? 'Chat unpinned.' : 'Chat pinned to the top.');
  } catch (e) {
    if (context.mounted) _toast(context, _err(e));
  }
}

/// "Muted until 6:30 pm" / "Muted until Tue" for chat info.
String? mutedUntilLabel(Conversation c) {
  final until = c.mutedUntil == null ? null : DateTime.tryParse(c.mutedUntil!)?.toLocal();
  if (!c.muted || until == null) return null;
  final now = DateTime.now();
  final sameDay = until.year == now.year && until.month == now.month && until.day == now.day;
  final h = until.hour % 12 == 0 ? 12 : until.hour % 12;
  final time = '$h:${until.minute.toString().padLeft(2, '0')} ${until.hour < 12 ? 'am' : 'pm'}';
  return sameDay ? 'Muted until $time' : 'Muted until ${until.day}/${until.month} $time';
}
