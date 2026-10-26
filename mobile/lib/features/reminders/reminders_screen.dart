import '../../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_notifications.dart';
import '../auth/session.dart';

const _kCategories = ['general', 'birthday', 'happy', 'love', 'sad', 'breakup'];
const _kCategoryLabels = {
  'general': 'General',
  'birthday': 'Birthday',
  'happy': 'Happy',
  'love': 'Love',
  'sad': 'Sad',
  'breakup': 'Breakup',
};

/// Personal date/task reminders. Delivery is a locally-scheduled OS
/// notification (see core/local_notifications.dart) rather than the web
/// app's server-side Web Push -- see the chat's note to the user about why
/// this needs a future Firebase Cloud Messaging setup to also notify when
/// this isn't the device that created the reminder.
class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  List<dynamic>? _reminders;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final session = ref.read(sessionControllerProvider);
      final rows = await session.api.listReminders();
      if (mounted) setState(() => _reminders = rows);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load reminders: $e');
    }
  }

  Future<void> _create() async {
    final result = await showDialog<_NewReminder>(context: context, builder: (_) => const _NewReminderDialog());
    if (result == null) return;
    try {
      final session = ref.read(sessionControllerProvider);
      final saved = await session.api.createReminder(
        content: result.content,
        category: result.category,
        remindAt: result.remindAt.toUtc().toIso8601String(),
      );
      await LocalNotifications.scheduleReminder(
        id: saved['id'] as String,
        content: saved['content'] as String,
        category: saved['category'] as String,
        remindAt: result.remindAt,
      );
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  Future<void> _delete(String id) async {
    final session = ref.read(sessionControllerProvider);
    await session.api.deleteReminder(id);
    await LocalNotifications.cancel(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      floatingActionButton: FloatingActionButton(onPressed: _create, child: const Icon(Icons.add_rounded)),
      body: _error != null
          ? Center(child: Text(_error!))
          : _reminders == null
              ? const Center(child: CircularProgressIndicator())
              : _reminders!.isEmpty
                  ? const Center(child: Text('No reminders yet.', style: TextStyle(color: VeyonColors.muted)))
                  : ListView.builder(
                      itemCount: _reminders!.length,
                      itemBuilder: (context, i) {
                        final r = _reminders![i] as Map<String, dynamic>;
                        final at = DateTime.parse(r['remindAt'] as String).toLocal();
                        return ListTile(
                          title: Text(r['content'] as String),
                          subtitle: Text('${_kCategoryLabels[r['category']] ?? r['category']} · ${at.toString().substring(0, 16)}'),
                          trailing: IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _delete(r['id'] as String)),
                        );
                      },
                    ),
    );
  }
}

class _NewReminder {
  final String content;
  final String category;
  final DateTime remindAt;
  _NewReminder(this.content, this.category, this.remindAt);
}

class _NewReminderDialog extends StatefulWidget {
  const _NewReminderDialog();

  @override
  State<_NewReminderDialog> createState() => _NewReminderDialogState();
}

class _NewReminderDialogState extends State<_NewReminderDialog> {
  final _contentCtrl = TextEditingController();
  String _category = 'general';
  DateTime _at = DateTime.now().add(const Duration(hours: 1));

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(context: context, initialDate: _at, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (time == null) return;
    setState(() => _at = DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New reminder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(controller: _contentCtrl, decoration: const InputDecoration(labelText: 'What is this about?')),
          const SizedBox(height: 12),
          DropdownButton<String>(
            value: _category,
            isExpanded: true,
            items: _kCategories.map((c) => DropdownMenuItem(value: c, child: Text(_kCategoryLabels[c]!))).toList(),
            onChanged: (v) => setState(() => _category = v ?? 'general'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDateTime,
            icon: const Icon(Icons.schedule_rounded),
            label: Text(_at.toString().substring(0, 16)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_contentCtrl.text.trim().isEmpty) return;
            Navigator.pop(context, _NewReminder(_contentCtrl.text.trim(), _category, _at));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
