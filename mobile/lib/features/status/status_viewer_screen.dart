import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../core/avatar.dart';
import '../../core/crypto/jwk.dart';
import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../models/conversation.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';
import '../presence/presence_provider.dart' show lastSeenLabel;
import 'status_composer_screen.dart';
import 'status_provider.dart';

/// Full-screen viewer for one person's statuses — the website's status
/// viewer: auto-advance with a progress bar (a video sets its own length),
/// tap left/right to step, captions, songs, mentions, "Seen by" + delete on
/// my own, reply / save / "Add to my status" on others'.
class StatusViewerScreen extends ConsumerStatefulWidget {
  final StatusGroup group;
  const StatusViewerScreen({super.key, required this.group});

  @override
  ConsumerState<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends ConsumerState<StatusViewerScreen> with SingleTickerProviderStateMixin {
  late List<Map<String, dynamic>> _items = [...widget.group.statuses];
  int _index = 0;
  late final AnimationController _progress = AnimationController(vsync: this)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _step(1);
    });

  EcPublicJwk? _posterKey;
  bool _loading = true;
  String? _text;
  Uint8List? _image;
  Uint8List? _videoBytes;
  VideoPlayerController? _video;
  bool _videoMuted = true;
  String? _caption;
  ({Uint8List bytes, String name, String mime})? _media; // for save / re-share
  ({Uint8List bytes, String name, String mime})? _song;
  final _songPlayer = AudioPlayer();
  bool _songPlaying = false;
  List<Map<String, dynamic>>? _views;
  bool _showViews = false;
  Set<String> _reshared = {};
  final _reply = TextEditingController();
  final _replyFocus = FocusNode();

  Map<String, dynamic> get _current => _items[_index];

  @override
  void initState() {
    super.initState();
    _replyFocus.addListener(() {
      // Don't skip ahead while someone is typing a reply.
      if (_replyFocus.hasFocus) {
        _pause();
      } else if (_reply.text.trim().isEmpty) {
        _resume();
      }
    });
    _songPlayer.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _songPlaying = s == PlayerState.playing);
    });
    _init();
  }

  @override
  void dispose() {
    _progress.dispose();
    _video?.dispose();
    _songPlayer.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _reshared = await ResharedStatuses.load();
    final session = ref.read(sessionControllerProvider);
    try {
      final jwk = widget.group.isMine
          ? session.user!.publicKey
          : (await session.api.getUser(widget.group.posterId))['publicKey'] as Map<String, dynamic>?;
      if (jwk != null) _posterKey = EcPublicJwk.fromJson(jwk);
    } catch (_) {}
    _show();
  }

  void _pause() {
    _progress.stop();
    _video?.pause();
  }

  void _resume() {
    if (_showViews || _loading) return;
    _progress.forward();
    _video?.play();
  }

  Future<SecretKey> _contentKey(Map<String, dynamic> s) async {
    final session = ref.read(sessionControllerProvider);
    if (_posterKey == null) throw StateError('No key');
    final wrapKey = await deriveWrapKey(session.identityKeyPair!, _posterKey!);
    return unwrapContentKey(wrapKey, s['wrappedKey'] as String, s['wrappedIv'] as String);
  }

  Future<void> _show() async {
    _progress.stop();
    _progress.value = 0;
    await _video?.dispose();
    await _songPlayer.stop();
    setState(() {
      _loading = true;
      _text = null;
      _image = null;
      _videoBytes = null;
      _video = null;
      _caption = null;
      _media = null;
      _song = null;
      _views = null;
      _showViews = false;
    });
    final s = _current;
    final session = ref.read(sessionControllerProvider);
    var duration = const Duration(seconds: 5);
    try {
      final key = await _contentKey(s);
      final kind = s['kind'] as String;
      if (kind == 'text') {
        _text = await decryptText(key, s['ciphertext'] as String, s['iv'] as String);
      } else {
        final meta = await decryptFileMeta(key, s['ciphertext'] as String, s['iv'] as String);
        _caption = meta['caption'] as String?;
        final blob = await session.api.downloadBlob(s['filePath'] as String);
        final bytes = await decryptFileBytes(key, Uint8List.fromList(blob), meta['blobIv'] as String);
        final mime = meta['mime'] as String? ?? (kind == 'video' ? 'video/mp4' : 'image/jpeg');
        _media = (bytes: bytes, name: meta['name'] as String? ?? 'status.${kind == 'video' ? 'mp4' : 'jpg'}', mime: mime);
        if (kind == 'video') {
          // video_player needs a file — write the decrypted copy to temp storage.
          final f = File('${(await getTemporaryDirectory()).path}/status_${s['id']}.mp4');
          await f.writeAsBytes(bytes);
          final c = VideoPlayerController.file(f);
          await c.initialize();
          await c.setVolume(_videoMuted ? 0 : 1);
          await c.setLooping(true);
          _video = c;
          _videoBytes = bytes;
          if (c.value.duration > Duration.zero) duration = c.value.duration;
        } else {
          _image = bytes;
        }
      }
      if (s['audioCiphertext'] != null) {
        final meta = await decryptFileMeta(key, s['audioCiphertext'] as String, s['audioIv'] as String);
        final blob = await session.api.downloadBlob(s['audioFilePath'] as String);
        final bytes = await decryptFileBytes(key, Uint8List.fromList(blob), meta['blobIv'] as String);
        _song = (bytes: bytes, name: meta['name'] as String? ?? 'song.mp3', mime: meta['mime'] as String? ?? 'audio/mpeg');
        await _songPlayer.setReleaseMode(ReleaseMode.loop);
        await _songPlayer.play(BytesSource(bytes));
      }
    } catch (_) {
      _text = '🔒 Could not decrypt this status.';
    }

    if (widget.group.isMine) {
      session.api.statusViews(s['id'] as String).then((v) {
        if (mounted && _current['id'] == s['id']) setState(() => _views = v.cast<Map<String, dynamic>>());
      }).catchError((_) {});
    } else {
      session.api.viewStatus(s['id'] as String).catchError((_) {});
      s['viewed'] = true;
    }

    if (!mounted) return;
    setState(() => _loading = false);
    _progress.duration = duration;
    _video?.play();
    if (!_replyFocus.hasFocus) _progress.forward(from: 0);
  }

  void _step(int delta) {
    final next = _index + delta;
    if (next < 0) return;
    if (next >= _items.length) {
      ref.read(statusProvider.notifier).refresh();
      Navigator.pop(context);
      return;
    }
    setState(() => _index = next);
    _show();
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _save() async {
    final m = _media;
    if (m == null) return;
    _pause();
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      final f = File('${(await getTemporaryDirectory()).path}/${m.name}');
      await f.writeAsBytes(m.bytes);
      if (m.mime.startsWith('video/')) {
        await Gal.putVideo(f.path);
      } else {
        await Gal.putImage(f.path);
      }
      _toast('Saved to your gallery.');
    } catch (_) {
      _toast('Could not save — allow access to photos and try again.');
    }
    _resume();
  }

  Future<void> _delete() async {
    _pause();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this status?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) {
      _resume();
      return;
    }
    try {
      await ref.read(sessionControllerProvider).api.deleteStatus(_current['id'] as String);
      _items = [..._items]..removeAt(_index);
      if (_items.isEmpty) {
        ref.read(statusProvider.notifier).refresh();
        if (mounted) Navigator.pop(context);
        return;
      }
      if (_index >= _items.length) _index = _items.length - 1;
      _show();
    } catch (_) {
      _toast('Could not delete — check your connection.');
      _resume();
    }
  }

  /// "Add to my status" — opens the composer with this status's photo/video,
  /// song, caption or text, ready to post as mine.
  Future<void> _reshare() async {
    final s = _current;
    if (_reshared.contains(s['id'])) {
      _toast("You've already added this one to your status.");
      return;
    }
    if (_media == null && (_text == null || _text!.startsWith('🔒'))) {
      _toast('Nothing to re-share.');
      return;
    }
    _pause();
    final prefill = StatusPrefill(
      text: _media == null ? (_text ?? '') : '',
      media: _media == null ? null : PickedMedia(_media!.bytes, _media!.name, _media!.mime),
      song: _song == null ? null : PickedMedia(_song!.bytes, _song!.name, _song!.mime),
      caption: _caption ?? '',
      sourceStatusId: s['id'] as String,
    );
    await _songPlayer.stop();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => StatusComposerScreen(prefill: prefill)));
  }

  /// A reply is a normal message in my direct chat with the poster.
  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    final session = ref.read(sessionControllerProvider);
    final Conversation? convo = (ref.read(conversationsProvider).valueOrNull ?? const [])
        .where((c) => !c.isGroup && c.peer?.id == widget.group.posterId)
        .firstOrNull;
    if (convo == null || session.ws == null) {
      _toast('Could not find your conversation with them.');
      return;
    }
    try {
      final key = await resolveConversationKey(session, convo);
      final env = await encryptText(key, text);
      session.ws!.sendMessage(conversationId: convo.id, ciphertext: env.ciphertext, iv: env.iv, tempId: const Uuid().v4());
      _reply.clear();
      _replyFocus.unfocus();
      _toast('Reply sent.');
    } catch (_) {
      _toast('Could not send the reply.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _items.isEmpty ? null : _current;
    final g = widget.group;
    final me = ref.read(sessionControllerProvider).user;
    final mentions = ((s?['mentions'] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>();
    final createdAt = s?['createdAt'] as String?;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            // Progress bars
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(
                children: [
                  for (var i = 0; i < _items.length; i++)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        height: 3,
                        child: i == _index
                            ? AnimatedBuilder(
                                animation: _progress,
                                builder: (_, __) => LinearProgressIndicator(
                                  value: _progress.value,
                                  backgroundColor: Colors.white24,
                                  color: Colors.white,
                                ),
                              )
                            : Container(color: i < _index ? Colors.white : Colors.white24),
                      ),
                    ),
                ],
              ),
            ),
            // Header
            Row(
              children: [
                const SizedBox(width: 8),
                g.isMine
                    ? Avatar(label: me?.displayName ?? '', color: me?.avatarColor, photoUrl: me?.photoUrl, radius: 18)
                    : Avatar(label: g.posterName, color: g.posterColor, photoUrl: g.posterPhotoUrl, radius: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.isMine ? (s?['audience'] == 'selected' ? 'My status 🔒' : 'My status') : g.posterName,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                      if (createdAt != null)
                        Text(lastSeenLabel(createdAt).replaceFirst('last seen ', ''),
                            style: const TextStyle(color: Colors.white60, fontSize: 11.5)),
                    ],
                  ),
                ),
                if (_song != null)
                  IconButton(
                    tooltip: 'Music',
                    icon: Icon(_songPlaying ? Icons.pause_rounded : Icons.music_note_rounded, color: Colors.white),
                    onPressed: () => _songPlaying ? _songPlayer.pause() : _songPlayer.resume(),
                  ),
                if (!g.isMine && s != null && !_reshared.contains(s['id']))
                  IconButton(tooltip: 'Add to my status', icon: const Icon(Icons.add_box_outlined, color: Colors.white), onPressed: _reshare),
                if (_media != null)
                  IconButton(tooltip: 'Save', icon: const Icon(Icons.download_rounded, color: Colors.white), onPressed: _save),
                if (g.isMine)
                  IconButton(tooltip: 'Delete status', icon: const Icon(Icons.delete_outline_rounded, color: Colors.white), onPressed: _delete),
                IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ],
            ),
            if (s?['mentionsMe'] == true || mentions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (s?['mentionsMe'] == true)
                      Chip(label: Text('🔔 ${g.posterName} mentioned you'), visualDensity: VisualDensity.compact),
                    for (final m in mentions)
                      Chip(label: Text('@${m['displayName']}'), visualDensity: VisualDensity.compact),
                  ],
                ),
              ),
            // Body — tap left third to go back, elsewhere to go forward; hold to pause.
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _step(d.globalPosition.dx < MediaQuery.of(context).size.width / 3 ? -1 : 1),
                onLongPressStart: (_) => _pause(),
                onLongPressEnd: (_) => _resume(),
                child: Center(child: _body()),
              ),
            ),
            if (g.isMine)
              InkWell(
                onTap: _views == null
                    ? null
                    : () {
                        setState(() => _showViews = !_showViews);
                        _showViews ? _pause() : _resume();
                      },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _views == null ? 'Loading views…' : _views!.isEmpty ? 'No views yet' : 'Seen by ${_views!.length} — tap to see who',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            if (g.isMine && _showViews && _views != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final v in _views!)
                      ListTile(
                        dense: true,
                        leading: Avatar(label: v['displayName'] as String? ?? '', color: v['avatarColor'] as String?, photoUrl: v['photoUrl'] as String?, radius: 16),
                        title: Text(v['displayName'] as String? ?? '', style: const TextStyle(color: Colors.white)),
                        trailing: Text(lastSeenLabel(v['viewedAt']?.toString()).replaceFirst('last seen ', ''),
                            style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                      ),
                  ],
                ),
              ),
            if (!g.isMine)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 6, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _reply,
                        focusNode: _replyFocus,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(hintText: 'Reply…', hintStyle: TextStyle(color: Colors.white54)),
                        onSubmitted: (_) => _sendReply(),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.send_rounded, color: Colors.white), onPressed: _sendReply),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const CircularProgressIndicator(color: Colors.white);
    final caption = _caption != null && _caption!.isNotEmpty
        ? Padding(
            padding: const EdgeInsets.all(14),
            child: Text(_caption!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
          )
        : const SizedBox.shrink();
    if (_video != null && _videoBytes != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: AspectRatio(aspectRatio: _video!.value.aspectRatio, child: VideoPlayer(_video!))),
              caption,
            ],
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: IconButton.filledTonal(
              icon: Icon(_videoMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
              onPressed: () {
                setState(() => _videoMuted = !_videoMuted);
                _video!.setVolume(_videoMuted ? 0 : 1);
              },
            ),
          ),
        ],
      );
    }
    if (_image != null) {
      return Column(mainAxisSize: MainAxisSize.min, children: [Flexible(child: Image.memory(_image!)), caption]);
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(_text ?? '', style: const TextStyle(color: Colors.white, fontSize: 22), textAlign: TextAlign.center),
    );
  }
}
