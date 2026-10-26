/// Date of birth: only private (1-to-1) chats and calls are for people 18
/// and over — everything else is open to everyone. Optional at sign-up;
/// otherwise asked the first time someone opens a private chat.
library birth_date;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/nav_key.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';

const _under18 = 'Private chats are for people 18 and over. Groups and everything else work for you.';

/// A date-of-birth picker field (sign-up and the private-chat prompt).
class BirthDateField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final bool optional;
  const BirthDateField({super.key, required this.value, required this.onChanged, this.optional = false});

  static String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            firstDate: DateTime(1900),
            lastDate: now,
            initialDate: value ?? DateTime(now.year - 20, now.month, now.day),
            initialEntryMode: DatePickerEntryMode.calendarOnly,
            helpText: 'Date of birth',
          );
          if (d != null) onChanged(d);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: optional ? 'Date of birth (optional)' : 'Date of birth',
            suffixIcon: const Icon(Icons.cake_outlined),
          ),
          child: Text(
            value == null ? 'Tap to choose' : '${value!.day}/${value!.month}/${value!.year}',
            style: TextStyle(color: value == null ? VeyonColors.muted : null),
          ),
        ),
      ),
      if (optional)
        const Padding(
          padding: EdgeInsets.only(top: 6, left: 4),
          child: Text('Only needed for private (1-to-1) chats, which are 18+. You can add it later.',
              style: TextStyle(color: VeyonColors.muted, fontSize: 12)),
        ),
    ]);
  }
}

/// The door to private chats: asks for a date of birth the first time, then
/// lets 18+ through. Returns true when the private chat may open.
Future<bool> privateChatGate() async {
  final ctx = veyonNavigatorKey.currentContext;
  if (ctx == null) return false;
  final container = ProviderScope.containerOf(ctx, listen: false);
  var user = container.read(sessionControllerProvider).user;
  if (user == null) return false;
  if (user.birthDate == null) {
    final saved = await showDialog<bool>(context: ctx, builder: (_) => const _BirthDateDialog());
    if (saved != true) return false;
    user = container.read(sessionControllerProvider).user;
  }
  if (user?.isAdult != true) {
    final now = veyonNavigatorKey.currentContext;
    if (now != null && now.mounted) ScaffoldMessenger.maybeOf(now)?.showSnackBar(const SnackBar(content: Text(_under18)));
    return false;
  }
  return true;
}

class _BirthDateDialog extends ConsumerStatefulWidget {
  const _BirthDateDialog();
  @override
  ConsumerState<_BirthDateDialog> createState() => _BirthDateDialogState();
}

class _BirthDateDialogState extends ConsumerState<_BirthDateDialog> {
  DateTime? _date;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    final d = _date;
    if (d == null) {
      setState(() => _error = 'Pick your date of birth.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save date of birth?'),
        content: Text('${d.day}/${d.month}/${d.year} — it can’t be changed later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await ref.read(sessionControllerProvider).api.postJson('/api/auth/birth-date', {'birthDate': BirthDateField.iso(d)});
      await ref.read(sessionControllerProvider.notifier).updateBirthDate(res['birthDate'] as String, res['isAdult'] == true);
      ref.read(conversationsProvider.notifier).refresh();
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(Icons.verified_user_outlined, color: Theme.of(context).colorScheme.primary, size: 30),
      title: const Text('Private chats are 18+'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
          'Add your date of birth once to use private chats and calls. Groups, status and everything else don’t need it.',
          style: TextStyle(color: VeyonColors.muted, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, style: const TextStyle(color: VeyonColors.danger))),
        BirthDateField(value: _date, onChanged: (d) => setState(() => _date = d)),
      ]),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Not now')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
      ],
    );
  }
}
