import '../../core/signal/signal_service.dart';
import 'package:veyon_chat_mobile/features/account/birth_date.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/avatar.dart';
import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../core/prefs_store.dart';
import '../../core/local_cache.dart';
import '../../core/storage_clear.dart';
import '../broadcasts/broadcasts_screen.dart';
import '../quickreplies/quick_replies.dart';
import '../security/security_screen.dart';
import '../settings/chat_features_screen.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../theme.dart';
import '../ai/ai_chat_screen.dart';
import '../assistant/voice_assistant.dart';
import '../applock/app_lock_setup_screen.dart';
import '../auth/session.dart';
import '../blocked/blocked_screen.dart';
import '../chat/chat_info_screens.dart';
import '../chat/chat_screen.dart';
import '../games/games_home_screen.dart';
import '../link/qr_scan_link_screen.dart';
import '../labels/labels_provider.dart';
import '../presence/presence_provider.dart';
import '../profile/profile_screen.dart';
import '../reminders/reminders_screen.dart';
import '../chat/message_tools.dart';
import '../settings/backup_screen.dart';
import '../settings/privacy_screen.dart';
import '../settings/storage_screen.dart';
import '../settings/theme_settings_screen.dart';
import '../groups/group_tools.dart';
import '../starred/starred_screen.dart';
import 'chat_list_actions.dart';
import 'conversations_provider.dart';
import 'new_chat_screen.dart';
import 'new_group_screen.dart';
import '../chat/chat3_tools.dart';

/// The chat list — the mobile version of the website's sidebar: filter tabs,
/// search (chats and people), favourites, select-and-act on several chats,
/// and the same overflow menu.
class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});

  @override
  ConsumerState<ConversationsScreen> createState() => _ConversationsScreenState();
}

