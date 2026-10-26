import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/avatar.dart';
import '../../theme.dart';
import '../auth/session.dart';
import 'status_composer_screen.dart';
import 'status_provider.dart';
import 'status_viewer_screen.dart';

/// The Status tab: your own status first, then updates you haven't seen,
/// then the ones you have — like the website's Status page.
class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key});
  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  @override
  void initState() {
    super.initState();
    // Statuses aren't pushed live; fetch whenever the tab is opened.
    Future.microtask(() => ref.read(statusProvider.notifier).refresh());
  }

  Future<void> _compose() async {
    final posted = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const StatusComposerScreen()));
    if (posted == true) ref.read(statusProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(statusProvider);
    final me = ref.watch(sessionControllerProvider).user;
    final groups = groupsAsync.valueOrNull ?? const <StatusGroup>[];
    final mine = groups.where((g) => g.isMine).firstOrNull;
    final others = groups.where((g) => !g.isMine).toList()
      ..sort((a, b) => _latest(b).compareTo(_latest(a)));
    final recent = others.where((g) => !g.allViewed).toList();
    final viewed = others.where((g) => g.allViewed).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Status')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New status',
        onPressed: _compose,
        child: const Icon(Icons.edit_rounded),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(statusProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            _StatusRow(
              ring: mine == null ? _Ring.none : _Ring.seen,
              avatar: Avatar(label: me?.displayName ?? '', color: me?.avatarColor, photoUrl: me?.photoUrl, radius: 25),
              addBadge: true,
              title: mine == null ? 'Add status' : 'My status',
              subtitle: mine == null
                  ? 'Share a photo, video or text for 24 hours'
                  : '${mine.statuses.length} update${mine.statuses.length == 1 ? '' : 's'} · ${_ago(_latest(mine))}',
              onTap: mine == null
                  ? _compose
                  : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StatusViewerScreen(group: mine))),
              onLongPress: _compose,
            ),
            if (recent.isNotEmpty) const _Section('Recent updates'),
            for (final g in recent) _posterRow(context, g),
            if (viewed.isNotEmpty) const _Section('Viewed updates'),
            for (final g in viewed) _posterRow(context, g),
            if (others.isEmpty && groupsAsync is! AsyncLoading)
              const Padding(
                padding: EdgeInsets.fromLTRB(32, 40, 32, 0),
                child: Text('No updates from your contacts yet.',
                    textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _posterRow(BuildContext context, StatusGroup g) {
    final mentioned = g.statuses.any((s) => s['mentionsMe'] == true);
    return _StatusRow(
      ring: g.allViewed ? _Ring.seen : _Ring.unseen,
      avatar: Avatar(label: g.posterName, color: g.posterColor, photoUrl: g.posterPhotoUrl, radius: 25),
      title: g.posterName,
      subtitle: mentioned ? 'Mentioned you · ${_ago(_latest(g))}' : _ago(_latest(g)),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => StatusViewerScreen(group: g)));
        ref.read(statusProvider.notifier).refresh();
      },
    );
  }

  static String _latest(StatusGroup g) =>
      g.statuses.map((s) => s['createdAt'] as String? ?? '').fold('', (a, b) => b.compareTo(a) > 0 ? b : a);

  static String _ago(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return 'yesterday';
  }
}

enum _Ring { none, seen, unseen }

class _StatusRow extends StatelessWidget {
  final _Ring ring;
  final Widget avatar;
  final bool addBadge;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _StatusRow({
    required this.ring,
    required this.avatar,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.addBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).scaffoldBackgroundColor;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _StatusRingView(ring: ring, gap: surface, child: avatar),
                if (addBadge)
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: VeyonColors.bubbleMe,
                        shape: BoxShape.circle,
                        border: Border.all(color: surface, width: 2.5),
                      ),
                      child: const Icon(Icons.add_rounded, size: 14, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 13, color: VeyonColors.muted), overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin ring around an avatar: gradient while there's something new,
/// a soft grey once seen, nothing at all when there's no status.
class _StatusRingView extends StatelessWidget {
  final _Ring ring;
  final Color gap;
  final Widget child;
  const _StatusRingView({required this.ring, required this.gap, required this.child});

  @override
  Widget build(BuildContext context) {
    if (ring == _Ring.none) return Padding(padding: const EdgeInsets.all(5), child: child);
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: ring == _Ring.unseen ? VeyonColors.statusRing : null,
        color: ring == _Ring.seen ? VeyonColors.line : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(shape: BoxShape.circle, color: gap),
        child: child,
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
        child: Text(text,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Theme.of(context).brightness == Brightness.dark ? VeyonColors.bubbleMe2 : VeyonColors.bubbleMe)),
      );
}
