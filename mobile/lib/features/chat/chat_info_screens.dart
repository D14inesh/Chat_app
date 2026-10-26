/// Contact info (direct chats) and Group info — the mobile versions of the
/// website's openContactInfo() / openGroupInfo() / openAddMember().
library chat_info_screens;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/avatar.dart';
import '../../core/config.dart';
import '../../core/crypto/jwk.dart';
import '../../core/crypto/keys.dart';
import '../../models/conversation.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../blocked/blocked_provider.dart';
import '../business/business_profile.dart';
import '../conversations/chat_list_actions.dart';
import '../conversations/conversations_provider.dart';
import '../groups/group_tools.dart';
import '../presence/presence_provider.dart';
import '../calls/calls_extras.dart';

/// What the chat screen should do after an info screen closes.
enum InfoResult { search, chatGone, cleared }

Future<void> showSafetyNumber(BuildContext context, Session session, Conversation c) async {
  final mine = session.user?.publicKey;
  final theirs = c.peer?.publicKey;
  if (mine == null || theirs == null) return;
  final number = await safetyNumber(EcPublicJwk.fromJson(mine), EcPublicJwk.fromJson(theirs));
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Safety number with ${c.peer!.displayName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(number, style: const TextStyle(fontSize: 20, letterSpacing: 1.5, fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(height: 14),
          const Text(
            'Compare this with them over a channel you already trust (in person, a phone call). '
            'If it matches on both sides, nobody is intercepting this conversation.',
            style: TextStyle(color: VeyonColors.muted, fontSize: 13),
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}

/// Shared confirm-then-act helpers, used by both the chat menu and these screens.
Future<bool> confirmAction(BuildContext context, String title, String body, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok, style: TextStyle(color: danger ? VeyonColors.danger : null)),
        ),
      ],
    ),
  );
  return r == true;
}

/// Runs a quick server change; shows the error only if this screen is still open.
Future<void> _guarded(BuildContext context, Future<void> action) async {
  try {
    await action;
  } catch (e) {
    if (context.mounted) _toast(context, _errText(e));
  }
}

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String _errText(Object e) => e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), '');

// ── Contact info ─────────────────────────────────────────────────────

class ContactInfoScreen extends ConsumerWidget {
  final String conversationId;
  final Conversation fallback;
  const ContactInfoScreen({super.key, required this.conversationId, required this.fallback});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(conversationsProvider);
    final c = ref.read(conversationsProvider.notifier).byId(conversationId) ?? fallback;
    final peer = c.peer!;
    final session = ref.watch(sessionControllerProvider);
    final presence = ref.watch(presenceProvider);
    final blocked = ref.watch(blockedProvider).any((u) => u.id == peer.id);
    final online = presence.online.contains(peer.id);