const _filters = {'all': 'All', 'unread': 'Unread', 'favorites': 'Favourites', 'groups': 'Groups', 'private': 'Private'};
const _emptyHints = {
  'all': 'No conversations yet.\nTap the chat button to find someone.',
  'unread': 'No unread chats.',
  'favorites': 'No favourites yet.\nTap the star on a chat to add one.',
  'groups': 'No group chats yet.',
  'private': 'No private chats yet.',
};

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  String _filter = 'all';
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  String _query = '';
  List<AppUser> _people = [];
  bool _peopleLoading = false;
  Timer? _peopleDebounce;
  final Set<String> _selected = {};
  bool _selectMode = false;
  bool _showArchived = false;

  @override
  void dispose() {
    _peopleDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  void _exitSelect() => setState(() {
        _selected.clear();
        _selectMode = false;
      });

  /// Search all chats: matching messages saved on this phone.
  List<({String conversationId, ChatMessage message})> _messageHits = [];

  Future<void> _searchMessages(String q) async {
    final raw = await LocalCache().searchMessages(q);
    final hits = [
      for (final h in raw)
        (conversationId: h.conversationId, message: ChatMessage.fromJson(h.message)),
    ].where((h) => !h.message.deleted && !isCleared(h.message)).toList();
    if (mounted && _query == q) setState(() => _messageHits = hits);
  }

  void _onSearch(String q) {
    setState(() => _query = q);
    _peopleDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _people = [];
        _messageHits = [];
      });
      return;
    }
    _peopleDebounce = Timer(const Duration(milliseconds: 300), () async {
      _searchMessages(q);
      setState(() => _peopleLoading = true);
      try {
        final raw = await ref.read(sessionControllerProvider).api.searchUsers(q.trim());
        if (mounted) setState(() => _people = raw.map((j) => AppUser.fromJson(j as Map<String, dynamic>)).toList());
      } catch (_) {
        if (mounted) setState(() => _people = []);
      } finally {
        if (mounted) setState(() => _peopleLoading = false);
      }
    });
  }

  Future<void> _openPerson(AppUser peer) async {
    if (!await privateChatGate()) return; // private chats are 18+
    try {
      final json = await ref.read(sessionControllerProvider).api.openDirectConversation(peer.id);
      final conversation = Conversation.fromJson(json);
      ref.read(conversationsProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchCtrl.clear();
        _query = '';
        _people = [];
      });
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
    } catch (_) {
      _toast('Could not open that chat — check your connection.');
    }
  }

  void _onMenu(String v) {
    final nav = Navigator.of(context);
    switch (v) {
      case 'starred':
        nav.push(MaterialPageRoute(builder: (_) => const StarredScreen()));
      case 'select':
        setState(() => _selectMode = true);
      case 'markread':
        final ids = (ref.read(conversationsProvider).valueOrNull ?? const <Conversation>[]).map((c) => c.id);
        final n = ref.read(conversationsProvider.notifier).markRead(ids);
        _toast(n > 0 ? 'All chats marked as read.' : 'Nothing to mark as read.');
      case 'applock':
        nav.push(MaterialPageRoute(builder: (_) => const AppLockSetupScreen()));
      case 'blocked':
        nav.push(MaterialPageRoute(builder: (_) => const BlockedScreen()));
      case 'linkdevice':
        nav.push(MaterialPageRoute(builder: (_) => const QrScanLinkScreen()));
      case 'storage':
        nav.push(MaterialPageRoute(builder: (_) => const StorageScreen()));
      case 'backup':
        nav.push(MaterialPageRoute(builder: (_) => const BackupScreen()));
      case 'privacy':
        nav.push(MaterialPageRoute(builder: (_) => const PrivacyScreen()));
      case 'textsize':
        pickChatTextSize(context);
      case 'reminders':
        nav.push(MaterialPageRoute(builder: (_) => const RemindersScreen()));
      case 'theme':
        nav.push(MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()));
      case 'games':
        nav.push(MaterialPageRoute(builder: (_) => const GamesHomeScreen()));
      case 'broadcasts':
        nav.push(MaterialPageRoute(builder: (_) => const BroadcastsScreen()));
      case 'quickreplies':
        nav.push(MaterialPageRoute(builder: (_) => const QuickRepliesScreen()));
      case 'security':
        nav.push(MaterialPageRoute(builder: (_) => const SecurityScreen()));
      case 'communities':
        nav.push(MaterialPageRoute(builder: (_) => const CommunitiesScreen()));
      case 'joinlink':
        showJoinWithLink(context, ref);
      case 'features':
        nav.push(MaterialPageRoute(builder: (_) => const ChatFeaturesScreen()));
      case 'group':
        nav.push(MaterialPageRoute(builder: (_) => const NewGroupScreen()));
      case 'ai':
        nav.push(MaterialPageRoute(builder: (_) => const AiChatScreen()));
      case 'voice':
        final on = ref.read(voiceAssistantProvider).active;
        ref.read(voiceAssistantProvider.notifier).toggle();
        if (on) _toast('Voice commands off — turn them back on from this menu.'); // turning on shows its own hint
      case 'profile':
        nav.push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
      case 'qr':
        nav.push(MaterialPageRoute(builder: (_) => const QrCodeScreen()));
      case 'logout':
        _confirmLogout();
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await confirmAction(context, 'Sign out', 'Sign out of this phone? Your chats stay on the server.', ok: 'Sign out');
    if (ok) ref.read(sessionControllerProvider.notifier).logout();
  }

  Future<void> _deleteSelected(List<Conversation> chosen) async {
    final ok = await confirmAction(context, 'Delete chats',
        'Delete ${chosen.length} chat${chosen.length == 1 ? '' : 's'}? They\'ll disappear from your list until someone messages you again.',
        ok: 'Delete', danger: true);
    if (!ok) return;
    final api = ref.read(sessionControllerProvider).api;
    var failed = 0;
    for (final c in chosen) {
      try {
        await api.deleteChat(c.id);
        ref.read(conversationsProvider.notifier).remove(c.id);
      } catch (_) {
        failed++;
      }
    }
    _exitSelect();
    _toast(failed == 0 ? 'Deleted.' : 'Some chats could not be deleted — check your connection.');
  }

  List<Conversation> _apply(List<Conversation> all) {
    // Locked chats stay behind the PIN (see chat3_tools.dart).
    final lockOpen = ref.read(chatLockProvider).open;
    // Pinned chats first (newest pin on top), then everything by last message.
    var list = [...all.where((c) => (lockOpen || !c.locked) && c.archived == _showArchived)]..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        if (a.pinned) return b.pinnedAt!.compareTo(a.pinnedAt!);
        return (b.lastMessage?.createdAt ?? '').compareTo(a.lastMessage?.createdAt ?? '');
      });
    if (_filter.startsWith('label:')) {
      final label = ref.read(labelsProvider).where((l) => 'label:${l.id}' == _filter).firstOrNull;
      list = label == null ? list : list.where((c) => label.conversationIds.contains(c.id)).toList();
    } else {
      list = switch (_filter) {
      'unread' => list.where((c) => c.unread > 0 || ConversationsController.isMarkedUnread(c.id)).toList(),
      'favorites' => list.where((c) => c.favorite).toList(),
      'groups' => list.where((c) => c.isGroup).toList(),
      'private' => list.where((c) => !c.isGroup).toList(),
      _ => list,
    };
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((c) => c.displayName('').toLowerCase().contains(q) || (c.peer?.username.toLowerCase().contains(q) ?? false))
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationsProvider);
    ref.watch(chatLockProvider); // locked chats appear/disappear with the PIN
    final session = ref.watch(sessionControllerProvider);
    final me = session.user;
    final all = conversationsAsync.valueOrNull ?? const <Conversation>[];
    final selecting = _selectMode || _selected.isNotEmpty;
    final chosen = all.where((c) => _selected.contains(c.id)).toList();
    final labels = ref.watch(labelsProvider);
    if (_filter.startsWith('label:') && !labels.any((l) => 'label:${l.id}' == _filter)) _filter = 'all';

    return PopScope(
      canPop: !selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) _exitSelect();
        if (_searching) setState(() { _searching = false; _searchCtrl.clear(); _query = ''; _people = []; });
      },
      child: Scaffold(
        appBar: selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: _exitSelect),
                title: Text('${_selected.length} selected'),
                actions: [
                  IconButton(
                    tooltip: chosen.isNotEmpty && chosen.every((c) => c.pinned) ? 'Unpin' : 'Pin',
                    icon: Icon(chosen.isNotEmpty && chosen.every((c) => c.pinned) ? Icons.push_pin_rounded : Icons.push_pin_outlined),
                    onPressed: chosen.isEmpty
                        ? null
                        : () async {
                            final unpin = chosen.every((c) => c.pinned);
                            _exitSelect();
                            for (final c in chosen.where((c) => c.pinned == unpin)) {
                              await togglePin(context, ref, c);
                            }
                          },
                  ),
                  if (chosen.length == 1)
                    IconButton(
                      tooltip: chosen.first.muted ? 'Unmute' : 'Mute',
                      icon: Icon(chosen.first.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
                      onPressed: () {
                        final c = chosen.first;
                        _exitSelect();
                        chooseMute(context, ref, c);
                      },
                    ),
                  IconButton(
                    tooltip: 'Mark as unread',
                    icon: const Icon(Icons.mark_chat_unread_outlined),
                    onPressed: chosen.isEmpty
                        ? null
                        : () {
                            ref.read(conversationsProvider.notifier).markUnread(_selected);
                            _exitSelect();
                            _toast('Marked as unread.');
                          },
                  ),
                  IconButton(
                    tooltip: 'Mark read',
                    icon: const Icon(Icons.done_all_rounded),
                    onPressed: () {
                      ref.read(conversationsProvider.notifier).markRead(_selected);
                      _exitSelect();
                      _toast('Marked as read.');
                    },
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: chosen.isEmpty ? null : () => _deleteSelected(chosen),
                  ),
                ],
              )
            : AppBar(
                titleSpacing: 12,
                title: _searching
                    ? TextField(
                        controller: _searchCtrl,
                        autofocus: true,
                        onChanged: _onSearch,
                        decoration: const InputDecoration(hintText: 'Search or start a new chat', border: InputBorder.none),
                      )
                    : const Padding(padding: EdgeInsets.only(left: 6), child: Text('Chats')),
                actions: [
                  if (!_searching)
                    IconButton(
                      tooltip: 'AI Chat',
                      icon: const Icon(Icons.auto_awesome_outlined, color: Color(0xFF8B5CF6)),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiChatScreen())),
                    ),
                  IconButton(
                    tooltip: _searching ? 'Close search' : 'Search',
                    icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) {
                        _searchCtrl.clear();
                        _query = '';
                        _people = [];
                      }
                    }),
                  ),
                  if (!_searching)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
                        child: Avatar(label: me?.displayName ?? '', color: me?.avatarColor, photoUrl: me?.photoUrl, radius: 16),
                      ),
                    ),
                  if (!_searching)
                    PopupMenuButton<String>(
                      onSelected: _onMenu,
                      itemBuilder: (ctx) => <PopupMenuEntry<String>>[
                        const PopupMenuItem(value: 'group', child: Text('New group')),
                        const PopupMenuItem(value: 'communities', child: Text('Communities')),
                        const PopupMenuItem(value: 'joinlink', child: Text('Join a group with link')),
                        const PopupMenuItem(value: 'profile', child: Text('Profile')),
                        const PopupMenuItem(value: 'qr', child: Text('QR code')),
                        const PopupMenuItem(value: 'starred', child: Text('Starred messages')),
                        const PopupMenuItem(value: 'select', child: Text('Select chats')),
                        const PopupMenuItem(value: 'markread', child: Text('Mark all as read')),
                        const PopupMenuItem(value: 'reminders', child: Text('Reminders')),
                        const PopupMenuItem(value: 'theme', child: Text('Appearance')),
                        const PopupMenuItem(value: 'applock', child: Text('App lock')),
                        const PopupMenuItem(value: 'blocked', child: Text('Blocked contacts')),
                        const PopupMenuItem(value: 'linkdevice', child: Text('Linked devices')),
                        const PopupMenuItem(value: 'storage', child: Text('Storage & data')),
                        const PopupMenuItem(value: 'backup', child: Text('Chat backup')),
                        const PopupMenuItem(value: 'privacy', child: Text('Privacy')),
                        const PopupMenuItem(value: 'textsize', child: Text('Chat text size')),
                        const PopupMenuDivider(),
                        const PopupMenuItem(value: 'broadcasts', child: Text('Broadcast lists')),
                        const PopupMenuItem(value: 'quickreplies', child: Text('Quick replies')),
                        const PopupMenuItem(value: 'security', child: Text('Security & logins')),
                        const PopupMenuItem(value: 'features', child: Text('Chat features')),
                        const PopupMenuDivider(),
                        const PopupMenuItem(value: 'games', child: Text('Games')),
                        const PopupMenuItem(value: 'ai', child: Text('AI Chat')),
                        PopupMenuItem(
                          value: 'voice',
                          child: Text(ref.read(voiceAssistantProvider).active
                              ? 'Turn off voice commands ("Hey ARM")'
                              : 'Turn on voice commands ("Hey ARM")'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(value: 'logout', child: Text('Sign out')),
                      ],
                    ),
                ],
              ),
        floatingActionButton: selecting
            ? null
            : FloatingActionButton(
                tooltip: 'New chat',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatScreen())),
                child: const Icon(Icons.add_comment_outlined),
              ),
        body: Column(
          children: [
            if (!selecting)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  children: [
                    for (final e in _filters.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(_chipLabel(e.key, e.value, all)),
                          selected: _filter == e.key,
                          onSelected: (_) => setState(() => _filter = e.key),
                        ),
                      ),
                    // One tab per custom list, after the built-in ones — like the website.
                    for (final l in labels)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          avatar: CircleAvatar(backgroundColor: parseHexColor(l.color), radius: 5),
                          label: Text(l.conversationIds.isEmpty ? l.name : '${l.name} ${l.conversationIds.length}'),
                          selected: _filter == 'label:${l.id}',
                          onSelected: (_) => setState(() => _filter = 'label:${l.id}'),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: conversationsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Could not load chats — check your connection.\n$e', textAlign: TextAlign.center)),
                data: (_) => _list(_apply(all), me?.id),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _chipLabel(String key, String label, List<Conversation> all) {
    final n = switch (key) {
      'unread' => all.where((c) => c.unread > 0 || ConversationsController.isMarkedUnread(c.id)).length,
      'favorites' => all.where((c) => c.favorite).length,
      'groups' => all.where((c) => c.isGroup).length,
      'private' => all.where((c) => !c.isGroup).length,
      _ => all.length,
    };
    return n > 0 ? '$label $n' : label;
  }

  Widget _list(List<Conversation> chats, String? myId) {
    final searchingPeople = _query.trim().isNotEmpty;
    final knownPeerIds = chats.map((c) => c.peer?.id).whereType<String>().toSet();
    final people = _people.where((u) => !knownPeerIds.contains(u.id)).toList();

    final allChats = ref.read(conversationsProvider).valueOrNull ?? const <Conversation>[];
    final lockedCount = allChats.where((c) => c.locked).length;
    final lockedUnread = allChats.where((c) => c.locked).fold<int>(0, (n, c) => n + c.unread);
    final archivedCount = allChats.where((c) => c.archived).length;
    final archivedUnread = allChats.where((c) => c.archived && c.unread > 0).length;
    if (chats.isEmpty && !searchingPeople && lockedCount == 0 && archivedCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(_emptyHints[_filter]!, textAlign: TextAlign.center, style: const TextStyle(color: VeyonColors.muted)),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
      child: ListView(
        children: [
          if (!searchingPeople && (archivedCount > 0 || _showArchived))
            _ArchivedRow(
              open: _showArchived,
              count: archivedCount,
              unread: archivedUnread,
              onTap: () => setState(() => _showArchived = !_showArchived),
            ),
          if (!searchingPeople && !_showArchived && lockedCount > 0) LockedChatsRow(count: lockedCount, unread: lockedUnread),
          if (searchingPeople && chats.isNotEmpty) const _SectionLabel('Chats'),
          for (final c in chats)
            _ConversationTile(
              conversation: c,
              myId: myId,
              selecting: _selectMode || _selected.isNotEmpty,
              selected: _selected.contains(c.id),
              onToggleSelect: () => setState(() => _selected.contains(c.id) ? _selected.remove(c.id) : _selected.add(c.id)),
            ),
          if (searchingPeople && _messageHits.isNotEmpty) ...[
            const _SectionLabel('Messages'),
            for (final h in _messageHits)
              if (allChats.where((c) => c.id == h.conversationId).firstOrNull case final convo?)
                if (!convo.locked || ref.read(chatLockProvider).open)
                  ListTile(
                    leading: convo.isGroup
                        ? Avatar(label: convo.displayName('Group'), color: convo.avatarColor)
                        : Avatar(label: convo.displayName(''), color: convo.peer?.avatarColor, photoUrl: convo.peer?.photoUrl),
                    title: Row(
                      children: [
                        Expanded(child: Text(convo.displayName('Chat'), overflow: TextOverflow.ellipsis)),
                        Text(_shortTime(h.message.createdAt), style: const TextStyle(fontSize: 11.5, color: VeyonColors.muted)),
                      ],
                    ),
                    subtitle: _Highlighted(text: h.message.preview, query: _query.trim()),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ChatScreen(conversation: convo, jumpToMessageId: h.message.id))),
                  ),
          ],
          if (searchingPeople) ...[
            const _SectionLabel('People'),
            if (_peopleLoading) const LinearProgressIndicator(),
            if (!_peopleLoading && people.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('No one else found.', style: TextStyle(color: VeyonColors.muted))),
            for (final u in people)
              ListTile(
                leading: Avatar(label: u.displayName, color: u.avatarColor, photoUrl: u.photoUrl),
                title: Text(u.displayName),
                subtitle: Text('@${u.username}', style: const TextStyle(color: VeyonColors.muted)),
                onTap: () => _openPerson(u),
              ),
          ],
        ],
      ),
    );
  }
}

