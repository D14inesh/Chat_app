/// Group extras shared by the chat and info screens — the phone side of the
/// website's js/features/groups.js: adding members with the group key,
/// reply privately, @everyone, invite links and communities.
library group_tools;

import 'package:veyon_chat_mobile/features/account/birth_date.dart';
import 'package:veyon_chat_mobile/core/bubble_ink.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/avatar.dart';
import '../../core/crypto/identity.dart';
import '../../core/crypto/jwk.dart';
import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../models/conversation.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../chat/chat_screen.dart';
import '../conversations/conversations_provider.dart';

String errText(Object e) => e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), '');

/// Wraps the group's key for each user ({id, publicKey}) and adds them —
/// only a member's app can do this (it holds the key).
Future<void> addMembersWithKey(Session session, Conversation c, Iterable<Map<String, dynamic>> users) async {
  final contentKey = await resolveConversationKey(session, c);
  final raw = Uint8List.fromList(await contentKey.extractBytes());
  for (final u in users) {
    final pub = u['publicKey'];
    if (pub == null) continue;
    final wrapKey = await deriveWrapKey(session.identityKeyPair!, EcPublicJwk.fromJson(Map<String, dynamic>.from(pub as Map)));
    final wrapped = await wrapContentKey(wrapKey, raw);
    await session.api.addMember(c.id, userId: u['id'] as String, wrappedKey: wrapped.wrappedKey, wrappedIv: wrapped.wrappedIv);
  }
}

/// A new group with just me in it (a community's announcements group).
Future<String> createSoloGroup(Session session, String title) async {
  final pair = session.identityKeyPair!;
  final (_, raw) = await generateContentKey();
  final mine = await wrapContentKey(await deriveWrapKey(pair, await exportPublicKey(pair)), raw);
  final json = await session.api.createGroup(title: title, avatarColor: '#7C5CFF', members: [
    {'userId': session.user!.id, 'wrappedKey': mine.wrappedKey, 'wrappedIv': mine.wrappedIv},
  ]);
  return json['id'] as String;
}

Future<void> openChatById(BuildContext context, WidgetRef ref, String id) async {
  final notifier = ref.read(conversationsProvider.notifier);
  var c = notifier.byId(id);
  if (c == null) {
    await notifier.refresh();
    c = notifier.byId(id);
  }
  if (c != null && context.mounted) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: c!)));
  }
}

Future<void> openDirectWith(BuildContext context, WidgetRef ref, String userId) async {
  if (!await privateChatGate()) return; // private chats are 18+
  final json = await ref.read(sessionControllerProvider).api.openDirectConversation(userId);
  final c = Conversation.fromJson(json);
  ref.read(conversationsProvider.notifier).refresh();
  if (context.mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: c)));
}

// ── @everyone ───────────────────────────────────────────────

final _everyone = RegExp(r'(^|\s)@everyone\b', caseSensitive: false);
bool mentionsEveryone(String text) => _everyone.hasMatch(text);

/// Text with "@everyone" highlighted (only when the message really is one).
InlineSpan everyoneSpan(String text, TextStyle style, {required bool active, required Color accent}) {
  if (!active) return TextSpan(text: text, style: style);
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in RegExp(r'@everyone\b', caseSensitive: false).allMatches(text)) {
    spans.add(TextSpan(text: text.substring(last, m.start)));
    spans.add(TextSpan(
      text: m.group(0),
      style: TextStyle(fontWeight: FontWeight.w800, color: accent, backgroundColor: accent.withValues(alpha: 0.16)),
    ));
    last = m.end;
  }
  spans.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: style, children: spans);
}

// ── Reply privately ─────────────────────────────────────────

const _pr = '⁣PR';
const _end = '⁣';