    return Scaffold(
      appBar: AppBar(title: const Text('Contact info')),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          Center(child: Avatar(label: peer.displayName, color: peer.avatarColor, photoUrl: peer.photoUrl, radius: 52)),
          const SizedBox(height: 12),
          Center(child: Text(peer.displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
          Center(child: Text('@${peer.username}', style: const TextStyle(color: VeyonColors.muted))),
          const SizedBox(height: 4),
          Center(
            child: Text(
              online ? 'online' : lastSeenLabel(presence.lastSeen[peer.id] ?? peer.lastSeen),
              style: TextStyle(color: online ? const Color(0xFF2ECC71) : VeyonColors.muted, fontSize: 12.5),
            ),
          ),
          const SizedBox(height: 18),
          ListTile(
            title: const Text('About', style: TextStyle(color: VeyonColors.muted, fontSize: 12.5)),
            subtitle: Text(peer.about.isEmpty ? 'Available' : peer.about, style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
          BusinessInfoCard(userId: peer.id),
          const Divider(color: VeyonColors.hairline),
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('Verify encryption'),
            subtitle: const Text('Compare your safety number'),
            onTap: () => showSafetyNumber(context, session, c),
          ),
          ListTile(
            leading: Icon(c.favorite ? Icons.star_rounded : Icons.star_border_rounded, color: Colors.amber),
            title: Text(c.favorite ? 'Remove from favourites' : 'Add to favourites'),
            onTap: () => _guarded(context, ref.read(conversationsProvider.notifier).setFavorite(c.id, !c.favorite)),
          ),
          ListTile(
            leading: Icon(c.muted ? Icons.notifications_off_rounded : Icons.notifications_none_rounded),
            title: Text(c.muted ? 'Unmute notifications' : 'Mute notifications'),
            subtitle: mutedUntilLabel(c) == null ? null : Text(mutedUntilLabel(c)!),
            onTap: () => chooseMute(context, ref, c),
          ),
          ListTile(
            leading: const Icon(Icons.search_rounded),
            title: const Text('Search in chat'),
            onTap: () => Navigator.pop(context, InfoResult.search),
          ),
          ListTile(
              leading: const Icon(Icons.music_note_rounded),
              title: const Text('Ringtone'),
              subtitle: Text(
                '${kRingtones[ringtoneFor(peer.id)]!.name}${ringtoneOverride(peer.id) == null ? ' (default)' : ''}',
                style: const TextStyle(color: VeyonColors.muted),
              ),
              onTap: () => showRingtonePicker(context, userId: peer.id, name: peer.displayName),
            ),
          const Divider(color: VeyonColors.hairline),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined, color: VeyonColors.danger),
            title: const Text('Clear chat', style: TextStyle(color: VeyonColors.danger)),
            onTap: () async {
              if (await clearChatFlow(context, ref, c) && context.mounted) Navigator.pop(context, InfoResult.cleared);
            },
          ),
          ListTile(
            leading: const Icon(Icons.block_rounded, color: VeyonColors.danger),
            title: Text(blocked ? 'Unblock ${peer.displayName}' : 'Block ${peer.displayName}',
                style: const TextStyle(color: VeyonColors.danger)),
            onTap: () => toggleBlockFlow(context, ref, c),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: VeyonColors.danger),
            title: const Text('Delete chat', style: TextStyle(color: VeyonColors.danger)),
            onTap: () async {
              if (await deleteChatFlow(context, ref, c) && context.mounted) Navigator.pop(context, InfoResult.chatGone);
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

Future<bool> clearChatFlow(BuildContext context, WidgetRef ref, Conversation c) async {
  final ok = await confirmAction(context, 'Clear chat',
      'Clear all messages in this chat? This only clears your own view — nothing changes for the other side.',
      ok: 'Clear', danger: true);
  if (!ok) return false;
  try {
    await ref.read(sessionControllerProvider).api.clearChat(c.id);
    ref.read(conversationsProvider.notifier).refresh();
    if (context.mounted) _toast(context, 'Chat cleared.');
    return true;
  } catch (e) {
    if (context.mounted) _toast(context, _errText(e));
    return false;
  }
}

Future<bool> deleteChatFlow(BuildContext context, WidgetRef ref, Conversation c) async {
  final ok = await confirmAction(context, 'Delete chat',
      'Delete your chat with ${c.displayName('them')}? It\'ll disappear from your list until they message you again.',
      ok: 'Delete', danger: true);
  if (!ok) return false;
  try {
    await ref.read(sessionControllerProvider).api.deleteChat(c.id);
    ref.read(conversationsProvider.notifier).remove(c.id);
    if (context.mounted) _toast(context, 'Chat deleted.');
    return true;
  } catch (e) {
    if (context.mounted) _toast(context, _errText(e));
    return false;
  }
}

Future<void> toggleBlockFlow(BuildContext context, WidgetRef ref, Conversation c) async {
  final peer = c.peer;
  if (peer == null) return;
  final isBlocked = ref.read(blockedProvider).any((u) => u.id == peer.id);
  final ok = await confirmAction(
    context,
    isBlocked ? 'Unblock ${peer.displayName}?' : 'Block ${peer.displayName}?',
    isBlocked
        ? 'They\'ll be able to message and call you again.'
        : 'They won\'t be able to message or call you, and you won\'t be able to message or call them.',
    ok: isBlocked ? 'Unblock' : 'Block',
    danger: !isBlocked,
  );
  if (!ok) return;
  try {
    if (isBlocked) {
      await ref.read(blockedProvider.notifier).unblock(peer.id);
    } else {
      await ref.read(blockedProvider.notifier).block(peer);
    }
    if (context.mounted) _toast(context, isBlocked ? '${peer.displayName} unblocked.' : '${peer.displayName} blocked.');
  } catch (e) {
    if (context.mounted) _toast(context, _errText(e));
  }
}

// ── Group info ───────────────────────────────────────────────────────

class GroupInfoScreen extends ConsumerStatefulWidget {
  final Conversation conversation;
  const GroupInfoScreen({super.key, required this.conversation});

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  List<Map<String, dynamic>>? _members;
  List<Map<String, dynamic>> _requests = const [];
  String? _error;
  bool _busy = false;

  Session get _session => ref.read(sessionControllerProvider);
  Conversation get _live => ref.read(conversationsProvider.notifier).byId(widget.conversation.id) ?? widget.conversation;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = (await _session.api.listMembers(widget.conversation.id)).cast<Map<String, dynamic>>();
      final myRole = m.firstWhere((x) => x['id'] == _session.user!.id, orElse: () => const {'role': 'member'})['role'] as String;
      ref.read(conversationsProvider.notifier).patch(widget.conversation.id, (c) => c.copyWith(myRole: myRole));
      var requests = const <Map<String, dynamic>>[];
      if (myRole == 'owner' || myRole == 'admin') {
        requests = ((await _session.api.getJson('/api/conversations/${widget.conversation.id}/join-requests'))['requests'] as List)
            .cast<Map<String, dynamic>>();
        ref.read(conversationsProvider.notifier).patch(widget.conversation.id, (c) => c.copyWith(joinRequests: requests.length));
      }
      if (mounted) {
        setState(() {
          _members = m;
          _requests = requests;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load members — check your connection.');
    }
  }

  Future<void> _settings(Map<String, dynamic> patch) async {
    final res = await _session.api.patchJson('/api/conversations/${widget.conversation.id}/group-settings', patch);
    ref.read(conversationsProvider.notifier).patch(
          widget.conversation.id,
          (c) => c.copyWith(
            title: res['title'] as String?,
            description: res['description'] as String?,
            onlyAdminsSend: res['onlyAdminsSend'] as bool?,
          ),
        );
  }

  Future<void> _edit() async {
    final c = _live;
    final title = TextEditingController(text: c.title);
    final desc = TextEditingController(text: c.description);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit group'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Group name')),
          const SizedBox(height: 12),
          TextField(controller: desc, maxLines: 4, minLines: 2, decoration: const InputDecoration(labelText: 'Description')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && mounted) await _guarded(context, _settings({'title': title.text, 'description': desc.text}));
  }

  Future<void> _invite(String action) async {
    final id = widget.conversation.id;
    try {
      if (action == 'off') {
        await _session.api.deleteJson('/api/conversations/$id/invite');
        ref.read(conversationsProvider.notifier).patch(id, (c) => c.copyWith(clearInvite: true));
      } else {
        final code = (await _session.api.postJson('/api/conversations/$id/invite'))['inviteCode'] as String;
        ref.read(conversationsProvider.notifier).patch(id, (c) => c.copyWith(inviteCode: code));
      }
    } catch (e) {
      if (mounted) _toast(context, _errText(e));
    }
  }

  /// The link opens the website, which shows the join screen.
  String _inviteUrl(String code) => '${AppConfig.webBaseUrl}/#join=$code';

  Future<void> _memberMenu(Map<String, dynamic> m) async {
    final role = _live.myRole;
    final owner = role == 'owner';
    final admin = owner || role == 'admin';
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Avatar(label: m['displayName'] as String, color: m['avatarColor'] as String?, photoUrl: m['photoUrl'] as String?),
            title: Text(m['displayName'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('@${m['username']}'),
          ),
          const Divider(height: 1, color: VeyonColors.hairline),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline_rounded),
            title: Text('Message ${m['displayName']}'),
            onTap: () => Navigator.pop(ctx, 'message'),
          ),
          if (owner && m['role'] == 'member')
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Make group admin'),
              onTap: () => Navigator.pop(ctx, 'promote'),
            ),
          if (owner && m['role'] == 'admin')
            ListTile(
              leading: const Icon(Icons.remove_moderator_outlined),
              title: const Text('Dismiss as admin'),
              onTap: () => Navigator.pop(ctx, 'demote'),
            ),
          if (admin && m['role'] != 'owner' && (owner || m['role'] == 'member'))
            ListTile(
              leading: const Icon(Icons.person_remove_outlined, color: VeyonColors.danger),
              title: Text('Remove ${m['displayName']}', style: const TextStyle(color: VeyonColors.danger)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
        ]),
      ),
    );
    if (act == null || !mounted) return;
    try {
      if (act == 'message') {
        await openDirectWith(context, ref, m['id'] as String);
        return;
      }
      if (act == 'remove') {
        final ok = await confirmAction(context, 'Remove member', 'Remove ${m['displayName']} from "${_live.title}"?', ok: 'Remove', danger: true);
        if (!ok) return;
        await _session.api.removeMember(widget.conversation.id, m['id'] as String);
      } else {
        await _session.api.patchJson(
          '/api/conversations/${widget.conversation.id}/members/${m['id']}/role',
          {'role': act == 'promote' ? 'admin' : 'member'},
        );
      }
      await _load();
    } catch (e) {
      if (mounted) _toast(context, _errText(e));
    }
  }

  Widget _roleTag(String role) {
    final owner = role == 'owner';
    final color = owner ? const Color(0xFFF5A524) : Theme.of(context).colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99)),
      child: Text(owner ? 'OWNER' : 'ADMIN', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: color)),
    );
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w700, fontSize: 12.5, letterSpacing: 0.4),
        ),
      );

  Future<void> _decide(Map<String, dynamic> u, bool approve) async {
    setState(() => _busy = true);
    try {
      if (approve) {
        await addMembersWithKey(_session, _live, [u]);
        if (mounted) _toast(context, '${u['displayName']} joined the group.');
      } else {
        await _session.api.postJson('/api/conversations/${_live.id}/join-requests/${u['id']}/decline');
      }
    } catch (e) {
      if (mounted) _toast(context, _errText(e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(conversationsProvider);
    final c = _live;
    final me = _session.user!.id;
    final members = _members;
    final admin = c.iAmAdmin;
    final online = ref.watch(presenceProvider).online;
    final accent = Theme.of(context).colorScheme.secondary;
    final code = c.inviteCode;

    return Scaffold(
      appBar: AppBar(title: const Text('Group info'), actions: [
        if (admin) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: _edit),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SizedBox(height: 22),
            Center(child: Avatar(label: c.title ?? 'Group', color: c.avatarColor, radius: 50)),
            const SizedBox(height: 12),
            Center(
              child: Text(c.title ?? 'Group', textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ),
            Center(
              child: Text(
                'Group · ${members?.length ?? c.memberCount ?? 0} members${c.isAnnouncement ? ' · Community announcements' : ''}',
                style: const TextStyle(color: VeyonColors.muted),
              ),
            ),
            if (c.description.isNotEmpty || admin)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: InkWell(
                  onTap: admin ? _edit : null,
                  child: Text(
                    c.description.isNotEmpty ? c.description : 'Add a group description',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.description.isNotEmpty ? Colors.white : VeyonColors.muted,
                      height: 1.4,
                      fontStyle: c.description.isNotEmpty ? FontStyle.normal : FontStyle.italic,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(c.favorite ? Icons.star_rounded : Icons.star_border_rounded, color: Colors.amber),
              title: Text(c.favorite ? 'Remove from favourites' : 'Add to favourites'),
              onTap: () => _guarded(context, ref.read(conversationsProvider.notifier).setFavorite(c.id, !c.favorite)),
            ),
            ListTile(
              leading: Icon(c.muted ? Icons.notifications_off_rounded : Icons.notifications_none_rounded),
              title: Text(c.muted ? 'Unmute notifications' : 'Mute notifications'),
              subtitle: mutedUntilLabel(c) == null ? null : Text(mutedUntilLabel(c)!),
              onTap: () => chooseMute(context, ref, c),
            ),
            ListTile(
              leading: const Icon(Icons.search_rounded),
              title: const Text('Search in chat'),
              onTap: () => Navigator.pop(context, InfoResult.search),
            ),
            if (admin) ...[
              const Divider(color: VeyonColors.hairline),
              _section('Group settings'),
              SwitchListTile(
                value: c.onlyAdminsSend,
                onChanged: c.isAnnouncement ? null : (v) => _guarded(context, _settings({'onlyAdminsSend': v})),
                title: const Text('Only admins can send messages'),
                subtitle: const Text('Members can still read, react and vote', style: TextStyle(color: VeyonColors.muted)),
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: (code != null ? accent : Colors.white).withValues(alpha: 0.12),
                  child: Icon(Icons.link_rounded, color: code != null ? accent : VeyonColors.muted),
                ),
                title: const Text('Invite link'),
                subtitle: Text(
                  code == null ? 'Anyone with the link can ask to join — an admin approves' : _inviteUrl(code),
                  maxLines: code == null ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: code == null ? VeyonColors.muted : accent),
                ),
                trailing: code == null ? TextButton(onPressed: () => _invite('make'), child: const Text('Create')) : null,
              ),
              if (code != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(68, 0, 12, 6),
                  child: Wrap(spacing: 8, runSpacing: 4, children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.share_rounded, size: 16),
                      label: const Text('Share'),
                      onPressed: () => Share.share('Join "${c.title}" on Veyon Chat: ${_inviteUrl(code)}'),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _inviteUrl(code)));
                        _toast(context, 'Invite link copied.');
                      },
                    ),
                    TextButton(onPressed: () => _invite('make'), child: const Text('Reset')),
                    TextButton(onPressed: () => _invite('off'), child: const Text('Turn off')),
                  ]),
                ),
            ],
            if (admin && _requests.isNotEmpty) ...[
              const Divider(color: VeyonColors.hairline),
              _section('Asking to join (${_requests.length})'),
              for (final u in _requests)
                ListTile(
                  leading: Avatar(label: u['displayName'] as String, color: u['avatarColor'] as String?, photoUrl: u['photoUrl'] as String?),
                  title: Text(u['displayName'] as String),
                  subtitle: Text('@${u['username']}', style: const TextStyle(color: VeyonColors.muted)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Decline',
                      icon: const Icon(Icons.close_rounded, color: VeyonColors.danger),
                      onPressed: _busy ? null : () => _decide(u, false),
                    ),
                    IconButton(
                      tooltip: 'Approve',
                      icon: const Icon(Icons.check_rounded, color: VeyonColors.online),
                      onPressed: _busy ? null : () => _decide(u, true),
                    ),
                  ]),
                ),
            ],
            const Divider(color: VeyonColors.hairline),
            _section(members == null ? 'Members' : '${members.length} members'),
            if (admin)
              ListTile(
                leading: CircleAvatar(backgroundColor: accent.withValues(alpha: 0.16), child: Icon(Icons.person_add_alt_1_rounded, color: accent)),
                title: const Text('Add members'),
                onTap: _busy || members == null ? null : () => _addMembers(members),
              ),
            if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: VeyonColors.muted))),
            if (members == null && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            for (final m in members ?? const <Map<String, dynamic>>[])
              ListTile(
                onTap: m['id'] == me ? null : () => _memberMenu(m),
                leading: Avatar(
                  label: m['displayName'] as String? ?? '?',
                  color: m['avatarColor'] as String?,
                  photoUrl: m['photoUrl'] as String?,
                  online: online.contains(m['id']),
                ),
                title: Text('${m['displayName']}${m['id'] == me ? ' (you)' : ''}'),
                subtitle: Text('@${m['username']}', style: const TextStyle(color: VeyonColors.muted)),
                trailing: m['role'] == 'member' ? null : _roleTag(m['role'] as String),
              ),
            const Divider(color: VeyonColors.hairline),
            ListTile(
              leading: const Icon(Icons.exit_to_app_rounded, color: VeyonColors.danger),
              title: const Text('Leave group', style: TextStyle(color: VeyonColors.danger)),
              onTap: _busy ? null : _leave,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _leave() async {
    final owner = _live.myRole == 'owner';
    final ok = await confirmAction(
      context,
      'Leave group',
      'Leave "${_live.title}"?${owner ? '\n\nYou’re the owner — the group passes to an admin (or the longest member).' : ''}',
      ok: 'Leave',
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await _session.api.removeMember(widget.conversation.id, _session.user!.id);
      ref.read(conversationsProvider.notifier).remove(widget.conversation.id);
      if (mounted) Navigator.pop(context, InfoResult.chatGone);
    } catch (e) {
      if (mounted) {
        _toast(context, _errText(e));
        setState(() => _busy = false);
      }
    }
  }

  /// Re-wraps the group's content key for each new member — this phone holds
  /// it precisely because it's a member. Same as the website's openAddMember.
  Future<void> _addMembers(List<Map<String, dynamic>> current) async {
    final currentIds = current.map((m) => m['id']).toSet();
    final candidates = (ref.read(conversationsProvider).valueOrNull ?? const <Conversation>[])
        .where((c) => !c.isGroup && c.status == 'accepted' && c.peer != null && !currentIds.contains(c.peer!.id))
        .map((c) => c.peer!)
        .toList();
    if (candidates.isEmpty) {
      _toast(context, 'Everyone in your contacts is already in this group. Share the invite link instead.');
      return;
    }
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final sel = <String>{};
        return StatefulBuilder(
          builder: (ctx, setSheet) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.65,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Add to ${_live.title}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final u in candidates)
                          CheckboxListTile(
                            value: sel.contains(u.id),
                            onChanged: (v) => setSheet(() => v == true ? sel.add(u.id) : sel.remove(u.id)),
                            secondary: Avatar(label: u.displayName, color: u.avatarColor, photoUrl: u.photoUrl),
                            title: Text(u.displayName),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: () => Navigator.pop(ctx, sel), child: const Text('Add')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked == null || picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      await addMembersWithKey(_session, _live, [
        for (final u in candidates.where((u) => picked.contains(u.id))) {'id': u.id, 'publicKey': u.publicKey},
      ]);
      if (mounted) _toast(context, 'Member(s) added.');
      await _load();
    } catch (e) {
      if (mounted) _toast(context, _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
