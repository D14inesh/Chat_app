/// "Schedule a message" — the website's openScheduleMessagePanel(): pick an
/// automatic message by type (same templates) or type your own, choose a
/// date and time, and the server sends it then. Lists what's still waiting,
/// each with a cancel button.
library schedule_screen;

import '../../theme.dart';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../models/conversation.dart';
import '../auth/session.dart';

const _categories = {
  'birthday': '🎂 Birthday',
  'happy': '😊 Happy',
  'love': '❤️ Love',
  'sad': '🤗 Sad',
  'breakup': '💙 Breakup',
  'general': '⏰ General',
};

/// Same wording as the website's SCHEDULED_MESSAGE_TEMPLATES.
const _templates = <String, List<String>>{
  'birthday': [
    '🎂 Happy Birthday! Wishing you a year full of joy, health, and everything good.',
    '🎉 Happy Birthday! Hope your day is as wonderful as you are.',
    "🎈 Happy Birthday! Here's to another great year ahead.",
  ],
  'happy': [
    '😊 Just wanted to say — hope this made you smile today!',
    '🌟 Thinking of you and hoping today is a good one.',
    '🥳 Celebrating this moment with you!',
  ],
  'love': [
    "❤️ Just a little reminder that you're loved.",
    '💕 Thinking of you today, always.',
    '💖 Sending you all my love.',
  ],
  'sad': [
    "🤗 Sending you strength today — you're not alone in this.",
    "💙 It's okay to not be okay. Take it one moment at a time.",
    "🫂 Thinking of you — I'm here if you need to talk.",
  ],
  'breakup': [
    '💙 Healing takes time — be gentle with yourself today.',
    '🌤️ This chapter closing makes room for something better.',
    '🫶 You deserve peace and someone who matches your effort.',
  ],
  'general': ['⏰ Just checking in with you.'],
};

class ScheduleScreen extends ConsumerStatefulWidget {
  final Conversation conversation;
  const ScheduleScreen({super.key, required this.conversation});

  @override
  ConsumerState<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends ConsumerState<ScheduleScreen> {
  bool _auto = true;
  String _category = 'birthday';
  final _text = TextEditingController();
  DateTime _when = DateTime.now().add(const Duration(hours: 1));
  bool _saving = false;
  List<({String id, String text, DateTime sendAt})>? _items;
  String? _listError;

  String get _target => widget.conversation.displayName('them');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _load() async {
    final session = ref.read(sessionControllerProvider);
    try {
      final raw = await session.api.listScheduled(widget.conversation.id);
      final key = await resolveConversationKey(session, widget.conversation);
      final items = <({String id, String text, DateTime sendAt})>[];
      for (final r in raw.cast<Map<String, dynamic>>()) {
        String text;
        try {
          text = await decryptText(key, r['ciphertext'] as String, r['iv'] as String);
        } catch (_) {
          text = '(could not decrypt)';
        }
        items.add((id: r['id'] as String, text: text, sendAt: DateTime.parse(r['sendAt'] as String).toLocal()));
      }
      if (mounted) setState(() { _items = items; _listError = null; });
    } catch (_) {
      if (mounted) setState(() => _listError = 'Scheduled messages need a connection to load.');
    }
  }

  Future<void> _pickWhen() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (time == null) return;
    setState(() => _when = DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _schedule() async {
    final String text;
    if (_auto) {
      final options = _templates[_category] ?? _templates['general']!;
      text = options[Random().nextInt(options.length)];
    } else {
      text = _text.text.trim();
      if (text.isEmpty) {
        _toast('Type the message to send.');
        return;
      }
    }
    if (_when.isBefore(DateTime.now())) {
      _toast('Pick a date and time in the future.');
      return;
    }
    setState(() => _saving = true);
    final session = ref.read(sessionControllerProvider);
    try {
      final key = await resolveConversationKey(session, widget.conversation);
      final env = await encryptText(key, text);
      await session.api.scheduleMessage(widget.conversation.id, ciphertext: env.ciphertext, iv: env.iv, sendAt: _when);
      _text.clear();
      _toast('Message scheduled.');
      await _load();
    } catch (e) {
      _toast(e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cancel(String id) async {
    try {
      await ref.read(sessionControllerProvider).api.cancelScheduled(widget.conversation.id, id);
      await _load();
    } catch (e) {
      _toast(e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), ''));
    }
  }

  String _fmt(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year} at ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule a message')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('How should the message be picked?', style: TextStyle(color: VeyonColors.muted)),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Automatic')),
              ButtonSegment(value: false, label: Text('Type my own')),
            ],
            selected: {_auto},
            onSelectionChanged: (s) => setState(() => _auto = s.first),
          ),
          const SizedBox(height: 16),
          if (_auto)
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final e in _categories.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => _category = v ?? 'general'),
            )
          else
            TextField(
              controller: _text,
              maxLength: 4000,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(labelText: 'Message to $_target', hintText: 'Type the exact message to send…'),
            ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_rounded),
            title: const Text('Send at'),
            subtitle: Text(_fmt(_when)),
            trailing: const Icon(Icons.edit_calendar_rounded),
            onTap: _pickWhen,
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _saving ? null : _schedule, child: Text(_saving ? 'Scheduling…' : 'Schedule')),
          const SizedBox(height: 24),
          const Text('Scheduled', style: TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          if (_listError != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_listError!, style: const TextStyle(color: VeyonColors.muted)))
          else if (_items == null)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          else if (_items!.isEmpty)
            const Padding(padding: EdgeInsets.all(8), child: Text('Nothing scheduled yet.', style: TextStyle(color: VeyonColors.muted)))
          else
            for (final m in _items!)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Text('🕒', style: TextStyle(fontSize: 22)),
                title: Text(m.text),
                subtitle: Text('To $_target · ${_fmt(m.sendAt)}', style: const TextStyle(color: VeyonColors.muted)),
                trailing: IconButton(
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _cancel(m.id),
                ),
              ),
        ],
      ),
    );
  }
}
