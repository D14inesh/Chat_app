import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../../core/avatar.dart';
import '../../core/crypto/identity.dart';
import '../../core/crypto/jwk.dart';
import '../../core/crypto/keys.dart';
import '../../models/user.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';
import 'status_provider.dart';

/// A picked file for the composer (photo, video or song).
class PickedMedia {
  final Uint8List bytes;
  final String name;
  final String mime;
  const PickedMedia(this.bytes, this.name, this.mime);
}

/// What "Add to my status" carries over from someone else's status.
class StatusPrefill {
  final String text;
  final PickedMedia? media;
  final PickedMedia? song;
  final String caption;
  final String? sourceStatusId;
  const StatusPrefill({this.text = '', this.media, this.song, this.caption = '', this.sourceStatusId});
}

/// "Post a status" — the website's openStatusComposer()/postStatus():
/// text, or a photo OR video with a caption, plus an optional song; who can
/// see it (all contacts, or only chosen ones); and people to tag. One fresh
/// content key per status, wrapped for me + every viewer (+ anyone tagged,
/// so a mention can never point at a status they can't open).
class StatusComposerScreen extends ConsumerStatefulWidget {
  final StatusPrefill? prefill;
  const StatusComposerScreen({super.key, this.prefill});

  @override
  ConsumerState<StatusComposerScreen> createState() => _StatusComposerScreenState();
}

class _StatusComposerScreenState extends ConsumerState<StatusComposerScreen> {
  late final _textCtrl = TextEditingController(text: widget.prefill?.text ?? '');
  late final _captionCtrl = TextEditingController(text: widget.prefill?.caption ?? '');
  late PickedMedia? _media = widget.prefill?.media; // image or video
  late PickedMedia? _song = widget.prefill?.song;
  bool _onlySelected = false;
  final Set<String> _audience = {};
  final Set<String> _mentions = {};
  bool _showMentions = false;
  bool _posting = false;
  String? _error;

  bool get _isVideo => _media?.mime.startsWith('video/') ?? false;

  @override
  void dispose() {
    _textCtrl.dispose();
    _captionCtrl.dispose();
    super.dispose();
  }

  /// Accepted direct contacts — the only people a status can be shared with.
  List<AppUser> _contacts() => (ref.read(conversationsProvider).valueOrNull ?? const [])
      .where((c) => !c.isGroup && c.status == 'accepted' && c.peer?.publicKey != null)
      .map((c) => c.peer!)
      .toList();

  Future<PickedMedia?> _pick(FileType type) async {
    final result = await FilePicker.platform.pickFiles(type: type, withData: true);
    final f = result?.files.singleOrNull;
    if (f?.bytes == null) return null;
    final fallback = type == FileType.video ? 'video/mp4' : type == FileType.audio ? 'audio/mpeg' : 'image/jpeg';
    return PickedMedia(f!.bytes!, f.name, lookupMimeType(f.name) ?? fallback);
  }

