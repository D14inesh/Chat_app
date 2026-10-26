/// "Blocked contacts" — the website's blocked-users panel.
library blocked_screen;

import '../../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/avatar.dart';
import 'blocked_provider.dart';

class BlockedScreen extends ConsumerStatefulWidget {
  const BlockedScreen({super.key});

  @override
  ConsumerState<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends ConsumerState<BlockedScreen> {
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    ref.read(blockedProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(blockedProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked contacts')),
      body: users.isEmpty
          ? const Center(child: Text('Nobody blocked.', style: TextStyle(color: VeyonColors.muted)))
          : ListView(
              children: [
                for (final u in users)
                  ListTile(
                    leading: Avatar(label: u.displayName, color: u.avatarColor, photoUrl: u.photoUrl),
                    title: Text(u.displayName),
                    subtitle: Text('@${u.username}', style: const TextStyle(color: VeyonColors.muted)),
                    trailing: OutlinedButton(
                      onPressed: _busy.contains(u.id)
                          ? null
                          : () async {
                              setState(() => _busy.add(u.id));
                              try {
                                await ref.read(blockedProvider.notifier).unblock(u.id);
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Could not unblock — check your connection.')));
                                }
                              } finally {
                                if (mounted) setState(() => _busy.remove(u.id));
                              }
                            },
                      child: const Text('Unblock'),
                    ),
                  ),
              ],
            ),
    );
  }
}