/// {quote: {group, groupId, sender, snippet}, text} for a private reply, else null.
({Map<String, dynamic> quote, String text})? splitPrivateReply(String? plain) {
  if (plain == null || !plain.startsWith(_pr)) return null;
  final end = plain.indexOf(_end, _pr.length);
  if (end < 0) return null;
  try {
    return (quote: jsonDecode(plain.substring(_pr.length, end)) as Map<String, dynamic>, text: plain.substring(end + 1));
  } catch (_) {
    return null;
  }
}

String textOf(String plain) => splitPrivateReply(plain)?.text ?? plain;

String packPrivateReply(Map<String, dynamic> quote, String text) => '$_pr${jsonEncode(quote)}$_end$text';

/// Chat id -> quote waiting to go with the next message typed there.
final pendingPrivateQuoteProvider = StateProvider<Map<String, Map<String, dynamic>>>((ref) => {});

class PrivateQuote extends StatelessWidget {
  final Map<String, dynamic> quote;
  final bool mine;
  const PrivateQuote({super.key, required this.quote, this.mine = false});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: mine ? BubbleInk.dim(context) : accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline_rounded, size: 12, color: BubbleInk.dim(context)),
            const SizedBox(width: 4),
            Flexible(
              child: Text('${quote['sender']} · ${quote['group']}',
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: BubbleInk.dim(context))),
            ),
          ]),
          Text('${quote['snippet']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: BubbleInk.dim(context))),
        ],
      ),
    );
  }
}

// ── Invite links ────────────────────────────────────────────

String? inviteCodeFrom(String text) {
  final t = text.trim();
  final m = RegExp(r'[#?&]join=([A-Za-z0-9_-]{6,40})').firstMatch(t) ?? RegExp(r'^([A-Za-z0-9_-]{6,40})$').firstMatch(t);
  return m?.group(1);
}

Future<void> showJoinWithLink(BuildContext context, WidgetRef ref) async {
  final ctrl = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Join a group with a link'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Invite link', hintText: 'Paste the link here')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, inviteCodeFrom(ctrl.text) ?? ''), child: const Text('Continue')),
      ],
    ),
  );
  if (code == null || !context.mounted) return;
  if (code.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That doesn’t look like an invite link.')));
    return;
  }
  final api = ref.read(sessionControllerProvider).api;
  Map<String, dynamic> g;
  try {
    g = Map<String, dynamic>.from((await api.getJson('/api/invite/$code'))['group'] as Map);
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errText(e))));
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Avatar(label: g['title'] as String, color: g['avatarColor'] as String?, radius: 40),
          const SizedBox(height: 12),
          Text(g['title'] as String, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Text('Group · ${g['memberCount']} members', style: const TextStyle(color: VeyonColors.muted)),
          if ((g['description'] as String? ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(g['description'] as String, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 14),
          Text(
            g['isMember'] == true
                ? 'You’re already in this group.'
                : g['requested'] == true
                    ? 'Your request was sent — an admin will let you in.'
                    : 'An admin approves new members. The group appears in your chats once they do.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: VeyonColors.muted),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: g['isMember'] == true
                ? FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      openChatById(context, ref, g['id'] as String);
                    },
                    child: const Text('Open group'))
                : g['requested'] == true
                    ? OutlinedButton(
                        onPressed: () async {
                          await api.deleteJson('/api/conversations/${g['id']}/join-request').catchError((_) => <String, dynamic>{});
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('Cancel request'))
                    : FilledButton(
                        onPressed: () async {
                          try {
                            await api.postJson('/api/invite/$code/request');
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Request sent — you’ll be added when an admin approves.')));
                            }
                          } catch (e) {
                            if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(errText(e))));
                          }
                        },
                        child: const Text('Ask to join')),
          ),
        ]),
      ),
    ),
  );
}

// ── Communities ─────────────────────────────────────────────