/// A one-line snippet with the searched words in bold.
class _Highlighted extends StatelessWidget {
  final String text;
  final String query;
  const _Highlighted({required this.text, required this.query});

  @override
  Widget build(BuildContext context) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ');
    final at = flat.toLowerCase().indexOf(query.toLowerCase());
    if (query.isEmpty || at < 0) {
      return Text(flat, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: VeyonColors.muted));
    }
    // Keep the match in view on long messages.
    final start = at > 30 ? at - 20 : 0;
    final shown = (start > 0 ? '…' : '') + flat.substring(start);
    final hit = at - start + (start > 0 ? 1 : 0);
    return Text.rich(
      TextSpan(style: const TextStyle(color: VeyonColors.muted), children: [
        TextSpan(text: shown.substring(0, hit)),
        TextSpan(
            text: shown.substring(hit, hit + query.length),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w700)),
        TextSpan(text: shown.substring(hit + query.length)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: const TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w600, fontSize: 12.5)),
      );
}

class _ConversationTile extends ConsumerWidget {
  final Conversation conversation;
  final String? myId;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggleSelect;
  const _ConversationTile({
    required this.conversation,
    required this.myId,
    required this.selecting,
    required this.selected,
    required this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = conversation;
    final title = c.displayName('Unknown');
    final online = !c.isGroup && ref.watch(presenceProvider).online.contains(c.peer?.id);
    final last = c.lastMessage;
    final mineLast = last != null && last.senderId == myId;
    final requestForMe = c.isPending && c.requestedBy != myId;
    final chatLabels = ref.watch(labelsProvider).where((l) => l.conversationIds.contains(c.id)).toList();

    return ListTile(
      selected: selected,
      selectedTileColor: VeyonColors.hairline,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      minVerticalPadding: 10,
      onLongPress: onToggleSelect,
      onTap: selecting
          ? onToggleSelect
          : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: c))),
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onToggleSelect())
          : c.isGroup
              ? Avatar(label: title, color: c.avatarColor)
              : Avatar(label: title, color: c.peer?.avatarColor, photoUrl: c.peer?.photoUrl, online: online),
      title: Row(
        children: [
          Expanded(
              child: Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, letterSpacing: -0.1))),
          if (c.pinned)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.push_pin_rounded, size: 15, color: VeyonColors.muted),
            ),
          InkWell(
            onTap: () => ref.read(conversationsProvider.notifier).setFavorite(c.id, !c.favorite).catchError((_) {}),
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Icon(c.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 17, color: c.favorite ? const Color(0xFFF5B83D) : VeyonColors.hairline),
            ),
          ),
          Text(last == null ? '' : _shortTime(last.createdAt),
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: c.unread > 0 ? FontWeight.w700 : FontWeight.w400,
                  color: c.unread > 0 ? Theme.of(context).colorScheme.primary : VeyonColors.muted)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rebuilds when a draft is started/cleared in any chat.
          ListenableBuilder(
            listenable: PrefsStore.instance,
            builder: (_, __) {
              final draft = requestForMe ? '' : PrefsStore.instance.draftFor(c.id);
              if (draft.isEmpty) return _subtitleRow(c, last, mineLast, requestForMe);
              return Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Draft: ', style: TextStyle(color: VeyonColors.danger, fontWeight: FontWeight.w700)),
                  TextSpan(text: draft.replaceAll(RegExp(r'\s+'), ' '), style: const TextStyle(color: VeyonColors.muted)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
          if (chatLabels.isNotEmpty) Wrap(children: [for (final l in chatLabels) LabelChip(l)]),
        ],
      ),
    );
  }

  Widget _subtitleRow(Conversation c, LastMessagePreview? last, bool mineLast, bool requestForMe) {
    return Row(
        children: [
          if (c.muted) const Padding(padding: EdgeInsets.only(right: 3), child: Text('🔕', style: TextStyle(fontSize: 12))),
          if (c.disappearSeconds > 0)
            const Padding(padding: EdgeInsets.only(right: 3), child: Icon(Icons.timer_outlined, size: 13, color: VeyonColors.muted)),
          if (mineLast && !requestForMe && !c.isPending && last != null) _tick(last),
          Expanded(
            child: requestForMe
                ? const Text('Message request', style: TextStyle(color: VeyonColors.bubbleMe2, fontWeight: FontWeight.w600))
                : c.isPending
                    ? const Text('Waiting for them to accept', style: TextStyle(color: VeyonColors.muted))
                    : last == null
                        ? Text(c.isGroup ? 'No messages yet' : 'Say hello', style: const TextStyle(color: VeyonColors.muted))
                        : _PreviewText(conversation: c),
          ),
          if (c.unread == 0 && ConversationsController.isMarkedUnread(c.id))
            Container(
              margin: const EdgeInsets.only(left: 6),
              width: 12,
              height: 12,
              decoration: const BoxDecoration(color: VeyonColors.bubbleMe, shape: BoxShape.circle),
            ),
          if (c.unread > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              constraints: const BoxConstraints(minWidth: 21),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(color: VeyonColors.bubbleMe, borderRadius: BorderRadius.circular(99)),
              child: Text(c.unread > 99 ? '99+' : '${c.unread}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
        ],
    );
  }

  Widget _tick(LastMessagePreview last) {
    final read = last.readAt != null;
    final delivered = last.deliveredAt != null || read;
    return Padding(
      padding: const EdgeInsets.only(right: 3),
      child: Icon(delivered ? Icons.done_all_rounded : Icons.done_rounded,
          size: 15, color: read ? const Color(0xFF7CC4FF) : VeyonColors.muted),
    );
  }
}

String _shortTime(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return '${d.day}/${d.month}/${d.year % 100}';
}

/// Decrypted one-line preview of a chat's last message (groups too — their
/// key comes from the same resolver the chat screen uses, cached offline).
/// Results are remembered per message so scrolling doesn't re-decrypt.
final Map<String, String> _previewCache = {};
/// Storage & data bucket of each previewed message, so a cleared one shows no preview.
final Map<String, String> _previewKind = {};

class _PreviewText extends ConsumerWidget {
  final Conversation conversation;
  const _PreviewText({required this.conversation});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = conversation.lastMessage!;
    final cached = _previewCache[last.id];
    const style = TextStyle(color: VeyonColors.muted);
    final kind = _previewKind[last.id];
    if (kind != null && isClearedAt(kind, last.createdAt)) return const SizedBox.shrink();
    if (cached != null) return Text(cached, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    final session = ref.read(sessionControllerProvider);
    return FutureBuilder<String>(
      future: _decrypt(session, conversation, last),
      builder: (context, snapshot) =>
          Text(snapshot.data ?? '…', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    );
  }

  Future<String> _decrypt(Session session, Conversation c, LastMessagePreview last) async {
    if (last.kind == 'auto' && isClearedAt('messages', last.createdAt)) return '';
    if (last.kind == 'auto') return _previewCache[last.id] = last.ciphertext; // automatic reply: plain text
    try {
      final String plaintext;
      if (last.ciphertext == 'signal') {
        // Signal: whatever this phone kept when it opened the message.
        final kept = await SignalService.instance.open(id: last.id, senderId: last.senderId, iv: last.iv);
        if (kept == null) return '🔒 Encrypted message';
        plaintext = kept;
      } else {
        final key = await resolveConversationKey(session, c);
        plaintext = await decryptText(key, last.ciphertext, last.iv);
      }
      final msg = ChatMessage(
        id: last.id,
        senderId: last.senderId,
        kind: last.kind,
        ciphertext: last.ciphertext,
        iv: last.iv,
        createdAt: last.createdAt,
        plaintext: plaintext,
      );
      _previewKind[last.id] = messageCategory(msg);
      if (isCleared(msg)) return '';
      var text = msg.preview;
      // In groups, say who sent it — like most chat apps.
      if (c.isGroup && last.senderId == session.user?.id) text = 'You: $text';
      return _previewCache[last.id] = text;
    } catch (_) {
      return '🔒 Encrypted message';
    }
  }
}



class _ArchivedRow extends StatelessWidget {
  final bool open;
  final int count;
  final int unread;
  final VoidCallback onTap;
  const _ArchivedRow({required this.open, required this.count, required this.unread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Material(
        color: VeyonColors.hairline,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: CircleAvatar(
            backgroundColor: accent.withValues(alpha: 0.15),
            child: Icon(open ? Icons.arrow_back_rounded : Icons.archive_outlined, color: accent, size: 20),
          ),
          title: Text(open ? 'Archived chats' : 'Archived', style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: open
              ? const Text('Back to chats', style: TextStyle(color: VeyonColors.muted))
              : Text(unread > 0 ? '$unread unread' : '$count', style: TextStyle(color: unread > 0 ? accent : VeyonColors.muted)),
          onTap: onTap,
        ),
      ),
    );
  }
}
