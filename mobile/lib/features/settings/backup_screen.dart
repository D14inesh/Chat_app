/// "Chat backup" — turn on a password-locked backup of the chats, back up
/// now / automatically, change the password, restore on a new phone, or turn
/// it off (the website's Settings → Chat backup). See core/chat_backup.dart.
library backup_screen;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/chat_backup.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';

ChatBackup _service(WidgetRef ref) {
  final session = ref.read(sessionControllerProvider);
  return ChatBackup(session.api, session.user!.id);
}

String _size(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String backupLine(BackupInfo? b) => b == null
    ? 'No backup yet.'
    : 'Last backup: ${DateFormat('d MMM y, h:mm a').format(b.createdAt)} · ${b.messageCount} messages · ${_size(b.size)}'
        '${b.device.isNotEmpty ? ' · from ${b.device}' : ''}';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});
  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  BackupInfo? _info;
  BackupConf? _conf;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = _service(ref);
    final results = await Future.wait([s.info(), s.conf()]);
    if (!mounted) return;
    setState(() {
      _info = results[0] as BackupInfo?;
      _conf = results[1] as BackupConf?;
      _loading = false;
    });
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } on WrongBackupPassword {
      _toast('Wrong backup password.');
    } catch (e) {
      _toast(e is BackupException ? e.message : 'Something went wrong: $e');
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _backUpNow() => _run(() async {
        final s = _service(ref);
        if (await s.backUpNow()) {
          _toast('Chats backed up.');
        } else {
          _toast('The backup was locked with a different password on another device. Enter that password to continue.');
          await s.setConf(null);
          final info = await s.info();
          if (mounted) await showRestoreBackupDialog(context, ref, info);
        }
      });

  Future<void> _setPassword({bool change = false, bool replace = false}) async {
    final pw = await _askNewPassword(context, change: change);
    if (pw == null) return;
    await _run(() async {
      await _service(ref).setPassword(pw, change: change, replace: replace);
      _toast(change ? 'Backup password changed.' : 'Backup is on. Your chats are backed up.');
    });
  }

  Future<void> _turnOff() async {
    final ok = await _confirm(context, 'Turn off backup?',
        "The backup will be deleted. Messages on this phone stay, but they won't be backed up any more.", 'Turn off');
    if (!ok) return;
    await _run(() async {
      await _service(ref).turnOff();
      _toast('Backup turned off and deleted.');
    });
  }

  Future<void> _startNew() async {
    final ok = await _confirm(context, 'Start a new backup?',
        'The old backup will be replaced with a new password, and anything only in it will be lost.', 'Continue');
    if (ok) await _setPassword(replace: true);
  }

  @override
  Widget build(BuildContext context) {
    final conf = _conf;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat backup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  "Your chats are backed up locked with a password only you know. Nobody else can open the backup "
                  "— and if you forget the password, your chats can't be restored.",
                  style: TextStyle(color: VeyonColors.muted),
                ),
                const SizedBox(height: 16),
                Card(
                  elevation: 0,
                  child: Padding(padding: const EdgeInsets.all(14), child: Text(backupLine(_info))),
                ),
                const SizedBox(height: 12),
                if (_busy) const LinearProgressIndicator(),
                if (conf != null) ...[
                  ListTile(
                    title: const Text('Back up automatically'),
                    trailing: DropdownButton<String>(
                      value: conf.freq,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 'daily', child: Text('Daily')),
                        DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                        DropdownMenuItem(value: 'off', child: Text('Off')),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) async {
                              if (v == null) return;
                              await _service(ref).setConf(conf.copyWith(freq: v));
                              _load();
                            },
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: _busy ? null : _backUpNow, child: const Text('Back up now')),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _busy ? null : () => _setPassword(change: true), child: const Text('Change password')),
                  const SizedBox(height: 8),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: VeyonColors.danger),
                    onPressed: _busy ? null : _turnOff,
                    child: const Text('Turn off backup'),
                  ),
                ] else if (_info != null) ...[
                  const Text('A backup of your chats was found. Restore it on this phone with your backup password.',
                      style: TextStyle(color: VeyonColors.muted)),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await showRestoreBackupDialog(context, ref, _info);
                            _load();
                          },
                    child: const Text('Restore'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _busy ? null : _startNew, child: const Text('Start a new backup')),
                ] else
                  FilledButton(onPressed: _busy ? null : () => _setPassword(), child: const Text('Turn on backup')),
              ],
            ),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    ) ??
    false;

/// New backup password, typed twice. Null when cancelled.
Future<String?> _askNewPassword(BuildContext context, {bool change = false}) {
  final a = TextEditingController();
  final b = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(change ? 'New backup password' : 'Create a backup password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "At least 8 characters. Write it down somewhere safe — it can't be reset, and without it the backup can't be opened.",
              style: TextStyle(color: VeyonColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(controller: a, obscureText: true, decoration: const InputDecoration(labelText: 'Backup password')),
            const SizedBox(height: 8),
            TextField(controller: b, obscureText: true, decoration: const InputDecoration(labelText: 'Type it again')),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: const TextStyle(color: VeyonColors.danger)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (a.text.length < 8) return setState(() => error = 'Use at least 8 characters.');
              if (a.text != b.text) return setState(() => error = "The two passwords don't match.");
              Navigator.pop(ctx, a.text);
            },
            child: Text(change ? 'Change & back up' : 'Turn on & back up'),
          ),
        ],
      ),
    ),
  );
}

/// Enter the backup password to restore (Chat backup screen, or the first
/// sign-in on this phone). Returns true when restored.
Future<bool> showRestoreBackupDialog(BuildContext context, WidgetRef ref, BackupInfo? info, {bool firstRun = false}) async {
  final pw = TextEditingController();
  final restored = await showDialog<int>(
    context: context,
    barrierDismissible: !firstRun,
    builder: (ctx) {
      String? error;
      var busy = false;
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(firstRun ? 'Restore your chats?' : 'Restore backup'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(backupLine(info), style: const TextStyle(color: VeyonColors.muted, fontSize: 13)),
              const SizedBox(height: 8),
              const Text('Enter your backup password to bring your messages back to this phone.'),
              const SizedBox(height: 12),
              TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Backup password')),
              if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: VeyonColors.danger)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: Text(firstRun ? 'Skip' : 'Cancel')),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final n = await _service(ref).restore(pw.text);
                        if (ctx.mounted) Navigator.pop(ctx, n);
                      } on WrongBackupPassword {
                        setState(() {
                          busy = false;
                          error = 'Wrong backup password.';
                        });
                      } catch (e) {
                        setState(() {
                          busy = false;
                          error = e is BackupException ? e.message : 'Could not restore: $e';
                        });
                      }
                    },
              child: const Text('Restore'),
            ),
          ],
        ),
      );
    },
  );
  if (restored == null) return false;
  ref.read(conversationsProvider.notifier).refresh();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restored $restored messages.')));
  }
  return true;
}
