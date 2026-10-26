import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/identity.dart';
import '../../core/crypto/jwk.dart';
import '../../core/crypto/keys.dart';
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../auth/session.dart';
import '../chat/chat_screen.dart';
import 'conversations_provider.dart';

/// Basic group creation — title + member picker, matching conversations.js's
/// POST /api/conversations/group contract exactly: the client (here) must
/// generate the content key and wrap a copy for every member INCLUDING
/// itself (the server rejects a group with no self-wrap — see the
/// "Missing a key for yourself" check in routes/conversations.py).
class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _titleCtrl = TextEditingController();
  final _queryCtrl = TextEditingController();
  final Map<String, AppUser> _selected = {};
  List<AppUser> _results = [];
  Timer? _debounce;
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _titleCtrl.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    final api = ref.read(sessionControllerProvider).api;
    final raw = await api.searchUsers(q.trim());
    setState(() => _results = raw.map((j) => AppUser.fromJson(j as Map<String, dynamic>)).toList());
  }

  Future<void> _create() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty || _selected.isEmpty) {
      setState(() => _error = 'Give the group a name and add at least one member.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final session = ref.read(sessionControllerProvider);
      final myKeyPair = session.identityKeyPair!;
      final (contentKey, rawKeyBytes) = await generateContentKey();

      // Self-wrap first — required by the server, see file docstring.
      // `session.user` never carries our own public key (auth responses
      // don't return it — see routes/auth.py's RETURNING clause), so
      // re-export it from the in-memory key pair instead. ECDH(myPriv,
      // myPub) is well-defined (ordinary scalar multiplication against your
      // own point) and deterministic, matching how the web client treats
      // "wrap for myself" as just another peer wrap using the same function.
      final myOwnPub = await exportPublicKey(myKeyPair);
      final myWrapKey = await deriveWrapKey(myKeyPair, myOwnPub);
      final myWrapped = await wrapContentKey(myWrapKey, rawKeyBytes);

      final members = <Map<String, dynamic>>[
        {'userId': session.user!.id, 'wrappedKey': myWrapped.wrappedKey, 'wrappedIv': myWrapped.wrappedIv},
      ];

      for (final user in _selected.values) {
        final peerJwk = EcPublicJwk.fromJson(user.publicKey!);
        final wrapKey = await deriveWrapKey(myKeyPair, peerJwk);
        final wrapped = await wrapContentKey(wrapKey, rawKeyBytes);
        members.add({'userId': user.id, 'wrappedKey': wrapped.wrappedKey, 'wrappedIv': wrapped.wrappedIv});
      }

      final json = await session.api.createGroup(title: title, avatarColor: '#2F6BFF', members: members);
      final conversation = Conversation.fromJson(json);
      ref.read(conversationsProvider.notifier).refresh();
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
      }
    } catch (e) {
      setState(() => _error = 'Could not create the group: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Group name'),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                children: _selected.values
                    .map((u) => Chip(
                          label: Text(u.displayName),
                          onDeleted: () => setState(() => _selected.remove(u.id)),
                        ))
                    .toList(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _queryCtrl,
              onChanged: _onQueryChanged,
              decoration: const InputDecoration(labelText: 'Add members', prefixIcon: Icon(Icons.search)),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final u = _results[i];
                final selected = _selected.containsKey(u.id);
                return CheckboxListTile(
                  value: selected,
                  title: Text(u.displayName),
                  subtitle: Text('@${u.username}'),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected[u.id] = u;
                    } else {
                      _selected.remove(u.id);
                    }
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
