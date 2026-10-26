/// Quick replies — saved answers. In a chat, type "/" and a shortcut to
/// insert one; manage them from the menu. Synced with the website (they're
/// stored on the server, so the same list shows on every device).
library quick_replies;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../auth/session.dart';

class QuickReply {
  final String id;
  final String shortcut;
  final String body;
  const QuickReply({required this.id, required this.shortcut, required this.body});

  factory QuickReply.fromJson(Map<String, dynamic> j) =>
      QuickReply(id: j['id'] as String, shortcut: j['shortcut'] as String, body: j['body'] as String);
}

class QuickRepliesController extends StateNotifier<List<QuickReply>> {
  final Session session;
  bool _loaded = false;
  QuickRepliesController(this.session) : super(const []);

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final rows = await session.api.listQuickReplies();
      state = rows.map((r) => QuickReply.fromJson(r as Map<String, dynamic>)).toList();
      _loaded = true;
    } catch (_) {/* offline — keep what we have */}
  }

  Future<void> save({String? id, required String shortcut, required String body}) async {
    final row = await session.api.saveQuickReply(id: id, shortcut: shortcut, body: body);
    final reply = QuickReply.fromJson(row);
    state = [...state.where((r) => r.id != reply.id), reply]..sort((a, b) => a.shortcut.compareTo(b.shortcut));
  }

  Future<void> delete(String id) async {
    await session.api.deleteQuickReply(id);
    state = state.where((r) => r.id != id).toList();
  }

  /// Matches for a composer value like "/ho" (null when it isn't a "/" query).
  List<QuickReply>? matchesFor(String value) {
    final m = RegExp(r'^/([a-z0-9_-]*)$', caseSensitive: false).firstMatch(value);
    if (m == null) return null;
    final q = m.group(1)!.toLowerCase();
    return state.where((r) => r.shortcut.startsWith(q) || r.body.toLowerCase().contains(q)).take(8).toList();
  }
}

final quickRepliesProvider = StateNotifierProvider<QuickRepliesController, List<QuickReply>>((ref) {
  return QuickRepliesController(ref.watch(sessionControllerProvider));
});

/// The "/" popup shown above the composer.
class QuickReplyPopup extends StatelessWidget {
  final List<QuickReply> matches;
  final bool anySaved;
  final ValueChanged<QuickReply> onPick;
  final VoidCallback onManage;
  const QuickReplyPopup({super.key, required this.matches, required this.anySaved, required this.onPick, required this.onManage});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            child: Row(children: [
              Icon(Icons.bolt_rounded, size: 16, color: accent),
              const SizedBox(width: 6),
              const Text('QUICK REPLIES', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: VeyonColors.muted)),
              const Spacer(),
              TextButton(onPressed: onManage, style: TextButton.styleFrom(visualDensity: VisualDensity.compact), child: const Text('Manage')),
            ]),
          ),
          if (matches.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(anySaved ? 'No match.' : 'No quick replies yet — tap Manage to add one.', style: const TextStyle(color: VeyonColors.muted)),
            ),
          for (final r in matches)
            ListTile(
              dense: true,
              onTap: () => onPick(r),
              title: Text(r.body, maxLines: 1, overflow: TextOverflow.ellipsis),
              leading: Text('/${r.shortcut}', style: TextStyle(color: accent, fontWeight: FontWeight.w800)),
            ),
        ],
      ),
    );
  }
}

class QuickRepliesScreen extends ConsumerStatefulWidget {
  final bool startAdding;
  const QuickRepliesScreen({super.key, this.startAdding = false});

  @override
  ConsumerState<QuickRepliesScreen> createState() => _QuickRepliesScreenState();
}

class _QuickRepliesScreenState extends ConsumerState<QuickRepliesScreen> {
  @override
  void initState() {
    super.initState();
    ref.read(quickRepliesProvider.notifier).load(force: true);
    if (widget.startAdding) WidgetsBinding.instance.addPostFrameCallback((_) => _edit(null));
  }

  Future<void> _edit(QuickReply? existing) async {
    final shortcut = TextEditingController(text: existing?.shortcut ?? '');
    final body = TextEditingController(text: existing?.body ?? '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(18, 0, 18, MediaQuery.of(ctx).viewInsets.bottom + 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(existing == null ? 'New quick reply' : 'Edit quick reply', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            TextField(
              controller: shortcut,
              autofocus: existing == null,
              decoration: const InputDecoration(labelText: 'Shortcut', prefixText: '/', hintText: 'hours'),
              onChanged: (v) {
                final clean = v.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '').toLowerCase();
                if (clean != v) shortcut.value = TextEditingValue(text: clean, selection: TextSelection.collapsed(offset: clean.length));
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: body,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: 'Message', hintText: 'Our office is open 9 am – 6 pm, Monday to Saturday.'),
            ),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(quickRepliesProvider.notifier).save(id: existing?.id, shortcut: shortcut.text, body: body.text);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final replies = ref.watch(quickRepliesProvider);
    final accent = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      appBar: AppBar(title: const Text('Quick replies')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(Icons.bolt_rounded, color: accent, size: 28),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Save answers you send often. In any chat, type / and the shortcut to insert one.',
                      style: TextStyle(color: VeyonColors.muted)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          if (replies.isEmpty)
            const Padding(
              padding: EdgeInsets.all(30),
              child: Text('No quick replies yet — add your first one.', textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
            ),
          for (final r in replies)
            Card(
              child: ListTile(
                title: Text('/${r.shortcut}', style: TextStyle(color: accent, fontWeight: FontWeight.w800)),
                subtitle: Text(r.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _edit(r),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, color: VeyonColors.danger),
                  onPressed: () => ref.read(quickRepliesProvider.notifier).delete(r.id),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
