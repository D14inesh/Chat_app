/// Edit profile (photo, name, About, appearance) and QR code (my code / scan
/// someone's code to start a chat) — the website's openEditProfile() and
/// openQrModal().
library profile_screen;

import '../../theme.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/avatar.dart';
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../auth/session.dart';
import '../business/business_profile.dart';
import '../chat/chat_screen.dart';
import '../conversations/conversations_provider.dart';
import '../settings/theme_settings_screen.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late final TextEditingController _name;
  late final TextEditingController _about;
  bool _saving = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    final me = ref.read(sessionControllerProvider).user!;
    _name = TextEditingController(text: me.displayName);
    _about = TextEditingController(text: me.about);
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _pickPhoto() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final file = result?.files.singleOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final mime = lookupMimeType(file.name) ?? 'image/jpeg';
    if (!{'image/jpeg', 'image/png', 'image/webp'}.contains(mime)) {
      _toast('Please choose a JPEG, PNG or WebP image.');
      return;
    }
    if (bytes.length > 5 * 1024 * 1024) {
      _toast('Photo is too large (limit 5 MB).');
      return;
    }
    setState(() => _uploading = true);
    try {
      await ref.read(sessionControllerProvider.notifier).updatePhoto(bytes, mime);
      final url = ref.read(sessionControllerProvider).user?.photoUrl;
      if (url != null) await evictAvatar(url);
      _toast('Profile photo updated.');
    } catch (e) {
      _toast(e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), ''));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _toast('Your name can\'t be empty.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(sessionControllerProvider.notifier).updateProfile(displayName: _name.text.trim(), about: _about.text.trim());
      _toast('Profile saved.');
    } catch (_) {
      _toast('Could not save — check your connection.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionControllerProvider).user!;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Stack(
              children: [
                // Key on the update so a new photo replaces the old one on screen.
                Avatar(key: ValueKey('${me.photoUrl}-$_uploading'), label: me.displayName, color: me.avatarColor, photoUrl: me.photoUrl, radius: 56),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: CircleAvatar(
                    radius: 20,
                    child: _uploading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : IconButton(icon: const Icon(Icons.photo_camera_rounded, size: 20), onPressed: _pickPhoto),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('JPEG, PNG or WebP — up to 5 MB. Not end-to-end encrypted, same as your username.',
                textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted, fontSize: 12)),
          ),
          const SizedBox(height: 20),
          Text('@${me.username}', style: const TextStyle(color: VeyonColors.muted)),
          const SizedBox(height: 12),
          TextField(controller: _name, maxLength: 60, decoration: const InputDecoration(labelText: 'Display name')),
          TextField(
            controller: _about,
            maxLength: 140,
            decoration: const InputDecoration(labelText: 'About', hintText: 'Available', helperText: 'Shown on your profile — visible to your contacts.'),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
          const SizedBox(height: 20),
          const BusinessEditor(),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Appearance'),
            subtitle: const Text('Palette, dark/light and layout — on every device you sign in from'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemeSettingsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_2_rounded),
            title: const Text('QR code'),
            subtitle: const Text('Show your code, or scan someone\'s to start a chat'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrCodeScreen())),
          ),
        ],
      ),
    );
  }
}

/// "My code" / "Scan" — scanning a `vesper:user:<id>` code opens a chat.
class QrCodeScreen extends ConsumerStatefulWidget {
  final bool startOnScan;
  const QrCodeScreen({super.key, this.startOnScan = false});

  @override
  ConsumerState<QrCodeScreen> createState() => _QrCodeScreenState();
}

class _QrCodeScreenState extends ConsumerState<QrCodeScreen> {
  Uint8List? _qr;
  String? _qrError;
  bool _opening = false;
  final _manual = TextEditingController();

  @override
  void initState() {
    super.initState();
    ref.read(sessionControllerProvider).api.myQr().then(
          (b) => mounted ? setState(() => _qr = Uint8List.fromList(b)) : null,
          onError: (_) => mounted ? setState(() => _qrError = 'Your code needs a connection to load.') : null,
        );
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _openChatWith(String userId) async {
    if (_opening) return;
    _opening = true;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = await ref.read(sessionControllerProvider).api.openDirectConversation(userId);
      final conversation = Conversation.fromJson(json);
      ref.read(conversationsProvider.notifier).refresh();
      nav.pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not open that chat — check your connection.')));
      _opening = false;
    }
  }

  Future<void> _openByUsername() async {
    final username = _manual.text.trim();
    if (username.isEmpty) return;
    try {
      final users = (await ref.read(sessionControllerProvider).api.searchUsers(username))
          .map((j) => AppUser.fromJson(j as Map<String, dynamic>));
      final match = users.where((u) => u.username.toLowerCase() == username.toLowerCase()).firstOrNull;
      if (match == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nobody found with that exact username.')));
        return;
      }
      await _openChatWith(match.id);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Search needs a connection.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.startOnScan ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('QR code'),
          bottom: const TabBar(tabs: [Tab(text: 'My code'), Tab(text: 'Scan')]),
        ),
        body: TabBarView(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_qr != null)
                      ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_qr!, width: 260, height: 260))
                    else if (_qrError != null)
                      Text(_qrError!, style: const TextStyle(color: VeyonColors.muted))
                    else
                      const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    const Text('Let someone scan this to start a chat with you instantly.',
                        textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
                  ],
                ),
              ),
            ),
            Column(
              children: [
                Expanded(
                  child: MobileScanner(
                    onDetect: (capture) {
                      final raw = capture.barcodes.firstOrNull?.rawValue;
                      if (raw != null && raw.startsWith('vesper:user:')) _openChatWith(raw.substring('vesper:user:'.length));
                    },
                    errorBuilder: (context, error, _) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          error.errorCode == MobileScannerErrorCode.permissionDenied
                              ? 'Camera permission is off — allow it in Settings, or type their username below.'
                              : 'Camera could not start (${error.errorCode.name}). Type their username below instead.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _manual,
                          decoration: const InputDecoration(hintText: 'or type their username', isDense: true),
                          onSubmitted: (_) => _openByUsername(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _openByUsername, child: const Text('Open chat')),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
