import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/chat_backup.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../calls/calls_extras.dart';
import '../conversations/conversations_provider.dart';
import '../conversations/conversations_screen.dart';
import '../groups/group_tools.dart';
import '../settings/backup_screen.dart';
import '../status/status_provider.dart';
import '../status/status_screen.dart';

/// The signed-in home: a bottom tab bar over Chats, Status, Calls and
/// Communities. Chats stays alive in the background (its search, filter and
/// scroll position survive a tab switch); the other tabs are built when
/// opened, so e.g. Calls only marks missed calls as seen once you look.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Automatic chat backup when one is due — or, the first time on a new
    // phone, offer to restore the backup.
    Future.delayed(const Duration(seconds: 4), () async {
      if (!mounted) return;
      final session = ref.read(sessionControllerProvider);
      final user = session.user;
      if (user == null) return;
      final offer = await ChatBackup(session.api, user.id).onSignedIn();
      if (offer != null && mounted) await showRestoreBackupDialog(context, ref, offer, firstRun: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(conversationsProvider).valueOrNull ?? const [];
    final unreadChats = chats.where((c) => c.unread > 0 && !c.archived && !c.locked).length;
    final missed = ref.watch(missedCallsProvider);
    final newStatus = (ref.watch(statusProvider).valueOrNull ?? const <StatusGroup>[])
        .any((g) => !g.isMine && !g.allViewed);

    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        body: Stack(
          children: [
            Offstage(
              offstage: _tab != 0,
              child: TickerMode(enabled: _tab == 0, child: const ConversationsScreen()),
            ),
            if (_tab == 1) const StatusScreen(),
            if (_tab == 2) const CallsScreen(),
            if (_tab == 3) const CommunitiesScreen(),
          ],
        ),
        bottomNavigationBar: VeyonDock(
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
          items: [
            DockItem(Icons.forum_outlined, 'Chats', badge: unreadChats > 99 ? '99+' : (unreadChats > 0 ? '$unreadChats' : null)),
            DockItem(Icons.donut_large_rounded, 'Status', dot: newStatus),
            DockItem(Icons.wifi_calling_3_rounded, 'Calls', badge: missed > 0 ? '$missed' : null, alert: true),
            const DockItem(Icons.diversity_3_rounded, 'Groups'),
          ],
        ),
      ),
    );
  }
}

class DockItem {
  final IconData icon;
  final String label;
  final String? badge;
  final bool dot;
  final bool alert;
  const DockItem(this.icon, this.label, {this.badge, this.dot = false, this.alert = false});
}

/// Veyon's tab bar: the same soft surface as the screen, small icons with
/// tiny labels, and only the current tab lit -- a blue-to-cyan pill behind
/// its icon. Same look as the website's navigation rail.
class VeyonDock extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final List<DockItem> items;
  const VeyonDock({super.key, required this.selected, required this.onSelect, required this.items});

  static const glow = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4C6EF5), Color(0xFF3B8CF0), Color(0xFF15AABF)],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(child: _tab(context, items[i], i == selected, () => onSelect(i))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, DockItem item, bool on, VoidCallback onTap) {
    final text = Theme.of(context).colorScheme.onSurface;
    Widget icon = Icon(item.icon, size: 22, color: on ? Colors.white : VeyonColors.muted);
    icon = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: 56,
      height: 32,
      decoration: BoxDecoration(
        gradient: on ? glow : null,
        borderRadius: BorderRadius.circular(99),
        boxShadow: on
            ? [BoxShadow(color: const Color(0xFF3B8CF0).withValues(alpha: 0.5), blurRadius: 12, offset: const Offset(0, 4), spreadRadius: -4)]
            : null,
      ),
      child: Center(child: icon),
    );
    if (item.badge != null) {
      icon = Badge(
        label: Text(item.badge!),
        backgroundColor: item.alert ? VeyonColors.danger : VeyonColors.bubbleMe,
        offset: const Offset(-6, -2),
        child: icon,
      );
    } else if (item.dot) {
      icon = Badge(smallSize: 9, backgroundColor: VeyonColors.online, offset: const Offset(-17, 4), child: icon);
    }
    return Semantics(
      selected: on,
      button: true,
      label: item.label,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: SizedBox(
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(height: 4),
              Text(item.label,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? text : VeyonColors.muted)),
            ],
          ),
        ),
      ),
    );
  }
}