  Future<void> _post() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty && _media == null) {
      setState(() => _error = 'Write something or pick a photo/video.');
      return;
    }
    if (_onlySelected && _audience.isEmpty) {
      setState(() => _error = 'Pick at least one person to share this with.');
      return;
    }
    setState(() { _posting = true; _error = null; });
    try {
      final session = ref.read(sessionControllerProvider);
      final myKeyPair = session.identityKeyPair!;
      final (contentKey, raw) = await generateContentKey();

      final body = <String, dynamic>{};
      if (_media != null) {
        final caption = _captionCtrl.text.trim();
        final env = await encryptFile(contentKey, _media!.bytes,
            name: _media!.name, mime: _media!.mime, extra: caption.isEmpty ? const {} : {'caption': caption});
        final up = await session.api.uploadBlob(env.blob);
        body.addAll({
          'kind': _isVideo ? 'video' : 'image',
          'ciphertext': env.metaCiphertext,
          'iv': env.metaIv,
          'filePath': up['filePath'],
          'fileSize': up['fileSize'],
        });
      } else {
        final env = await encryptText(contentKey, text);
        body.addAll({'kind': 'text', 'ciphertext': env.ciphertext, 'iv': env.iv});
      }

      if (_song != null) {
        // Same content key as the status itself — one set of wrapped keys covers both.
        final env = await encryptFile(contentKey, _song!.bytes, name: _song!.name, mime: _song!.mime);
        final up = await session.api.uploadBlob(env.blob);
        body.addAll({
          'audioCiphertext': env.metaCiphertext,
          'audioIv': env.metaIv,
          'audioFilePath': up['filePath'],
          'audioFileSize': up['fileSize'],
        });
      }

      final contacts = _contacts();
      final audienceIds = _onlySelected ? _audience : contacts.map((c) => c.id).toSet();
      final recipients = contacts.where((c) => audienceIds.contains(c.id) || _mentions.contains(c.id));

      final keys = <Map<String, dynamic>>[];
      final myWrap = await wrapContentKey(await deriveWrapKey(myKeyPair, await exportPublicKey(myKeyPair)), raw);
      keys.add({'viewerId': session.user!.id, 'wrappedKey': myWrap.wrappedKey, 'wrappedIv': myWrap.wrappedIv});
      for (final c in recipients) {
        final w = await wrapContentKey(await deriveWrapKey(myKeyPair, EcPublicJwk.fromJson(c.publicKey!)), raw);
        keys.add({'viewerId': c.id, 'wrappedKey': w.wrappedKey, 'wrappedIv': w.wrappedIv});
      }

      await session.api.postStatus({
        ...body,
        'keys': keys,
        'audience': _onlySelected ? 'selected' : 'contacts',
        'mentions': _mentions.toList(),
      });
      if (widget.prefill?.sourceStatusId != null) await ResharedStatuses.remember(widget.prefill!.sourceStatusId!);
      await ref.read(statusProvider.notifier).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Status posted.')));
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() => _error = 'Could not post status: ${e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), '')}');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = _contacts();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post a status'),
        actions: [
          TextButton(
            onPressed: _posting ? null : _post,
            child: _posting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Post'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: VeyonColors.danger))),
          if (_media == null)
            TextField(controller: _textCtrl, maxLines: 4, decoration: const InputDecoration(hintText: "What's on your mind?")),
          if (_media != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _isVideo
                  ? Container(
                      height: 160,
                      color: Colors.black54,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.videocam_rounded, size: 40),
                          const SizedBox(height: 6),
                          Text(_media!.name, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    )
                  : Image.memory(_media!.bytes, height: 220, width: double.infinity, fit: BoxFit.cover),
            ),
            const SizedBox(height: 8),
            TextField(controller: _captionCtrl, maxLength: 200, decoration: const InputDecoration(labelText: 'Caption', hintText: 'Say something about this')),
          ],
          const SizedBox(height: 12),
          const Text('Add to your status', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(Icons.image_rounded, 'Photo', !_isVideo ? _media?.name : null, () async {
                final m = await _pick(FileType.image);
                if (m != null) setState(() => _media = m); // photo and video are exclusive
              }, onClear: !_isVideo && _media != null ? () => setState(() => _media = null) : null),
              _chip(Icons.videocam_rounded, 'Video', _isVideo ? _media?.name : null, () async {
                final m = await _pick(FileType.video);
                if (m != null) setState(() => _media = m);
              }, onClear: _isVideo ? () => setState(() => _media = null) : null),
              _chip(Icons.music_note_rounded, 'Song', _song?.name, () async {
                final m = await _pick(FileType.audio);
                if (m != null) setState(() => _song = m);
              }, onClear: _song != null ? () => setState(() => _song = null) : null),
            ],
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<bool>(
            initialValue: _onlySelected,
            decoration: const InputDecoration(labelText: 'Who can see this'),
            items: [
              const DropdownMenuItem(value: false, child: Text('All my contacts')),
              DropdownMenuItem(value: true, enabled: contacts.isNotEmpty, child: const Text('Only share with…')),
            ],
            onChanged: (v) => setState(() => _onlySelected = v ?? false),
          ),
          if (_onlySelected) _peoplePicker(contacts, _audience),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: contacts.isEmpty ? null : () => setState(() => _showMentions = !_showMentions),
            icon: const Icon(Icons.alternate_email_rounded),
            label: Text(_mentions.isEmpty ? 'Tag people (optional)' : 'Tagged: ${_mentions.length}'),
          ),
          if (_showMentions) _peoplePicker(contacts, _mentions),
          const SizedBox(height: 16),
          const Text('Disappears after 24 hours.', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, String? filled, VoidCallback onPick, {VoidCallback? onClear}) {
    return InputChip(
      avatar: Icon(icon, size: 18),
      label: Text(filled ?? label, overflow: TextOverflow.ellipsis),
      selected: filled != null,
      onPressed: onPick,
      onDeleted: onClear,
    );
  }

  Widget _peoplePicker(List<AppUser> contacts, Set<String> into) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(border: Border.all(color: Colors.white12), borderRadius: BorderRadius.circular(10)),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final c in contacts)
            CheckboxListTile(
              dense: true,
              value: into.contains(c.id),
              onChanged: (v) => setState(() => v == true ? into.add(c.id) : into.remove(c.id)),
              secondary: Avatar(label: c.displayName, color: c.avatarColor, photoUrl: c.photoUrl, radius: 16),
              title: Text(c.displayName),
            ),
        ],
      ),
    );
  }
}
