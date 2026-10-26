/// Broadcast lists — send one message to many people privately. Each gets
/// it as a normal 1:1 message encrypted for them alone (same as the
/// website); replies come back to your own chat with each person.
library broadcasts_screen;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/avatar.dart';
import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';

class BroadcastsScreen extends ConsumerStatefulWidget {
  const BroadcastsScreen({super.key});
  @override
  ConsumerState<BroadcastsScreen> createState() => _BroadcastsScreenState();
}

class _BroadcastsScreenState extends ConsumerState<BroadcastsScreen> {
  List<Map<String, dynamic>>? _lists;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(sessionControllerProvider).api.listBroadcasts();
      if (mounted) setState(() => _lists = rows.cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn’t load your lists — check your connection.');
    }
  }

  List<Conversation> get _directs => (ref.read(conversationsProvider).valueOrNull ?? const [])
      .where((c) => !c.isGroup && c.status == 'accepted' && c.peer?.publicKey != null)
      .toList()
    ..sort((a, b) => a.peer!.displayName.toLowerCase().compareTo(b.peer!.displayName.toLowerCase()));

  AppUser? _person(String id) => _directs.where((c) => c.peer!.id == id).firstOrNull?.peer;

  Future<void> _editList(Map<String, dynamic>? existing) async {
    final saved = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => _ListEditor(existing: existing, contacts: _directs.map((c) => c.peer!).toList())),
    );
    if (saved == null) return;
    setState(() => _lists = [...?_lists?.where((l) => l['id'] != saved['id']), saved]);
  }

  Future<void> _delete(Map<String, dynamic> l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete list?'),
        content: Text('Delete the broadcast list “${l['name']}”? Messages already sent stay in each chat.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: VeyonColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(sessionControllerProvider).api.deleteBroadcast(l['id'] as String);
      setState(() => _lists!.removeWhere((x) => x['id'] == l['id']));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not delete — check your connection.')));
    }
  }

  Future<void> _send(Map<String, dynamic> l) async {
    final ids = (l['memberIds'] as List<dynamic>).cast<String>();
    final text = TextEditingController();
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(18, 0, 18, MediaQuery.of(ctx).viewInsets.bottom + 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.campaign_rounded, color: Theme.of(ctx).colorScheme.secondary),
              const SizedBox(width: 8),
              Expanded(child: Text(l['name'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            ]),
            const SizedBox(height: 4),
            Text('Goes to ${ids.length} people, each as a private message from you.', style: const TextStyle(color: VeyonColors.muted)),
            const SizedBox(height: 12),
            TextField(controller: text, autofocus: true, minLines: 3, maxLines: 8, maxLength: 4000, decoration: const InputDecoration(hintText: 'Type your message…')),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.send_rounded),
                label: Text('Send to ${ids.length}'),
              ),
            ),
          ],
        ),
      ),
    );
    final body = text.text.trim();
    if (go != true || body.isEmpty || !mounted) return;

    final session = ref.read(sessionControllerProvider);
    final messenger = ScaffoldMessenger.of(context);
    var sent = 0;
    final failed = <String>[];
    for (final id in ids) {
      final convo = _directs.where((c) => c.peer!.id == id).firstOrNull;
      if (convo == null || session.ws == null) {
        failed.add(_person(id)?.displayName ?? 'someone');
        continue;
      }
      try {
        final key = await resolveConversationKey(session, convo);
        final env = await encryptText(key, body);
        session.ws!.sendMessage(conversationId: convo.id, ciphertext: env.ciphertext, iv: env.iv, kind: 'text', tempId: const Uuid().v4());
        sent++;
      } catch (_) {
        failed.add(convo.peer!.displayName);
      }
    }
    messenger.showSnackBar(SnackBar(
      content: Text(failed.isEmpty ? 'Sent to all $sent ✓' : 'Sent to $sent. Couldn’t send to: ${failed.join(', ')}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      appBar: AppBar(title: const Text('Broadcast lists')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editList(null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New list'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(Icons.campaign_rounded, color: accent, size: 30),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Send one message to many people at once — each gets it privately, like a normal message from you.',
                      style: TextStyle(color: VeyonColors.muted)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          if (_error != null) Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center)),
          if (_lists == null && _error == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          if (_lists != null && _lists!.isEmpty)
            const Padding(
              padding: EdgeInsets.all(30),
              child: Text('No broadcast lists yet. Create one to message a group of contacts privately.',
                  textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
            ),
          for (final l in _lists ?? const <Map<String, dynamic>>[])
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: const Icon(Icons.campaign_rounded, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                          Text(
                            '${(l['memberIds'] as List).length} recipients · ${(l['memberIds'] as List).map((id) => _person(id as String)?.displayName).whereType<String>().take(4).join(', ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: VeyonColors.muted, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: () => _send(l),
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      child: const Text('Send'),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) => v == 'edit' ? _editList(l) : _delete(l),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: VeyonColors.danger))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ListEditor extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  final List<AppUser> contacts;
  const _ListEditor({required this.existing, required this.contacts});
  @override
  ConsumerState<_ListEditor> createState() => _ListEditorState();
}

class _ListEditorState extends ConsumerState<_ListEditor> {
  late final _name = TextEditingController(text: widget.existing?['name'] as String? ?? '');
  late final Set<String> _picked = {...(widget.existing?['memberIds'] as List<dynamic>? ?? const []).cast<String>()};
  String _filter = '';
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await ref.read(sessionControllerProvider).api.saveBroadcast(
            id: widget.existing?['id'] as String?,
            name: _name.text,
            memberIds: _picked.toList(),
          );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), ''))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.contacts.where((c) => _filter.isEmpty || c.displayName.toLowerCase().contains(_filter)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New broadcast list' : 'Edit list'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              onPressed: _saving || _name.text.trim().isEmpty || _picked.isEmpty ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
            child: TextField(
              controller: _name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'List name', hintText: 'e.g. Customers, Family', counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search contacts'),
              onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
            child: Row(children: [
              const Text('Recipients', style: TextStyle(fontWeight: FontWeight.w700, color: VeyonColors.muted)),
              const Spacer(),
              Text('${_picked.length} selected', style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.w600)),
            ]),
          ),
          Expanded(
            child: widget.contacts.isEmpty
                ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('You need accepted chats with people before you can add them.', textAlign: TextAlign.center)))
                : ListView(
                    children: [
                      for (final c in shown)
                        CheckboxListTile(
                          value: _picked.contains(c.id),
                          onChanged: (v) => setState(() => v == true ? _picked.add(c.id) : _picked.remove(c.id)),
                          secondary: Avatar(label: c.displayName, color: c.avatarColor, photoUrl: c.photoUrl, radius: 20),
                          title: Text(c.displayName),
                          subtitle: Text('@${c.username}', style: const TextStyle(color: VeyonColors.muted)),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
