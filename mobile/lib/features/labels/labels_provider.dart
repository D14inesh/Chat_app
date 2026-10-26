/// Custom chat lists ("labels": Work, Family, …) — the website's labels.
/// Shown as extra filter tabs on the chat list and as coloured chips on each
/// chat. Kept on the phone so they show offline.
library labels_provider;

import '../../theme.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/avatar.dart';
import '../auth/session.dart';

class ChatLabel {
  final String id;
  final String name;
  final String color;
  final List<String> conversationIds;
  const ChatLabel({required this.id, required this.name, required this.color, required this.conversationIds});

  factory ChatLabel.fromJson(Map<String, dynamic> j) => ChatLabel(
        id: j['id'] as String,
        name: j['name'] as String,
        color: j['color'] as String? ?? '#A76BC9',
        conversationIds: ((j['conversationIds'] as List<dynamic>?) ?? const []).cast<String>(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color, 'conversationIds': conversationIds};
}

/// Colours offered when creating a list (the server defaults to purple).
const kLabelColors = ['#A76BC9', '#2F6BFF', '#00B894', '#E17055', '#E84393', '#FDCB6E', '#00CEC9', '#636E72'];

class LabelsController extends StateNotifier<List<ChatLabel>> {
  final Session _session;
  LabelsController(this._session) : super(const []) {
    _init();
  }

  Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/veyon_cache/labels.json');

  Future<void> _init() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        state = (jsonDecode(await f.readAsString()) as List<dynamic>)
            .map((j) => ChatLabel.fromJson(j as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
    await refresh();
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(state.map((l) => l.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> refresh() async {
    try {
      state = (await _session.api.listLabels()).map((j) => ChatLabel.fromJson(j as Map<String, dynamic>)).toList();
      await _save();
    } catch (_) {}
  }

  Future<ChatLabel> create(String name, String color) async {
    final label = ChatLabel.fromJson(await _session.api.createLabel(name, color: color));
    state = [...state, label];
    await _save();
    return label;
  }

  Future<void> delete(String id) async {
    await _session.api.deleteLabel(id);
    state = state.where((l) => l.id != id).toList();
    await _save();
  }

  Future<void> toggle(String labelId, String conversationId) async {
    final applied = await _session.api.toggleLabel(labelId, conversationId);
    state = [
      for (final l in state)
        l.id != labelId
            ? l
            : ChatLabel(
                id: l.id,
                name: l.name,
                color: l.color,
                conversationIds: applied
                    ? {...l.conversationIds, conversationId}.toList()
                    : l.conversationIds.where((c) => c != conversationId).toList(),
              ),
    ];
    await _save();
  }
}

final labelsProvider = StateNotifierProvider<LabelsController, List<ChatLabel>>((ref) {
  return LabelsController(ref.watch(sessionControllerProvider));
});

/// Small coloured chip with a list's name.
class LabelChip extends StatelessWidget {
  final ChatLabel label;
  const LabelChip(this.label, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 4, top: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: parseHexColor(label.color), borderRadius: BorderRadius.circular(6)),
        child: Text(label.name, style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
      );
}

/// "Add to list" — tick the lists this chat belongs to, or create a new one.
Future<void> showAddToListSheet(BuildContext context, WidgetRef ref, String conversationId) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AddToListSheet(conversationId: conversationId),
  );
}

class _AddToListSheet extends ConsumerStatefulWidget {
  final String conversationId;
  const _AddToListSheet({required this.conversationId});

  @override
  ConsumerState<_AddToListSheet> createState() => _AddToListSheetState();
}

class _AddToListSheetState extends ConsumerState<_AddToListSheet> {
  final _name = TextEditingController();
  String _color = kLabelColors.first;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(labelsProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Add to list', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            if (labels.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No lists yet — create one below.', style: TextStyle(color: VeyonColors.muted)),
              ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in labels)
                    CheckboxListTile(
                      value: l.conversationIds.contains(widget.conversationId),
                      onChanged: _busy
                          ? null
                          : (_) async {
                              setState(() => _busy = true);
                              try {
                                await ref.read(labelsProvider.notifier).toggle(l.id, widget.conversationId);
                              } catch (_) {
                                _toast('Could not change that — check your connection.');
                              } finally {
                                if (mounted) setState(() => _busy = false);
                              }
                            },
                      title: Align(alignment: Alignment.centerLeft, child: LabelChip(l)),
                      secondary: IconButton(
                        tooltip: 'Delete list',
                        icon: const Icon(Icons.delete_outline_rounded, size: 20),
                        onPressed: _busy ? null : () => _delete(l),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(color: VeyonColors.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                controller: _name,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'New list', hintText: 'e.g. Work, Family…'),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final c in kLabelColors)
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 30,
                        height: 30,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: parseHexColor(c),
                          shape: BoxShape.circle,
                          border: Border.all(color: _color == c ? Colors.white : Colors.transparent, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _busy ? null : _create, child: const Text('Create')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('Give this list a name.');
      return;
    }
    setState(() => _busy = true);
    try {
      final label = await ref.read(labelsProvider.notifier).create(name, _color);
      // A list made from inside a chat starts with that chat in it.
      await ref.read(labelsProvider.notifier).toggle(label.id, widget.conversationId);
      _name.clear();
    } catch (_) {
      _toast('Could not create the list — check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ChatLabel l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${l.name}"?'),
        content: const Text('The chats themselves stay — only the list is removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(labelsProvider.notifier).delete(l.id);
    } catch (_) {
      _toast('Could not delete — check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
