import 'package:veyon_chat_mobile/features/account/birth_date.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../../models/user.dart';
import '../auth/session.dart';
import '../chat/chat_screen.dart';
import 'conversations_provider.dart';

/// User search -> open (or reopen) a 1:1 conversation — mirrors app.js's
/// "start new chat" flow, backed by GET /api/users?q= and
/// POST /api/conversations/direct exactly as-is.
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _queryCtrl = TextEditingController();
  List<AppUser> _results = [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final api = ref.read(sessionControllerProvider).api;
      final raw = await api.searchUsers(q.trim());
      setState(() => _results = raw.map((j) => AppUser.fromJson(j as Map<String, dynamic>)).toList());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openChat(AppUser peer) async {
    if (!await privateChatGate()) return; // private chats are 18+
    final api = ref.read(sessionControllerProvider).api;
    final json = await api.openDirectConversation(peer.id);
    final conversation = Conversation.fromJson(json);
    ref.read(conversationsProvider.notifier).refresh();
    if (mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _queryCtrl,
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                hintText: 'Search by username or name',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final u = _results[i];
                return ListTile(
                  leading: CircleAvatar(child: Text(u.displayName.isNotEmpty ? u.displayName[0].toUpperCase() : '?')),
                  title: Text(u.displayName),
                  subtitle: Text('@${u.username}'),
                  onTap: () => _openChat(u),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