class CommunitiesScreen extends ConsumerStatefulWidget {
  const CommunitiesScreen({super.key});
  @override
  ConsumerState<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends ConsumerState<CommunitiesScreen> {
  List<Map<String, dynamic>>? _items;
  String? _error;

  Session get _session => ref.read(sessionControllerProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _session.api.getJson('/api/communities');
      final items = (res['communities'] as List).cast<Map<String, dynamic>>();
      if (mounted) setState(() => _items = items);
      for (final c in items) {
        if (c['isAdmin'] == true) _sync(c['id'] as String, loud: false);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load communities — check your connection.');
    }
  }

  /// Puts everyone from the community's groups into its announcements group.
  Future<void> _sync(String id, {required bool loud}) async {
    try {
      final res = await _session.api.getJson('/api/communities/$id/missing-members');
      final members = (res['members'] as List).cast<Map<String, dynamic>>();
      final ann = ref.read(conversationsProvider.notifier).byId(res['announcementId'] as String? ?? '');
      if (ann == null || members.isEmpty) {
        if (loud) _toast('Everyone is already in the announcements group.');
        return;
      }
      await addMembersWithKey(_session, ann, members);
      if (loud) _toast('Added ${members.length} to announcements.');
    } catch (e) {
      if (loud) _toast(errText(e));
    }
  }

  void _toast(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  List<Conversation> _myAdminGroups() => (ref.read(conversationsProvider).valueOrNull ?? const <Conversation>[])
      .where((c) => c.iAmAdmin && c.communityId == null)
      .toList();

  Future<void> _create() async {
    final name = TextEditingController();
    final desc = TextEditingController();
    final groups = _myAdminGroups();
    final picked = <String>{};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                const Text('New community', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 12),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
                const SizedBox(height: 16),
                const Text('Groups to include', style: TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w700)),
                if (groups.isEmpty)
                  const Padding(padding: EdgeInsets.all(12), child: Text('No groups you admin yet — you can add them later.', style: TextStyle(color: VeyonColors.muted))),
                for (final g in groups)
                  CheckboxListTile(
                    value: picked.contains(g.id),
                    onChanged: (v) => setSheet(() => v == true ? picked.add(g.id) : picked.remove(g.id)),
                    secondary: Avatar(label: g.title ?? 'Group', color: g.avatarColor),
                    title: Text(g.title ?? 'Group'),
                  ),
                const SizedBox(height: 8),
                const Text('An “Announcements” group is created — everyone in the groups is added, and only admins can post.',
                    style: TextStyle(color: VeyonColors.muted, fontSize: 12.5)),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
              ]),
            ),
          ),
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      final annId = await createSoloGroup(_session, '${name.text.trim()} · Announcements');
      final res = await _session.api.postJson('/api/communities', {
        'name': name.text.trim(),
        'description': desc.text.trim(),
        'announcementConversationId': annId,
        'groupIds': picked.toList(),
      });
      await ref.read(conversationsProvider.notifier).refresh();
      await _sync((res['community'] as Map)['id'] as String, loud: false);
      _toast('Community “${name.text.trim()}” created.');
      _load();
    } catch (e) {
      _toast(errText(e));
    }
  }

  Future<void> _manage(Map<String, dynamic> c) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.group_add_rounded), title: const Text('Add a group'), onTap: () => Navigator.pop(ctx, 'link')),
          ListTile(leading: const Icon(Icons.campaign_rounded), title: const Text('Add everyone to announcements'), onTap: () => Navigator.pop(ctx, 'sync')),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: VeyonColors.danger),
            title: const Text('Delete community', style: TextStyle(color: VeyonColors.danger)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    final id = c['id'] as String;
    if (act == null || !mounted) return;
    try {
      if (act == 'sync') await _sync(id, loud: true);
      if (act == 'delete' && mounted) {
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete “${c['name']}”?'),
            content: const Text('Its groups carry on as ordinary groups.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: VeyonColors.danger))),
            ],
          ),
        );
        if (yes == true) await _session.api.deleteJson('/api/communities/$id');
      }
      if (act == 'link') {
        final linked = (c['groups'] as List).map((g) => g['id']).toSet();
        final options = _myAdminGroups().where((g) => !linked.contains(g.id)).toList();
        if (options.isEmpty) {
          _toast('You have no other groups you admin to add.');
          return;
        }
        if (!mounted) return;
        final gid = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: ListView(shrinkWrap: true, children: [
              for (final g in options)
                ListTile(
                  leading: Avatar(label: g.title ?? 'Group', color: g.avatarColor),
                  title: Text(g.title ?? 'Group'),
                  onTap: () => Navigator.pop(ctx, g.id),
                ),
            ]),
          ),
        );
        if (gid == null) return;
        await _session.api.postJson('/api/communities/$id/groups', {'conversationId': gid});
        await ref.read(conversationsProvider.notifier).refresh();
        await _sync(id, loud: false);
        _toast('Group added to the community.');
      }
      _load();
    } catch (e) {
      _toast(errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final accent = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      appBar: AppBar(title: const Text('Communities')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New community'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
          children: [
            if (_error != null) Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center)),
            if (items == null && _error == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            if (items != null && items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 70),
                child: Column(children: [
                  Icon(Icons.groups_rounded, size: 60, color: accent.withValues(alpha: 0.6)),
                  const SizedBox(height: 12),
                  const Text('You’re not in any community yet.', style: TextStyle(color: VeyonColors.muted)),
                  const SizedBox(height: 4),
                  const Text('Bring related groups together, with announcements\nonly admins can post.',
                      textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted, fontSize: 12.5)),
                ]),
              ),
            for (final c in items ?? const <Map<String, dynamic>>[])
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
                  child: Column(children: [
                    Row(children: [
                      Container(
                        width: 46,
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: _hex(c['avatarColor'] as String?), borderRadius: BorderRadius.circular(14)),
                        child: Text(_initials(c['name'] as String), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                          Text(
                            '${(c['groups'] as List).length} groups${(c['description'] as String).isNotEmpty ? ' · ${c['description']}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: VeyonColors.muted, fontSize: 12.5),
                          ),
                        ]),
                      ),
                      if (c['isAdmin'] == true) IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () => _manage(c)),
                    ]),
                    const Divider(color: VeyonColors.hairline),
                    for (final g in (c['groups'] as List).cast<Map<String, dynamic>>())
                      ListTile(
                        contentPadding: const EdgeInsets.only(left: 4, right: 8),
                        leading: g['isAnnouncement'] == true
                            ? CircleAvatar(backgroundColor: accent.withValues(alpha: 0.18), child: Icon(Icons.campaign_rounded, color: accent))
                            : Avatar(label: g['title'] as String, color: g['avatarColor'] as String?),
                        title: Text(g['isAnnouncement'] == true ? 'Announcements' : g['title'] as String),
                        subtitle: Text('${g['memberCount']} members', style: const TextStyle(color: VeyonColors.muted)),
                        trailing: g['isMember'] == true
                            ? TextButton(onPressed: () => openChatById(context, ref, g['id'] as String), child: const Text('Open'))
                            : g['requested'] == true
                                ? const Text('Requested', style: TextStyle(color: VeyonColors.muted))
                                : TextButton(
                                    onPressed: () async {
                                      try {
                                        await _session.api.postJson('/api/conversations/${g['id']}/join-request');
                                        _toast('Request sent to the group’s admins.');
                                        _load();
                                      } catch (e) {
                                        _toast(errText(e));
                                      }
                                    },
                                    child: const Text('Ask to join'),
                                  ),
                      ),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _initials(String s) {
  final parts = s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts[1][0] : '')).toUpperCase();
}

Color _hex(String? hex) {
  final h = (hex ?? '#6C5CE7').replaceFirst('#', '');
  return Color(int.tryParse('FF$h', radix: 16) ?? 0xFF6C5CE7);
}
