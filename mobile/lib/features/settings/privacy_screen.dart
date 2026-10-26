/// "Privacy" — who sees my last seen & online and my profile photo, and read
/// receipts (blue ticks). The server enforces all three
/// (backend/app/utils/privacy.py).
library privacy_screen;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../theme.dart';
import '../auth/session.dart';

const _audiences = [
  ('everyone', 'Everyone'),
  ('contacts', 'My contacts'),
  ('nobody', 'Nobody'),
];

String _audienceLabel(String v) => _audiences.firstWhere((a) => a.$1 == v, orElse: () => _audiences.first).$2;

class PrivacyScreen extends ConsumerStatefulWidget {
  const PrivacyScreen({super.key});
  @override
  ConsumerState<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends ConsumerState<PrivacyScreen> {
  Map<String, dynamic>? _p;
  String? _error;
  bool _saving = false;

  ApiClient get _api => ref.read(sessionControllerProvider).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _api.getJson('/api/users/me/privacy');
      if (mounted) setState(() => _p = p);
    } catch (_) {
      if (mounted) setState(() => _error = 'Privacy settings need a connection.');
    }
  }

  Future<void> _save(Map<String, dynamic> change) async {
    final before = _p;
    setState(() {
      _p = {...?_p, ...change};
      _saving = true;
    });
    try {
      final p = await _api.patchJson('/api/users/me/privacy', change);
      if (mounted) setState(() => _p = p);
    } catch (e) {
      if (mounted) {
        setState(() => _p = before);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e is ApiException ? e.message : 'Could not save — check your connection.')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pick(String key, String title, String note) async {
    final current = _p?[key] as String? ?? 'everyone';
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(note, style: const TextStyle(color: VeyonColors.muted, fontSize: 13)),
          ),
          for (final (value, label) in _audiences)
            ListTile(
              leading: Icon(value == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(label),
              onTap: () => Navigator.pop(ctx, value),
            ),
        ],
      ),
    );
    if (picked != null && picked != current) await _save({key: picked});
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: p == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: const TextStyle(color: VeyonColors.muted)))
          : ListView(
              children: [
                if (_saving) const LinearProgressIndicator(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Who can see my personal info', style: TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w600)),
                ),
                ListTile(
                  leading: const Icon(Icons.access_time_rounded),
                  title: const Text('Last seen and online'),
                  subtitle: Text(_audienceLabel(p['lastSeen'] as String? ?? 'everyone')),
                  onTap: () => _pick('lastSeen', 'Last seen and online',
                      '“My contacts” means people you have a 1-to-1 chat with.'),
                ),
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: const Text('Profile photo'),
                  subtitle: Text(_audienceLabel(p['photo'] as String? ?? 'everyone')),
                  onTap: () => _pick('photo', 'Profile photo', 'People who can’t see it see your initials instead.'),
                ),
                const Divider(),
                SwitchListTile(
                  secondary: const Icon(Icons.done_all_rounded),
                  title: const Text('Read receipts'),
                  subtitle: const Text(
                      'If turned off, you won’t send or receive blue ticks in 1-to-1 chats. Groups always show them.'),
                  value: p['readReceipts'] != false,
                  onChanged: _saving ? null : (v) => _save({'readReceipts': v}),
                ),
              ],
            ),
    );
  }
}
