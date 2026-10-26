import 'package:veyon_chat_mobile/features/account/birth_date.dart';
import 'package:veyon_chat_mobile/core/bubble_ink.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_visibility.dart';
import '../../core/avatar.dart';
import '../../core/crypto/keys.dart';
import '../../core/auto_download.dart';
import '../../core/file_cache.dart';
import '../../core/prefs_store.dart';
import '../../core/wallpapers.dart';
import '../effects/effects_overlay.dart';
import '../quickreplies/quick_replies.dart';
import 'chat_extras.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../blocked/blocked_provider.dart';
import '../calls/call_controller.dart';
import '../calls/group_call_screen.dart';
import 'message_tools.dart';
import '../conversations/chat_list_actions.dart';
import '../conversations/conversations_provider.dart';
import '../games/live/live_game_controller.dart';
import '../presence/presence_provider.dart';
import '../starred/starred_provider.dart';
import 'chat_controller.dart';
import '../labels/labels_provider.dart';
import 'chat_info_screens.dart';
import 'schedule_screen.dart';
import 'smart_compose.dart';
import 'forward_sheet.dart';
import 'media_picker_sheet.dart';
import '../groups/group_tools.dart';
import 'chat3_tools.dart';
import 'voice_playback.dart';
import '../share/launch_handler.dart';
import '../business/shop.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final Conversation conversation;
  /// Text/files shared into the app ("Send to…") — sent once the chat is ready.
  final SharedPayload? initialShare;
  /// Search all chats → open the chat scrolled to this message.
  final String? jumpToMessageId;
  const ChatScreen({super.key, required this.conversation, this.initialShare, this.jumpToMessageId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _composerCtrl = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _typingStopTimer;
  bool _typing = false;
  bool _searching = false;
  String _searchQuery = '';
  String _searchKind = 'all'; // all | photos | videos | links | docs | voice

  final _recorder = AudioRecorder();
  bool _recording = false;

  /// Voice-to-text language ('' = record a normal voice note). With a
  /// language picked, the mic turns speech into text in the message box
  /// instead — the website's language dropdown next to the mic.
  String _speechLang = '';
  final _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  String _liveText = '';

  /// Replying to / editing a message — at most one at a time, like the website.
  ChatMessage? _replyTo;
  ChatMessage? _editing;

  /// Multi-select mode (long-press "Select", or menu "Select messages").
  final Set<String> _selected = {};
  bool _selectMode = false;

  void _exitSelect() => setState(() {
        _selected.clear();
        _selectMode = false;
      });

  /// For jumping to a replied-to message.
  final Map<String, GlobalKey> _bubbleKeys = {};
  String? _flashId;
  bool _scrolledToEndOnce = false;

  ChatController get _controller => ref.read(chatControllerProvider(widget.conversation).notifier);

  /// messageId → `{loading}` / `{error}` / `{text, lang}` (Translate).
  final Map<String, Map<String, dynamic>> _translations = {};

  /// AI smart replies for the latest message (null until asked).
  List<String>? _aiReplies;
  String? _aiRepliesFor;
  bool _aiThinking = false;

  @override
  void dispose() {
    if (AppVisibility.openChatId.value == widget.conversation.id) AppVisibility.openChatId.value = null;
    _typingStopTimer?.cancel();
    _searchDebounce?.cancel();
    _composerCtrl.dispose();
    _composerFocus.dispose();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _onComposerChanged(String value) {
    setState(() {}); // swaps mic <-> send
    if (_editing != null) return;
    PrefsStore.instance.setDraft(widget.conversation.id, value); // kept per chat
    if (!_typing) {
      _typing = true;
      _controller.setTyping(true);
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 2), () {
      _typing = false;
      _controller.setTyping(false);
    });
  }

  void _stopTyping() {
    _typingStopTimer?.cancel();
    if (_typing) _controller.setTyping(false);
    _typing = false;
  }

  Future<void> _send() async {
    final text = _composerCtrl.text;
    if (text.trim().isEmpty) return;
    _composerCtrl.clear();
    _stopTyping();
    final editing = _editing;
    final replyTo = _replyTo;
    setState(() {
      _editing = null;
      _replyTo = null;
    });
    if (editing != null) {
      await _controller.editMessage(editing, text);
      return;
    }
    PrefsStore.instance.clearDraft(widget.conversation.id);
    maybePlayEffect(text);
    SmartCompose.instance.learn(text); // suggestions adapt to how I write
    final quotes = ref.read(pendingPrivateQuoteProvider);
    final quote = quotes[widget.conversation.id];
    if (quote != null) ref.read(pendingPrivateQuoteProvider.notifier).state = {...quotes}..remove(widget.conversation.id);
    await _controller.sendText(text, replyToId: replyTo?.id, privateQuote: quote);
    _scrollToEnd();
  }

  void _startReply(ChatMessage m) {
    setState(() {
      _editing = null;
      _replyTo = m;
    });
    _composerFocus.requestFocus();
  }

  void _startEdit(ChatMessage m) {
    setState(() {
      _replyTo = null;
      _editing = m;
      _composerCtrl.text = m.plaintext ?? '';
    });
    _composerFocus.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _composerCtrl.clear();
  }

  // ── Attachments ────────────────────────────────────────────────────

  Future<void> _openAttachMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(leading: const Icon(Icons.photo_library_rounded), title: const Text('Photo or file'), onTap: () => Navigator.pop(ctx, 'file')),
            ListTile(leading: const Icon(Icons.location_on_rounded), title: const Text('Location'), onTap: () => Navigator.pop(ctx, 'location')),
            ListTile(leading: const Icon(Icons.person_rounded), title: const Text('Contact'), onTap: () => Navigator.pop(ctx, 'contact')),
            ListTile(leading: const Icon(Icons.bar_chart_rounded), title: const Text('Poll'), onTap: () => Navigator.pop(ctx, 'poll')),
            if (ref.read(sessionControllerProvider).user?.businessSettings?['enabled'] == true)
              ListTile(
                leading: const Icon(Icons.shopping_bag_outlined),
                title: const Text('Product from my catalogue'),
                onTap: () => Navigator.pop(ctx, 'product'),
              ),
            ListTile(
              leading: const Icon(Icons.looks_one_outlined),
              title: const Text('View-once photo or video'),
              subtitle: const Text('They can open it one time'),
              onTap: () => Navigator.pop(ctx, 'viewonce'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'file') await _pickAndSendAttachment();
    if (choice == 'location') await _shareLocation();
    if (choice == 'contact') await _shareContact();
    if (choice == 'poll') await _createPoll();
    if (choice == 'product' && mounted) {
      final me = ref.read(sessionControllerProvider).user!.id;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CatalogueScreen(userId: me, onPick: (snap) => _controller.sendJson('product', snap)),
      ));
    }
    if (choice == 'viewonce') await _sendViewOnce();
  }

  Future<void> _makeSticker() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.singleOrNull?.bytes;
    if (bytes == null || !mounted) return;
    final png = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => StickerMakerScreen(image: bytes)));
    if (png == null) return;
    await _controller.sendFile(png, name: 'sticker.png', mime: 'image/png', extra: const {'sticker': true});
    _scrollToEnd();
  }

  /// Sends what was shared into the app, once the chat's key is ready.
  Future<void> _sendShared(SharedPayload p) async {
    for (var i = 0; i < 60 && _controller.resolvedKey == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
    }
    if (_controller.resolvedKey == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn’t open this chat to send — try again.')));
      return;
    }
    for (final f in p.files) {
      try {
        final bytes = await File(f['path']!).readAsBytes();
        await _controller.sendFile(bytes, name: f['name'] ?? 'file', mime: f['mime'] ?? 'application/octet-stream');
      } catch (_) {}
    }
    if (p.text.trim().isNotEmpty) await _controller.sendText(p.text);
    _scrollToEnd();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent.')));
  }

  Future<void> _createPoll() async {
    final poll = await showPollComposer(context);
    if (poll == null) return;
    final closesAt = poll.remove('pollClosesAt') as String?;
    await _controller.sendJson('poll', poll, extras: closesAt == null ? const {} : {'pollClosesAt': closesAt});
    _scrollToEnd();
  }

  Future<void> _sendViewOnce() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.media, withData: true);
    final file = result?.files.singleOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final mime = lookupMimeType(file.name) ?? 'application/octet-stream';
    if (!mime.startsWith('image/') && !mime.startsWith('video/')) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('View once works for photos and videos.')));
      return;
    }
    await _controller.sendFile(bytes, name: file.name, mime: mime, extra: const {'viewOnce': true});
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent as view once — they can open it one time.')));
    _scrollToEnd();
  }

  /// Decrypts a view-once photo/video straight into the viewer (never into
  /// the media cache) and marks it opened — on every device, for good.
  Future<void> _openViewOnce(ChatMessage m) async {
    final key = _controller.resolvedKey;
    final meta = m.payload;
    if (key == null || meta == null || m.filePath == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final blob = await ref.read(sessionControllerProvider).api.downloadBlob(m.filePath!);
      final bytes = await decryptFileBytes(key, Uint8List.fromList(blob), meta['blobIv'] as String);
      _controller.markViewOnceOpened(m);
      if (!mounted) return;
      await showViewOnceViewer(context, bytes, meta['mime'] as String? ?? 'image/jpeg');
    } catch (e) {
      if (e.toString().contains('410')) {
        _controller.markViewOnceOpened(m);
      } else {
        messenger.showSnackBar(const SnackBar(content: Text('Could not open it — check your connection.')));
      }
    }
  }

  Future<void> _translate(ChatMessage m, String lang) async {
    final text = m.plaintext;
    if (text == null) return;
    setState(() => _translations[m.id] = {'loading': true});
    try {
      final translation = await ref.read(sessionControllerProvider).api.aiTranslate(text, lang);
      if (mounted) setState(() => _translations[m.id] = {'text': translation, 'lang': lang});
    } catch (e) {
      if (mounted) setState(() => _translations[m.id] = {'error': e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), '')});
    }
  }

  /// `[{name, text}]` for the AI — only the messages it's asked about.
  List<Map<String, String>> _aiLines(List<ChatMessage> messages) {
    final out = <Map<String, String>>[];
    for (final m in messages) {
      if (m.deleted || m.plaintext == null) continue;
      final p = m.payload;
      final text = switch (m.kind) {
        'text' => m.plaintext!,
        'poll' => '[poll] ${p?['question']}: ${(p?['options'] as List?)?.join(' / ')}',
        'location' => '[shared a location]',
        'voice' => '[voice message]',
        'contact' => '[shared contact ${p?['name']}]',
        _ => '[sent ${m.isGif ? 'a GIF' : m.isSticker ? 'a sticker' : 'a file'}]',
      };
      final name = m.senderId == ref.read(sessionControllerProvider).user?.id
          ? ref.read(sessionControllerProvider).user!.displayName
          : _controller.senderName(m.senderId);
      out.add({'name': name, 'text': text.length > 600 ? text.substring(0, 600) : text});
    }
    return out;
  }

  Future<void> _askSmartReplies(List<ChatMessage> messages) async {
    setState(() => _aiThinking = true);
    try {
      final last = messages.last;
      final replies = await ref.read(sessionControllerProvider).api.aiReplies(
            _aiLines(messages.length > 15 ? messages.sublist(messages.length - 15) : messages),
            ref.read(sessionControllerProvider).user!.displayName,
          );
      if (mounted) {
        setState(() {
          _aiReplies = replies;
          _aiRepliesFor = last.id;
        });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), ''))));
    } finally {
      if (mounted) setState(() => _aiThinking = false);
    }
  }

  Future<void> _summarize() => showSummarySheet(context, () async {
        var messages = ref.read(chatControllerProvider(widget.conversation)).messages;
        if (messages.length < 150) await _controller.extendHistoryForSearch();
        messages = ref.read(chatControllerProvider(widget.conversation)).messages;
        final recent = messages.length > 150 ? messages.sublist(messages.length - 150) : messages;
        final lines = _aiLines(recent);
        if (lines.isEmpty) throw StateError('Nothing to summarize yet.');
        final summary = await ref.read(sessionControllerProvider).api.aiSummarize(lines);
        return (summary: summary, count: lines.length);
      });

  Future<void> _export(Conversation c) async {
    final messenger = ScaffoldMessenger.of(context);
    final progress = ValueNotifier<int>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 18),
          Expanded(child: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, n, __) => Text(n == 0 ? 'Loading messages…' : 'Decrypting… $n messages'),
          )),
        ]),
      ),
    );
    try {
      final all = await _controller.loadFullHistory(onProgress: (n) => progress.value = n);
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      final myId = ref.read(sessionControllerProvider).user?.id;
      final myName = ref.read(sessionControllerProvider).user?.displayName ?? 'Me';
      await shareChatExport(
        title: c.displayName('Chat'),
        messages: all,
        senderName: (m) => m.senderId == myId ? myName : _controller.senderName(m.senderId),
      );
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(const SnackBar(content: Text('Export needs a connection — try again when you’re online.')));
    }
  }

  Future<void> _pickAndSendAttachment() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) return;
    final mime = lookupMimeType(file.name) ?? 'application/octet-stream';
    final replyTo = _replyTo;
    setState(() => _replyTo = null);
    await _controller.sendFile(bytes, name: file.name, mime: mime, replyToId: replyTo?.id);
    _scrollToEnd();
  }

  Future<void> _shareLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        messenger.showSnackBar(const SnackBar(content: Text('Turn on Location in your phone settings first.')));
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        messenger.showSnackBar(const SnackBar(content: Text('Location permission is off for this app.')));
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('Getting your location…'), duration: Duration(seconds: 2)));
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
      final replyTo = _replyTo;
      setState(() => _replyTo = null);
      await _controller.sendJson('location', {'lat': pos.latitude, 'lng': pos.longitude}, replyToId: replyTo?.id);
      _scrollToEnd();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not get your location.')));
    }
  }

  Future<void> _shareContact() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share a contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'Full name'), textCapitalization: TextCapitalization.words),
            const SizedBox(height: 8),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone', hintText: '+91 98765 43210'), keyboardType: TextInputType.phone),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty || phone.text.trim().isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name and phone are both required.')));
      return;
    }
    final replyTo = _replyTo;
    setState(() => _replyTo = null);
    await _controller.sendJson('contact', {'name': name.text.trim(), 'phone': phone.text.trim()}, replyToId: replyTo?.id);
    _scrollToEnd();
  }

  void _openMediaPicker() {
    final api = ref.read(sessionControllerProvider).api;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => MediaPickerSheet(
        api: api,
        onMakeSticker: _makeSticker,
        onMySticker: (Uint8List png) async {
          await _controller.sendFile(png, name: 'sticker.png', mime: 'image/png', extra: const {'sticker': true});
          _scrollToEnd();
        },
        onEmoji: (e) {
          final sel = _composerCtrl.selection;
          final text = _composerCtrl.text;
          final start = sel.isValid ? sel.start : text.length;
          final end = sel.isValid ? sel.end : text.length;
          _composerCtrl.value = TextEditingValue(
            text: text.replaceRange(start, end, e),
            selection: TextSelection.collapsed(offset: start + e.length),
          );
          setState(() {});
        },
        onSticker: (s) async {
          final replyTo = _replyTo;
          setState(() => _replyTo = null);
          await _controller.sendText(s, replyToId: replyTo?.id);
          _scrollToEnd();
        },
        onGif: (url) async {
          final replyTo = _replyTo;
          setState(() => _replyTo = null);
          await _controller.sendGif(url, replyToId: replyTo?.id);
          _scrollToEnd();
        },
      ),
    );
  }

  Future<void> _toggleSpeech() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_listening) {
      await _speech.stop();
      final text = _liveText.trim();
      setState(() => _listening = false);
      if (text.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text("Didn't catch any speech.")));
        return;
      }
      final current = _composerCtrl.text;
      _composerCtrl.text = current.isEmpty ? text : '$current $text';
      _composerCtrl.selection = TextSelection.collapsed(offset: _composerCtrl.text.length);
      _composerFocus.requestFocus();
      setState(() {});
      return;
    }
    _speechReady = _speechReady || await _speech.initialize();
    if (!_speechReady) {
      messenger.showSnackBar(const SnackBar(content: Text('Speech recognition isn\'t available on this phone.')));
      return;
    }
    setState(() {
      _listening = true;
      _liveText = '';
    });
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        localeId: _speechLang.replaceAll('-', '_'),
      ),
      onResult: (r) => setState(() => _liveText = r.recognizedWords),
    );
  }

  /// Discard the voice note (or dictation) instead of sending it.
  Future<void> _cancelRecording() async {
    if (_listening) {
      await _speech.cancel();
      setState(() {
        _listening = false;
        _liveText = '';
      });
      return;
    }
    if (!_recording) return;
    final path = await _recorder.stop();
    setState(() => _recording = false);
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  Future<void> _toggleRecording() async {
    if (_speechLang.isNotEmpty || _listening) return _toggleSpeech();
    if (_recording) {
      final path = await _recorder.stop();
      setState(() => _recording = false);
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      final replyTo = _replyTo;
      setState(() => _replyTo = null);
      await _controller.sendFile(bytes, name: 'voice-note.m4a', mime: 'audio/mp4', kind: 'voice', replyToId: replyTo?.id);
      _scrollToEnd();
      return;
    }
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() => _recording = true);
  }

  // ── Scrolling ──────────────────────────────────────────────────────

  void _scrollToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final max = _scrollCtrl.position.maxScrollExtent;
      if (animate) {
        _scrollCtrl.animateTo(max, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      } else {
        _scrollCtrl.jumpTo(max);
      }
    });
  }

  /// Tap on a reply quote: scroll to the original and flash it.
  /// The pinned message may be older than what's loaded — page back first.
  Future<void> _jumpToPinned(String messageId) async {
    var messages = ref.read(chatControllerProvider(widget.conversation)).messages;
    if (!messages.any((m) => m.id == messageId)) {
      await _controller.extendHistoryForSearch();
      messages = ref.read(chatControllerProvider(widget.conversation)).messages;
    }
    if (!mounted) return;
    if (!messages.any((m) => m.id == messageId)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That message is too far back to show.')));
      return;
    }
    await _jumpTo(messageId, messages);
  }

  Future<void> _jumpTo(String messageId, List<ChatMessage> messages) async {
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That message isn\'t loaded here.')));
      return;
    }
    // The list builds lazily — move roughly there first so the bubble exists.
    if (_bubbleKeys[messageId]?.currentContext == null && _scrollCtrl.hasClients) {
      final max = _scrollCtrl.position.maxScrollExtent;
      _scrollCtrl.jumpTo(max * index / (messages.length - 1).clamp(1, 1 << 30));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final ctx = _bubbleKeys[messageId]?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 250));
    }
    setState(() => _flashId = messageId);
    Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _flashId = null);
    });
  }

  // ── Message actions ────────────────────────────────────────────────

  void _toggleSelected(ChatMessage m) {
    setState(() => _selected.contains(m.id) ? _selected.remove(m.id) : _selected.add(m.id));
  }

  Future<void> _showActions(ChatMessage m, ChatState chatState) async {
    final session = ref.read(sessionControllerProvider);
    final mine = m.senderId == session.user?.id;
    final pending = _controller.isPending(m);
    final starred = ref.read(starredProvider).contains(m.id);
    final canCopy = m.kind == 'text' || m.kind == 'contact';
    final myReaction = m.reactions.where((r) => r['userId'] == session.user?.id).firstOrNull?['emoji'];

    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Wrap(
          children: [
            if (!pending && !m.deleted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in kReactionEmoji)
                      InkWell(
                        onTap: () => Navigator.pop(ctx, 'react:$e'),
                        borderRadius: BorderRadius.circular(24),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: myReaction == e ? VeyonColors.line : Colors.transparent,
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ),
            if (!pending && !m.deleted)
              ListTile(leading: const Icon(Icons.reply_rounded), title: const Text('Reply'), onTap: () => Navigator.pop(ctx, 'reply')),
            if (widget.conversation.isGroup && !mine && !pending && !m.deleted)
              ListTile(
                leading: const Icon(Icons.lock_outline_rounded),
                title: Text('Reply privately to ${_controller.senderName(m.senderId)}'),
                onTap: () => Navigator.pop(ctx, 'private'),
              ),
            if (canCopy && !m.deleted)
              ListTile(leading: const Icon(Icons.copy_rounded), title: const Text('Copy'), onTap: () => Navigator.pop(ctx, 'copy')),
            if (!pending && !m.deleted && !m.isViewOnce)
              ListTile(leading: const Icon(Icons.shortcut_rounded), title: const Text('Forward'), onTap: () => Navigator.pop(ctx, 'forward')),
            if (!pending && !m.deleted)
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: Text(chatState.pinned?.id == m.id ? 'Unpin' : 'Pin'),
                onTap: () => Navigator.pop(ctx, 'pin'),
              ),
            if (m.kind == 'text' && !m.deleted && m.plaintext != null)
              ListTile(leading: const Icon(Icons.translate_rounded), title: const Text('Translate'), onTap: () => Navigator.pop(ctx, 'translate')),
            if (!pending && !m.deleted)
              ListTile(
                leading: Icon(starred ? Icons.star_rounded : Icons.star_border_rounded, color: Colors.amber),
                title: Text(starred ? 'Unstar' : 'Star'),
                onTap: () => Navigator.pop(ctx, 'star'),
              ),
            if (mine && m.kind == 'text' && !pending && !m.deleted)
              ListTile(leading: const Icon(Icons.edit_rounded), title: const Text('Edit'), onTap: () => Navigator.pop(ctx, 'edit')),
            if (mine && !pending && !m.deleted)
              ListTile(leading: const Icon(Icons.info_outline_rounded), title: const Text('Message info'), onTap: () => Navigator.pop(ctx, 'info')),
            ListTile(leading: const Icon(Icons.check_circle_outline_rounded), title: const Text('Select'), onTap: () => Navigator.pop(ctx, 'select')),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: VeyonColors.danger),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action.startsWith('react:')) {
      await _controller.react(m, action.substring(6));
    } else if (action == 'reply') {
      _startReply(m);
    } else if (action == 'private') {
      final quote = {
        'group': widget.conversation.title ?? 'Group',
        'groupId': widget.conversation.id,
        'sender': _controller.senderName(m.senderId),
        'snippet': m.preview.length > 200 ? m.preview.substring(0, 200) : m.preview,
      };
      if (!await privateChatGate()) return; // private chats are 18+
      try {
        final json = await session.api.openDirectConversation(m.senderId);
        final direct = Conversation.fromJson(json);
        ref.read(pendingPrivateQuoteProvider.notifier).state = {...ref.read(pendingPrivateQuoteProvider), direct.id: quote};
        ref.read(conversationsProvider.notifier).refresh();
        if (mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: direct)));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errText(e))));
      }
    } else if (action == 'copy') {
      final text = m.kind == 'contact' ? '${m.payload?['name']} ${m.payload?['phone']}' : (m.plaintext ?? '');
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied.')));
    } else if (action == 'forward') {
      await _forward([m]);
    } else if (action == 'pin') {
      _controller.pin(chatState.pinned?.id == m.id ? null : m.id);
    } else if (action == 'translate') {
      await _translate(m, PrefsStore.instance.translateTo);
    } else if (action == 'star') {
      ref.read(starredProvider.notifier).toggle(m.id);
    } else if (action == 'edit') {
      _startEdit(m);
    } else if (action == 'info') {
      await showMessageInfo(context, session.api, m, isGroup: widget.conversation.isGroup);
    } else if (action == 'select') {
      setState(() => _selected.add(m.id));
    } else if (action == 'delete') {
      await _confirmDelete([m]);
    }
  }

  Future<void> _forward(List<ChatMessage> messages) async {
    final key = _controller.resolvedKey;
    if (key == null) return;
    final usable = messages.where((m) => !m.deleted && !_controller.isPending(m)).toList();
    if (usable.isEmpty) return;
    await showForwardSheet(context, ref, messages: usable, sourceKey: key, sourceConversationId: widget.conversation.id);
  }

  /// "Delete for me" for anything; "Delete for everyone" only when every
  /// chosen message is mine — the same rule as the website.
  Future<void> _confirmDelete(List<ChatMessage> messages) async {
    final myId = ref.read(sessionControllerProvider).user?.id;
    final allMine = messages.every((m) => m.senderId == myId);
    final n = messages.length;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Delete message' : 'Delete $n messages'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'me'), child: const Text('Delete for me')),
          if (allMine)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'everyone'),
              child: const Text('Delete for everyone', style: TextStyle(color: VeyonColors.danger)),
            ),
        ],
      ),
    );
    if (choice == 'me') await _controller.deleteForMe(messages);
    if (choice == 'everyone') await _controller.deleteForEveryone(messages);
    if (choice != null) _exitSelect();
  }

  // ── Search in chat ─────────────────────────────────────────────────

  List<String> _matches = [];
  int _matchIndex = -1;
  Timer? _searchDebounce;

  void _openSearch() {
    setState(() => _searching = true);
    _controller.extendHistoryForSearch(); // reach further back, in the background
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _searchKind = 'all';
      _searchCtrl.clear();
      _searchQuery = '';
      _matches = [];
      _matchIndex = -1;
    });
  }

  void _onSearchChanged(String v) {
    _searchQuery = v;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () => _runSearch(jump: true));
  }

  /// Text messages containing the query; starts at the newest match.
  void _runSearch({required bool jump}) {
    final q = _searchQuery.trim().toLowerCase();
    final messages = ref.read(chatControllerProvider(widget.conversation)).messages;
    final matches = q.isEmpty && _searchKind == 'all'
        ? <String>[]
        : messages
            .where((m) => !m.deleted && _passesKind(m))
            .where((m) => q.isEmpty || (m.kind == 'text' ? m.preview : (m.payload?['name'] as String? ?? '')).toLowerCase().contains(q))
            .map((m) => m.id)
            .toList();
    final current = _matchIndex >= 0 && _matchIndex < _matches.length ? _matches[_matchIndex] : null;
    setState(() {
      _matches = matches;
      _matchIndex = jump || current == null ? matches.length - 1 : matches.indexOf(current);
    });
    if (jump && matches.isNotEmpty) _jumpTo(matches.last, messages);
  }

  static final _urlRe = RegExp(r'https?://\S+', caseSensitive: false);

  bool _passesKind(ChatMessage m) {
    final mime = m.payload?['mime'] as String? ?? '';
    return switch (_searchKind) {
      'photos' => m.kind == 'file' && mime.startsWith('image/') && !m.isSticker && !m.isGif,
      'videos' => m.kind == 'file' && mime.startsWith('video/'),
      'docs' => m.kind == 'file' && !mime.startsWith('image/') && !mime.startsWith('video/'),
      'links' => m.kind == 'text' && _urlRe.hasMatch(m.plaintext ?? ''),
      'voice' => m.kind == 'voice',
      _ => m.kind == 'text',
    };
  }

  Future<void> _jumpToDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: now, initialDate: now);
    if (d == null) return;
    final messages = ref.read(chatControllerProvider(widget.conversation)).messages;
    final hit = messages.where((m) => (DateTime.tryParse(m.createdAt)?.toLocal() ?? now).isAfter(d)).firstOrNull;
    if (hit != null) {
      _jumpTo(hit.id, messages);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No messages from that day on.')));
    }
  }

  Widget _searchFilters() => SizedBox(
        height: 46,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          children: [
            for (final (k, l) in const [('all', 'All'), ('photos', 'Photos'), ('videos', 'Videos'), ('links', 'Links'), ('docs', 'Docs'), ('voice', 'Voice')])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(l),
                  selected: _searchKind == k,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    setState(() => _searchKind = k);
                    _runSearch(jump: true);
                  },
                ),
              ),
            ActionChip(
              avatar: const Icon(Icons.event_rounded, size: 16),
              label: const Text('Date'),
              visualDensity: VisualDensity.compact,
              onPressed: _jumpToDate,
            ),
          ],
        ),
      );

  void _stepSearch(int dir) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + dir + _matches.length) % _matches.length);
    _jumpTo(_matches[_matchIndex], ref.read(chatControllerProvider(widget.conversation)).messages);
  }

  // ── Chat menu actions ──────────────────────────────────────────────

  Future<void> _openInfo(Conversation c) async {
    final result = await Navigator.of(context).push<InfoResult>(MaterialPageRoute(
      builder: (_) => c.isGroup ? GroupInfoScreen(conversation: c) : ContactInfoScreen(conversationId: c.id, fallback: c),
    ));
    if (!mounted) return;
    if (result == InfoResult.search) _openSearch();
    if (result == InfoResult.chatGone) Navigator.of(context).pop();
    if (result == InfoResult.cleared) _controller.clearLocal();
  }

  Future<void> _onMenu(String v, Conversation c) async {
    final convos = ref.read(conversationsProvider.notifier);
    void toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
    switch (v) {
      case 'info':
        await _openInfo(c);
      case 'search':
        _openSearch();
      case 'select':
        setState(() => _selectMode = true);
      case 'archive':
        final c = ref.read(conversationsProvider.notifier).byId(widget.conversation.id) ?? widget.conversation;
        try {
          await ref.read(conversationsProvider.notifier).setArchived(c.id, !c.archived);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(c.archived ? 'Chat unarchived.' : 'Chat archived — find it under “Archived”.'),
            ));
            if (!c.archived) Navigator.of(context).maybePop();
          }
        } catch (_) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not do that — check your connection.')));
        }
      case 'notes':
        await showChatNotes(context, ref, widget.conversation, _controller.resolvedKey);
      case 'lock':
        final live = ref.read(conversationsProvider.notifier).byId(widget.conversation.id) ?? widget.conversation;
        final locked = await toggleChatLock(context, ref, live);
        if (locked == true && mounted && !ref.read(chatLockProvider).open) Navigator.of(context).maybePop();
      case 'mute':
        await chooseMute(context, ref, c);
      case 'favorite':
        try {
          await convos.setFavorite(c.id, !c.favorite);
        } catch (_) {
          toast('Could not change that — check your connection.');
        }
      case 'wallpaper':
        await _openWallpaperPicker();
      case 'list':
        await showAddToListSheet(context, ref, c.id);
      case 'schedule':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScheduleScreen(conversation: c)));
      case 'verify':
        await showSafetyNumber(context, ref.read(sessionControllerProvider), c);
      case 'close':
        Navigator.of(context).pop();
      case 'block':
        await toggleBlockFlow(context, ref, c);
      case 'clear':
        if (await clearChatFlow(context, ref, c)) _controller.clearLocal();
      case 'delete':
        if (await deleteChatFlow(context, ref, c) && mounted) Navigator.of(context).pop();
      case 'disappearing':
        final current = ref.read(chatControllerProvider(widget.conversation)).disappearSeconds;
        final picked = await showDisappearingPicker(context, current);
        if (picked != null && picked != current) _controller.setDisappearing(picked);
      case 'summarize':
        await _summarize();
      case 'export':
        await _export(c);
      case 'chess' || 'pong' || 'candy' || 'ludo' || 'tictactoe' || 'snakes':
        if (!ref.read(presenceProvider).online.contains(c.peer!.id)) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${c.peer!.displayName} is offline — they need to be online to play.')));
          return;
        }
        ref.read(liveGameControllerProvider.notifier).sendInvite(
              conversationId: c.id,
              peerUserId: c.peer!.id,
              peerName: c.peer!.displayName,
              game: v,
            );
    }
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    AppVisibility.openChatId.value = widget.conversation.id; // no notifications for the chat on screen
    if (!widget.conversation.isGroup) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!await privateChatGate() && mounted) Navigator.of(context).maybePop(); // private chats are 18+
      });
    }
    if (widget.initialShare != null) WidgetsBinding.instance.addPostFrameCallback((_) => _sendShared(widget.initialShare!));
    final jump = widget.jumpToMessageId;
    if (jump != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        for (var i = 0; i < 40 && ref.read(chatControllerProvider(widget.conversation)).loading; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (!mounted) return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (mounted) await _jumpToPinned(jump);
      });
    }
    final product = ref.read(pendingProductProvider);
    if (product != null && product['sellerId'] == widget.conversation.peer?.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        ref.read(pendingProductProvider.notifier).state = null;
        for (var i = 0; i < 60 && _controller.resolvedKey == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (!mounted) return;
        }
        await _controller.sendJson('product', product);
        _scrollToEnd();
      });
    }
    _composerCtrl.text = PrefsStore.instance.draftFor(widget.conversation.id); // pick up where I left off
    ref.read(quickRepliesProvider.notifier).load(); // "/" shortcuts
    ref.read(presenceProvider.notifier).refresh(); // a new contact shows as online straight away
    final myId = ref.read(sessionControllerProvider).user?.id;
    if (myId != null) {
      final ids = (ref.read(conversationsProvider).valueOrNull ?? const []).map((c) => c.id);
      SmartCompose.instance.build(myId, ids);
    }
    // The chat's controller outlives the screen, so on a re-open there may be
    // no "messages changed" event to trigger the first scroll — do it here.
    _scrollToEnd(animate: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(chatControllerProvider(widget.conversation)).messages.isNotEmpty) _scrolledToEndOnce = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The controller is keyed on the conversation the screen was opened
    // with; mute/favourite/status are read from the live chat list.
    final conversation = widget.conversation;
    ref.watch(conversationsProvider);
    final live = ref.read(conversationsProvider.notifier).byId(conversation.id) ?? conversation;
    final chatState = ref.watch(chatControllerProvider(conversation));
    final controller = ref.read(chatControllerProvider(conversation).notifier);
    final session = ref.watch(sessionControllerProvider);
    final iBlockedThem = !live.isGroup && ref.watch(blockedProvider).any((u) => u.id == live.peer?.id);
    final requestForMe = live.isPending && live.requestedBy != session.user?.id;
    final myId = session.user?.id;
    final structure = session.user?.appearance?['structure'] as String? ?? 'floating';

    // Errors from actions (refused message, offline edit, …) → snackbar.
    ref.listen<ChatState>(chatControllerProvider(conversation), (prev, next) {
      if (next.error != null && next.error != prev?.error && next.messages.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.error!)));
        controller.clearError();
      }
      if (next.notice != null && next.notice != prev?.notice) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.notice!)));
        controller.clearError();
      }
      // Message effects for a text that just arrived live (not history).
      if (prev != null && !prev.loading && prev.messages.isNotEmpty && next.messages.length > prev.messages.length) {
        final last = next.messages.last;
        final fresh = DateTime.tryParse(last.createdAt)?.isAfter(DateTime.now().subtract(const Duration(minutes: 1))) ?? false;
        if (last.id != prev.messages.last.id && last.senderId != myId && last.kind == 'text' && fresh) {
          maybePlayEffect(last.plaintext);
        }
      }
      if (!_scrolledToEndOnce && next.messages.isNotEmpty) {
        _scrolledToEndOnce = true;
        _scrollToEnd(animate: false);
      } else if (prev != null && next.messages.length > prev.messages.length &&
          next.messages.last.id != prev.messages.lastOrNull?.id && // appended, not older history
          _scrollCtrl.hasClients && _scrollCtrl.position.maxScrollExtent - _scrollCtrl.offset < 300) {
        _scrollToEnd(); // a new message while already near the bottom
      }
      // Older history arriving for search → recount matches, keep my place.
      if (_searching && _searchQuery.trim().isNotEmpty && prev != null && next.messages.length != prev.messages.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _runSearch(jump: false);
        });
      }
    });

    // Search keeps the whole chat visible and jumps between matches (like the website).
    final visibleMessages = chatState.messages;
    final selecting = _selectMode || _selected.isNotEmpty;
    final selectedMessages = chatState.messages.where((m) => _selected.contains(m.id)).toList();

    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) _exitSelect();
      },
      child: Scaffold(
        appBar: selecting ? _selectionAppBar(selectedMessages) : _normalAppBar(live, chatState, iBlockedThem),
        body: Column(
          children: [
            if (chatState.offline)
              Container(
                width: double.infinity,
                color: const Color(0xFF3A2A12),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                child: const Text(
                  'Offline — showing saved messages. New messages will send once you\'re back online.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFFFD9A0), fontSize: 12),
                ),
              ),
            if (conversation.isGroup && chatState.callParticipants.isNotEmpty)
              _GroupCallBanner(
                count: chatState.callParticipants.length,
                iAmIn: chatState.callParticipants.contains(myId),
                onJoin: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => GroupCallScreen(conversation: conversation, callType: 'video'))),
              ),
            if (chatState.pinned != null && !_searching)
              PinnedBar(
                pinned: chatState.pinned!,
                pinnedByName: chatState.pinnedBy == null ? null : controller.senderName(chatState.pinnedBy!),
                onTap: () => _jumpToPinned(chatState.pinned!.id),
                onUnpin: () => controller.pin(null),
              ),
            Expanded(
              child: _ChatBackground(
                conversation: live,
                gradient: _wallpaperGradient(live.wallpaper),
                child: chatState.loading
                    ? const Center(child: CircularProgressIndicator())
                    : chatState.error != null && chatState.messages.isEmpty
                        ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(chatState.error!, textAlign: TextAlign.center)))
                        : visibleMessages.isEmpty
                            ? Center(
                                child: Text(_searching ? 'No matches' : 'No messages yet — say hi 👋',
                                    style: const TextStyle(color: VeyonColors.muted)),
                              )
                            : MediaQuery(
                              // Settings → Chat text size.
                              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(chatTextScale)),
                              child: ListView.builder(
                                controller: _scrollCtrl,
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                                itemCount: visibleMessages.length + (chatState.disappearSeconds > 0 ? 1 : 0),
                                itemBuilder: (context, rawIndex) {
                                  final noteShown = chatState.disappearSeconds > 0;
                                  if (noteShown && rawIndex == 0) {
                                    return SystemNote(
                                      icon: Icons.timer_outlined,
                                      text: 'Disappearing messages are on. New messages vanish from this chat '
                                          '${disappearLabel(chatState.disappearSeconds).toLowerCase()} after they’re sent.',
                                    );
                                  }
                                  final i = rawIndex - (noteShown ? 1 : 0);
                                  final msg = visibleMessages[i];
                                  final prev = i > 0 ? visibleMessages[i - 1] : null;
                                  final key = _bubbleKeys.putIfAbsent(msg.id, GlobalKey.new);
                                  final newDay = prev == null || _dayKey(prev.createdAt) != _dayKey(msg.createdAt);
                                  return Column(
                                    key: key,
                                    children: [
                                      if (newDay) _DayDivider(iso: msg.createdAt),
                                      SwipeToReply(
                                        enabled: !selecting && !msg.deleted && !controller.isPending(msg) && !requestForMe,
                                        onReply: () => _startReply(msg),
                                        child: _Bubble(
                                        message: msg,
                                        mine: msg.senderId == myId,
                                        myId: myId,
                                        boxed: structure == 'boxed',
                                        session: session,
                                        convKey: controller.resolvedKey,
                                        pending: controller.isPending(msg),
                                        showSender: conversation.isGroup && msg.senderId != myId &&
                                            (prev == null || prev.senderId != msg.senderId || newDay),
                                        senderName: controller.senderName(msg.senderId),
                                        senderColor: chatState.members[msg.senderId]?['avatarColor'] as String?,
                                        replyTo: msg.replyToId == null
                                            ? null
                                            : chatState.messages.where((m) => m.id == msg.replyToId).firstOrNull,
                                        replyToSender: (id) => controller.senderName(id),
                                        selected: _selected.contains(msg.id),
                                        flash: _flashId == msg.id,
                                        onTap: selecting ? () => _toggleSelected(msg) : null,
                                        onLongPress: selecting ? () => _toggleSelected(msg) : () => _showActions(msg, chatState),
                                        onReplyTap: (id) => _jumpTo(id, chatState.messages),
                                        onReactionTap: (emoji) => controller.react(msg, emoji),
                                        isGroup: conversation.isGroup,
                                        pinned: chatState.pinned?.id == msg.id,
                                        translation: _translations[msg.id],
                                        onTranslationHide: () => setState(() => _translations.remove(msg.id)),
                                        onTranslationChange: () async {
                                          final code = await pickLanguage(context, PrefsStore.instance.translateTo);
                                          if (code != null) {
                                            PrefsStore.instance.translateTo = code;
                                            await _translate(msg, code);
                                          }
                                        },
                                        onVote: (option) => controller.vote(msg, option),
                                        onShowVotes: () => showPollVotes(context, msg, controller.senderName),
                                        onClosePoll: msg.kind == 'poll' && (msg.senderId == session.user?.id || live.iAmAdmin)
                                            ? () async {
                                                final ok = await confirmAction(context, 'Close poll', 'Close this poll now? No one can vote after that.',
                                                    ok: 'Close poll', danger: true);
                                                if (ok) controller.closePoll(msg);
                                              }
                                            : null,
                                        onOpenViewOnce: () => _openViewOnce(msg),
                                      ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              ),
              ),
            ),
            if (requestForMe)
              _RequestBar(
                name: live.displayName('This person'),
                onAccept: () async {
                  try {
                    await session.api.acceptRequest(live.id);
                    await ref.read(conversationsProvider.notifier).refresh();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request accepted.')));
                    }
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not accept — check your connection.')));
                    }
                  }
                },
                onDecline: () async {
                  final ok = await confirmAction(context, 'Decline request', 'Decline this request from ${live.displayName('them')}?',
                      ok: 'Decline', danger: true);
                  if (!ok) return;
                  try {
                    await session.api.declineRequest(live.id);
                    ref.read(conversationsProvider.notifier).remove(live.id);
                    if (context.mounted) Navigator.of(context).pop();
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not decline — check your connection.')));
                    }
                  }
                },
              )
            else if (live.isPending)
              const SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('Waiting for them to accept your request…', style: TextStyle(color: VeyonColors.muted)),
                ),
              )
            else if (iBlockedThem)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('You blocked this contact.', style: TextStyle(color: VeyonColors.muted)),
                      ),
                      TextButton(onPressed: () => toggleBlockFlow(context, ref, live), child: const Text('Unblock')),
                    ],
                  ),
                ),
              )
            else if (!selecting)
              if (live.sendLocked) _AdminsOnlyBar(announcement: live.isAnnouncement) else _composer(controller),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar(List<ChatMessage> selected) {
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => _exitSelect()),
      title: Text('${selected.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Star',
          icon: const Icon(Icons.star_border_rounded),
          onPressed: () {
            for (final m in selected) {
              ref.read(starredProvider.notifier).toggle(m.id);
            }
            _exitSelect();
          },
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy_rounded),
          onPressed: () async {
            final text = selected.where((m) => m.kind == 'text' && !m.deleted).map((m) => m.plaintext ?? '').join('\n');
            await Clipboard.setData(ClipboardData(text: text));
            _exitSelect();
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied.')));
          },
        ),
        IconButton(
          tooltip: 'Forward',
          icon: const Icon(Icons.shortcut_rounded),
          onPressed: () async {
            await _forward(selected);
            _exitSelect();
          },
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => _confirmDelete(selected),
        ),
      ],
    );
  }

  PreferredSizeWidget _normalAppBar(Conversation conversation, ChatState chatState, bool iBlockedThem) {
    final canCall = conversation.status != 'pending' && !iBlockedThem;
    final presence = ref.watch(presenceProvider);
    final peer = conversation.peer;
    final online = peer != null && presence.online.contains(peer.id);
    final String subtitle;
    if (chatState.peerTyping) {
      subtitle = 'typing…';
    } else if (conversation.isGroup) {
      final n = conversation.memberCount ?? chatState.members.length;
      subtitle = '$n member${n == 1 ? '' : 's'}';
    } else if (online) {
      subtitle = 'online';
    } else {
      subtitle = lastSeenLabel(presence.lastSeen[peer?.id] ?? peer?.lastSeen);
    }

    return AppBar(
      titleSpacing: 0,
      bottom: _searching ? PreferredSize(preferredSize: const Size.fromHeight(46), child: _searchFilters()) : null,
      title: _searching
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(hintText: 'Search in this chat', border: InputBorder.none),
                    onChanged: _onSearchChanged,
                    onSubmitted: (_) => _stepSearch(-1),
                  ),
                ),
                Text(
                  _matches.isNotEmpty ? '${_matchIndex + 1} / ${_matches.length}' : (_searchQuery.trim().isEmpty ? '' : 'No results'),
                  style: const TextStyle(fontSize: 12.5, color: VeyonColors.muted),
                ),
                IconButton(tooltip: 'Older match', icon: const Icon(Icons.keyboard_arrow_up_rounded), onPressed: _matches.isEmpty ? null : () => _stepSearch(-1)),
                IconButton(tooltip: 'Newer match', icon: const Icon(Icons.keyboard_arrow_down_rounded), onPressed: _matches.isEmpty ? null : () => _stepSearch(1)),
              ],
            )
          : InkWell(
              onTap: () => _openInfo(conversation),
              child: Row(
                children: [
                  conversation.isGroup
                      ? Avatar(label: conversation.title ?? 'Group', color: conversation.avatarColor, radius: 18)
                      : Avatar(label: peer?.displayName ?? '?', color: peer?.avatarColor, photoUrl: peer?.photoUrl, radius: 18, online: online),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [
                          Flexible(child: Text(conversation.displayName('Chat'), overflow: TextOverflow.ellipsis)),
                          if (chatState.disappearSeconds > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.fromLTRB(4, 1, 6, 1),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.timer_outlined, size: 12, color: Theme.of(context).colorScheme.secondary),
                                const SizedBox(width: 2),
                                Text(
                                  {86400: '24h', 604800: '7d', 7776000: '90d'}[chatState.disappearSeconds] ?? '',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.secondary),
                                ),
                              ]),
                            ),
                        ]),
                        Text(
                          subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: chatState.peerTyping || online ? VeyonColors.bubbleMe2 : VeyonColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      actions: [
        if (!_searching && !conversation.isGroup && canCall && peer != null) ...[
          IconButton(
            tooltip: 'Audio call',
            icon: const Icon(Icons.call_rounded),
            onPressed: () => ref.read(callControllerProvider.notifier).startCall(
                  conversationId: conversation.id,
                  peerUserId: peer.id,
                  peerName: peer.displayName,
                  callType: 'audio',
                ),
          ),
          IconButton(
            tooltip: 'Video call',
            icon: const Icon(Icons.videocam_rounded),
            onPressed: () => ref.read(callControllerProvider.notifier).startCall(
                  conversationId: conversation.id,
                  peerUserId: peer.id,
                  peerName: peer.displayName,
                  callType: 'video',
                ),
          ),
        ],
        if (!_searching && conversation.isGroup) ...[
          IconButton(
            tooltip: 'Group audio call',
            icon: const Icon(Icons.call_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => GroupCallScreen(conversation: conversation, callType: 'audio'))),
          ),
          IconButton(
            tooltip: 'Group video call',
            icon: const Icon(Icons.videocam_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => GroupCallScreen(conversation: conversation, callType: 'video'))),
          ),
        ],
        if (_searching) IconButton(icon: const Icon(Icons.close_rounded), onPressed: _closeSearch),
        if (!_searching)
          PopupMenuButton<String>(
            onSelected: (v) => _onMenu(v, conversation),
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'info', child: Text(conversation.isGroup ? 'Group info' : 'Contact info')),
              const PopupMenuItem(value: 'search', child: Text('Search in chat')),
              PopupMenuItem(value: 'lock', child: Text(conversation.locked ? 'Remove chat lock' : 'Lock chat')),
              const PopupMenuItem(value: 'notes', child: Text('Notes')),
              PopupMenuItem(value: 'archive', child: Text(conversation.archived ? 'Unarchive chat' : 'Archive chat')),
              const PopupMenuItem(value: 'select', child: Text('Select messages')),
              PopupMenuItem(value: 'mute', child: Text(conversation.muted ? 'Unmute notifications' : 'Mute notifications')),
              PopupMenuItem(value: 'favorite', child: Text(conversation.favorite ? 'Remove from favourites' : 'Add to favourites')),
              const PopupMenuItem(value: 'list', child: Text('Add to list')),
              const PopupMenuItem(value: 'wallpaper', child: Text('Chat wallpaper')),
              if (!(conversation.isPending && conversation.requestedBy != ref.read(sessionControllerProvider).user?.id))
                const PopupMenuItem(value: 'schedule', child: Text('Schedule a message')),
              if (!(conversation.isPending && conversation.requestedBy != ref.read(sessionControllerProvider).user?.id))
                PopupMenuItem(
                  value: 'disappearing',
                  child: Text(chatState.disappearSeconds > 0
                      ? 'Disappearing messages · ${disappearLabel(chatState.disappearSeconds)}'
                      : 'Disappearing messages'),
                ),
              const PopupMenuItem(value: 'summarize', child: Text('✨ Summarize chat')),
              const PopupMenuItem(value: 'export', child: Text('Export chat')),
              if (!conversation.isGroup) const PopupMenuItem(value: 'verify', child: Text('Verify encryption')),
              if (!conversation.isGroup && conversation.status == 'accepted' && canCall && peer != null) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'chess', child: Text('Play Chess')),
                const PopupMenuItem(value: 'pong', child: Text('Play Pong')),
                const PopupMenuItem(value: 'candy', child: Text('Play Candy Crush')),
                const PopupMenuItem(value: 'ludo', child: Text('Play Ludo')),
                const PopupMenuItem(value: 'tictactoe', child: Text('Play Tic-tac-toe')),
                const PopupMenuItem(value: 'snakes', child: Text('Play Snake & Ladder')),
              ],
              const PopupMenuItem(value: 'close', child: Text('Close chat')),
              const PopupMenuDivider(),
              if (!conversation.isGroup)
                PopupMenuItem(
                  value: 'block',
                  child: Text(iBlockedThem ? 'Unblock ${peer?.displayName ?? ''}' : 'Block ${peer?.displayName ?? ''}',
                      style: const TextStyle(color: VeyonColors.danger)),
                ),
              const PopupMenuItem(value: 'clear', child: Text('Clear chat', style: TextStyle(color: VeyonColors.danger))),
              const PopupMenuItem(value: 'delete', child: Text('Delete chat', style: TextStyle(color: VeyonColors.danger))),
            ],
          ),
      ],
    );
  }

  /// Smart compose: while typing, one chip that finishes the sentence (tap
  /// to accept); with an empty box, quick replies to their last message.
  Widget _suggestionBar() {
    final typed = _composerCtrl.text;

    // "/shortcut" → the quick replies popup instead of suggestions.
    final qr = ref.watch(quickRepliesProvider);
    final qrMatches = ref.read(quickRepliesProvider.notifier).matchesFor(typed);
    if (qrMatches != null) {
      return QuickReplyPopup(
        matches: qrMatches,
        anySaved: qr.isNotEmpty,
        onPick: (r) {
          _composerCtrl.value = TextEditingValue(text: r.body, selection: TextSelection.collapsed(offset: r.body.length));
          PrefsStore.instance.setDraft(widget.conversation.id, r.body);
          setState(() {});
        },
        onManage: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuickRepliesScreen(startAdding: qr.isEmpty))),
      );
    }

    final List<(String label, String value)> chips;
    var showSmart = false;
    if (typed.trim().length >= 3) {
      final rest = SmartCompose.instance.predict(typed);
      if (rest.trim().isEmpty) return const SizedBox.shrink();
      final tail = typed.length > 24 ? typed.substring(typed.length - 24) : typed;
      chips = [('…$tail$rest', typed + rest)];
    } else if (typed.isEmpty) {
      final messages = ref.read(chatControllerProvider(widget.conversation)).messages;
      final myId = ref.read(sessionControllerProvider).user?.id;
      String? lastIncoming;
      for (final m in messages.reversed) {
        if (m.senderId == myId) break; // I spoke last — no quick replies
        if (m.deleted) continue;
        if (m.kind == 'text') lastIncoming = m.plaintext;
        break;
      }
      chips = [for (final r in SmartCompose.instance.quickReplies(lastIncoming)) (r, r)];
      showSmart = lastIncoming != null;
    } else {
      return const SizedBox.shrink();
    }
    final messages = ref.read(chatControllerProvider(widget.conversation)).messages;
    final aiFresh = _aiReplies != null && messages.isNotEmpty && _aiRepliesFor == messages.last.id;
    if (chips.isEmpty && !showSmart) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.secondary;
    void fill(String value) {
      _composerCtrl.value = TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length));
      _composerFocus.requestFocus();
      PrefsStore.instance.setDraft(widget.conversation.id, value);
      setState(() {});
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        children: [
          for (final (label, value) in chips)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(label: Text(label, overflow: TextOverflow.ellipsis), onPressed: () => fill(value)),
            ),
          if (showSmart && aiFresh)
            for (final r in _aiReplies!)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  avatar: Icon(Icons.auto_awesome_rounded, size: 15, color: accent),
                  label: Text(r, overflow: TextOverflow.ellipsis),
                  onPressed: () => fill(r),
                ),
              )
          else if (showSmart)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: _aiThinking
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.auto_awesome_rounded, size: 15, color: accent),
                label: Text(_aiThinking ? 'Thinking…' : 'Smart replies', style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
                side: BorderSide(color: accent.withValues(alpha: 0.5)),
                onPressed: _aiThinking ? null : () => _askSmartReplies(messages),
              ),
            ),
        ],
      ),
    );
  }

  /// "@" (or "@ev…") at the cursor in a group I admin.
  bool _everyoneHint() {
    final c = ref.read(conversationsProvider.notifier).byId(widget.conversation.id) ?? widget.conversation;
    if (!c.iAmAdmin) return false;
    final sel = _composerCtrl.selection.baseOffset;
    final upTo = _composerCtrl.text.substring(0, sel < 0 ? _composerCtrl.text.length : sel);
    final m = RegExp(r'(?:^|\s)@(\w*)$').firstMatch(upTo);
    return m != null && 'everyone'.startsWith(m.group(1)!.toLowerCase());
  }

  Widget _everyoneChip() {
    final c = ref.read(conversationsProvider.notifier).byId(widget.conversation.id) ?? widget.conversation;
    final accent = Theme.of(context).colorScheme.secondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            final t = _composerCtrl.text;
            final sel = _composerCtrl.selection.baseOffset < 0 ? t.length : _composerCtrl.selection.baseOffset;
            final before = t.substring(0, sel).replaceFirst(RegExp(r'@\w*$'), '@everyone ');
            _composerCtrl.value = TextEditingValue(text: before + t.substring(sel), selection: TextSelection.collapsed(offset: before.length));
            setState(() {});
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              Icon(Icons.campaign_rounded, color: accent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('@everyone', style: TextStyle(fontWeight: FontWeight.w800)),
                  Text('Notify all ${c.memberCount ?? ''} members, even if they muted the chat',
                      style: const TextStyle(color: VeyonColors.muted, fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _composer(ChatController controller) {
    final hasText = _composerCtrl.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyTo != null)
            _ComposerBar(
              icon: Icons.reply_rounded,
              title: 'Replying to ${controller.senderName(_replyTo!.senderId)}',
              text: _replyTo!.preview,
              onClose: () => setState(() => _replyTo = null),
            ),
          if (_editing != null)
            _ComposerBar(
              icon: Icons.edit_rounded,
              title: 'Editing message',
              text: _editing!.plaintext ?? '',
              onClose: _cancelEdit,
            ),
          if (ref.watch(pendingPrivateQuoteProvider)[widget.conversation.id] case final q?)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 4, 0),
              child: Row(children: [
                Expanded(child: PrivateQuote(quote: q)),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => ref.read(pendingPrivateQuoteProvider.notifier).state = {
                    ...ref.read(pendingPrivateQuoteProvider),
                  }..remove(widget.conversation.id),
                ),
              ]),
            ),
          if (_editing == null && _everyoneHint()) _everyoneChip(),
          if (_editing == null) _suggestionBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 10, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Emoji, GIFs & stickers',
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  onPressed: _openMediaPicker,
                ),
                if (_editing == null)
                  IconButton(tooltip: 'Attach', icon: const Icon(Icons.attach_file_rounded), onPressed: _openAttachMenu),
                Expanded(
                  child: TextField(
                    controller: _composerCtrl,
                    focusNode: _composerFocus,
                    onChanged: _onComposerChanged,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: _listening
                          ? (_liveText.isEmpty ? 'Listening… tap ■ when done' : _liveText)
                          : _recording
                              ? 'Recording… tap ■ to send'
                              : 'Message',
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (!hasText && _editing == null && !_recording && !_listening)
                  PopupMenuButton<String>(
                    tooltip: 'Voice-to-text language',
                    initialValue: _speechLang,
                    onSelected: (v) => setState(() => _speechLang = v),
                    itemBuilder: (_) => [
                      for (final e in _speechLangs.entries) PopupMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        _speechLang.isEmpty ? '🎤' : _speechLang.split('-').first.toUpperCase(),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                if (_recording || _listening)
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _cancelRecording,
                  ),
                if (!hasText && _editing == null)
                  IconButton(
                    tooltip: _speechLang.isEmpty ? 'Record a voice note' : 'Speak to type (${_speechLangs[_speechLang]})',
                    icon: Icon(
                      _recording || _listening ? Icons.stop_circle_rounded : (_speechLang.isEmpty ? Icons.mic_rounded : Icons.keyboard_voice_rounded),
                      color: _recording || _listening ? VeyonColors.danger : null,
                    ),
                    onPressed: _toggleRecording,
                  )
                else
                  _SendButton(onTap: _send, icon: _editing != null ? Icons.check_rounded : Icons.arrow_upward_rounded),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openWallpaperPicker() async {
    final live = ref.read(conversationsProvider.notifier).byId(widget.conversation.id) ?? widget.conversation;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141A33),
      builder: (ctx) => _WallpaperPickerSheet(conversation: live),
    );
  }

  LinearGradient? _wallpaperGradient(String? wallpaper) {
    if (wallpaper == null || wallpaper == 'photo') return null;
    final colors = kWallpaperPresets[wallpaper];
    if (colors == null) return null;
    return LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors);
  }
}

/// The chat's background: a preset gradient, or the photo I uploaded for
/// this chat under a dark scrim (keeps bubbles readable) with my chosen fit —
/// the website's applyWallpaper(). The photo is kept on the phone for offline.
class _ChatBackground extends ConsumerStatefulWidget {
  final Conversation conversation;
  final Gradient? gradient;
  final Widget child;
  const _ChatBackground({required this.conversation, required this.gradient, required this.child});

  @override
  ConsumerState<_ChatBackground> createState() => _ChatBackgroundState();
}

/// Bumped after a new upload so the saved copy is refreshed.
final Map<String, int> wallpaperVersions = {};

class _ChatBackgroundState extends ConsumerState<_ChatBackground> {
  Uint8List? _photo;
  String? _loadedKey;

  String get _cacheKey => 'wallpaper_${widget.conversation.id}_${wallpaperVersions[widget.conversation.id] ?? 0}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(covariant _ChatBackground old) {
    super.didUpdateWidget(old);
    _maybeLoad();
  }

  Future<void> _maybeLoad() async {
    if (widget.conversation.wallpaper != 'photo') return;
    final key = _cacheKey;
    if (_loadedKey == key) return;
    _loadedKey = key;
    final cache = FileCache();
    final saved = await cache.load(key);
    if (saved != null && saved.isNotEmpty) {
      if (mounted) setState(() => _photo = saved);
      return;
    }
    try {
      final bytes = Uint8List.fromList(await ref.read(sessionControllerProvider).api.downloadWallpaperPhoto(widget.conversation.id));
      await cache.save(key, bytes);
      if (mounted) setState(() => _photo = bytes);
    } catch (_) {
      _loadedKey = null; // offline — try again on the next rebuild
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.conversation.wallpaper == 'photo' ? _photo : null;
    if (photo == null) {
      return DecoratedBox(decoration: BoxDecoration(gradient: widget.gradient), child: widget.child);
    }
    final fit = widget.conversation.wallpaperFit;
    return DecoratedBox(
      decoration: BoxDecoration(
        image: DecorationImage(
          image: MemoryImage(photo),
          fit: switch (fit) { 'contain' => BoxFit.contain, 'fill' => BoxFit.fill, 'tile' => BoxFit.none, _ => BoxFit.cover },
          repeat: fit == 'tile' ? ImageRepeat.repeat : ImageRepeat.noRepeat,
          alignment: fit == 'tile' ? Alignment.topLeft : Alignment.center,
          colorFilter: const ColorFilter.mode(Color(0x8C0A0A14), BlendMode.srcATop),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Same choices as the website's voice-to-text dropdown.
const _speechLangs = {
  '': 'Voice note',
  'en-US': 'English',
  'ta-IN': 'Tamil',
  'hi-IN': 'Hindi',
  'te-IN': 'Telugu',
  'kn-IN': 'Kannada',
  'ml-IN': 'Malayalam',
};

String _dayKey(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  return d == null ? '' : '${d.year}-${d.month}-${d.day}';
}

/// "Today" / "Yesterday" / date separator between days, like the website.
class _DayDivider extends StatelessWidget {
  final String iso;
  const _DayDivider({required this.iso});

  @override
  Widget build(BuildContext context) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final label = day == today
        ? 'Today'
        : day == today.subtract(const Duration(days: 1))
            ? 'Yesterday'
            : '${d.day} ${months[d.month - 1]}${d.year != now.year ? ' ${d.year}' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(10)),
          child: Text(label, style: const TextStyle(color: VeyonColors.muted, fontSize: 11.5)),
        ),
      ),
    );
  }
}

/// "Call in progress · 3 joined  [Join]" at the top of a group chat while a
/// group call is running — the website's group-call banner.
class _GroupCallBanner extends StatelessWidget {
  final int count;
  final bool iAmIn;
  final VoidCallback onJoin;
  const _GroupCallBanner({required this.count, required this.iAmIn, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF123D2A),
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      child: Row(
        children: [
          const Icon(Icons.videocam_rounded, size: 18, color: Color(0xFF7CE0A8)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              iAmIn ? "You're in this call · $count joined" : 'Call in progress · $count joined',
              style: const TextStyle(color: Color(0xFFCFF5E0), fontSize: 13),
            ),
          ),
          if (!iAmIn) TextButton(onPressed: onJoin, child: const Text('Join')),
        ],
      ),
    );
  }
}

/// Shown instead of the composer when someone new has messaged me — the
/// website's request bar.
class _RequestBar extends StatelessWidget {
  final String name;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  const _RequestBar({required this.name, required this.onAccept, required this.onDecline});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        color: const Color(0xFF141A33),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$name wants to chat with you.', style: const TextStyle(color: VeyonColors.muted)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: onDecline, child: const Text('Decline'))),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(onPressed: onAccept, child: const Text('Accept'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The strip above the composer while replying or editing.
class _ComposerBar extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onClose;
  const _ComposerBar({required this.icon, required this.title, required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1B2340),
        borderRadius: BorderRadius.circular(10),
        border: const Border(left: BorderSide(color: VeyonColors.bubbleMe2, width: 3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: VeyonColors.bubbleMe2),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: VeyonColors.bubbleMe2, fontWeight: FontWeight.w600, fontSize: 12.5)),
                Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: VeyonColors.muted, fontSize: 12.5)),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: onClose),
        ],
      ),
    );
  }
}

/// A message that's nothing but a handful of emoji — rendered big and
/// bubble-less (stickers are sent this way too). Mirrors app.js's isJumboEmoji.
bool _isJumboEmoji(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), '');
  if (t.isEmpty || t.runes.length > 8) return false;
  var pictographs = 0;
  for (final r in t.runes) {
    if (_isPictograph(r)) {
      pictographs++;
    } else if (!_isEmojiJoiner(r)) {
      return false;
    }
  }
  return pictographs > 0;
}

// Dart's RegExp has no \p{Extended_Pictographic}, so the emoji blocks are
// listed explicitly.
bool _isPictograph(int r) =>
    (r >= 0x1F000 && r <= 0x1FAFF) || // emoticons, symbols, flags, food, animals, …
    (r >= 0x2600 && r <= 0x27BF) || // misc symbols & dingbats (☀ ☕ ✨ ❤ …)
    (r >= 0x2300 && r <= 0x23FF) || // ⌚ ⏰ ⌛ …
    (r >= 0x2B00 && r <= 0x2BFF) || // ⭐ ⬆ …
    (r >= 0x2190 && r <= 0x21FF) || // arrows
    (r >= 0x25A0 && r <= 0x25FF) || // ▶ ◀ …
    r == 0x203C || r == 0x2049 || r == 0x2122 || r == 0x2139 || r == 0x24C2 ||
    r == 0x3030 || r == 0x303D || r == 0x3297 || r == 0x3299 || r == 0x00A9 || r == 0x00AE;

// Variation selector, zero-width joiner, keycap — glue between emoji parts.
bool _isEmojiJoiner(int r) => r == 0xFE0F || r == 0x200D || r == 0x20E3;

class _Bubble extends ConsumerWidget {
  final ChatMessage message;
  final bool mine;
  final String? myId;
  final bool boxed;
  final Session session;
  final SecretKey? convKey;
  final bool pending;
  final bool showSender;
  final String senderName;
  final String? senderColor;
  final ChatMessage? replyTo;
  final String Function(String userId) replyToSender;
  final bool selected;
  final bool flash;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;
  final ValueChanged<String> onReplyTap;
  final ValueChanged<String> onReactionTap;
  final bool isGroup;
  final bool pinned;
  final Map<String, dynamic>? translation;
  final VoidCallback onTranslationHide;
  final VoidCallback onTranslationChange;
  final ValueChanged<int> onVote;
  final VoidCallback onShowVotes;
  final VoidCallback? onClosePoll;
  final VoidCallback onOpenViewOnce;

  const _Bubble({
    required this.isGroup,
    required this.pinned,
    required this.translation,
    required this.onTranslationHide,
    required this.onTranslationChange,
    required this.onVote,
    required this.onShowVotes,
    this.onClosePoll,
    required this.onOpenViewOnce,
    required this.message,
    required this.mine,
    required this.myId,
    required this.boxed,
    required this.session,
    required this.convKey,
    required this.pending,
    required this.showSender,
    required this.senderName,
    required this.senderColor,
    required this.replyTo,
    required this.replyToSender,
    required this.selected,
    required this.flash,
    required this.onTap,
    required this.onLongPress,
    required this.onReplyTap,
    required this.onReactionTap,
  });

  bool get _bare =>
      !message.deleted &&
      ((message.kind == 'text' && message.plaintext != null && _isJumboEmoji(message.plaintext!)) ||
          (message.kind == 'file' && (message.isSticker || message.isGif)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starred = ref.watch(starredProvider).contains(message.id);
    final bare = _bare;
    final dark = Theme.of(context).brightness == Brightness.dark;

    final content = Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSender)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(senderName,
                style: TextStyle(color: _parseColor(senderColor) ?? VeyonColors.bubbleMe2, fontWeight: FontWeight.w600, fontSize: 12.5)),
          ),
        if (message.replyToId != null && !message.deleted) _replyQuote(context),
        Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(right: starred ? 14 : 0),
              child: _body(context),
            ),
            if (starred) const Positioned(top: 0, right: 0, child: Icon(Icons.star_rounded, color: Colors.amber, size: 14)),
          ],
        ),
        const SizedBox(height: 2),
        _BubbleFooter(
          message: message,
          mine: mine,
          pending: mine && pending,
          pinned: pinned,
          onEditedTap: () => showEditHistory(context, session.api, convKey, message.id),
        ),
      ],
    );

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        color: selected
            ? Colors.white.withValues(alpha: 0.12)
            : flash
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.transparent,
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Align(
              alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                padding: bare
                    ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
                    : message.kind == 'file'
                        ? const EdgeInsets.all(6)
                        : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                decoration: bare
                    ? null
                    : BoxDecoration(
                        color: mine ? VeyonColors.bubbleMe : (dark ? VeyonColors.bubbleThemDark : Colors.white),
                        borderRadius: boxed
                            ? BorderRadius.circular(6)
                            : BorderRadius.only(
                                topLeft: const Radius.circular(18),
                                topRight: const Radius.circular(18),
                                bottomLeft: Radius.circular(mine ? 18 : 6),
                                bottomRight: Radius.circular(mine ? 6 : 18),
                              ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: dark ? 0.22 : 0.06),
                            blurRadius: dark ? 2 : 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                child: BubbleInk.wrap(fg: (mine && !bare) || dark ? Colors.white : VeyonColors.inkLight, child: content),
              ),
            ),
            if (message.reactions.any((r) => r['emoji'] != null) && !message.deleted) _reactionRow(context),
          ],
        ),
      ),
    );
  }

  Widget _replyQuote(BuildContext context) {
    final original = replyTo;
    final name = original == null ? '' : replyToSender(original.senderId);
    return GestureDetector(
      onTap: original == null ? null : () => onReplyTap(original.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: BubbleInk.dim(context), width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (name.isNotEmpty)
              Text(name, style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w600, fontSize: 12)),
            Text(
              original?.preview ?? 'Original message',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: BubbleInk.dim(context), fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reactionRow(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final counts = <String, ({int count, bool mine})>{};
    for (final r in message.reactions) {
      final e = r['emoji'] as String?;
      if (e == null) continue;
      final prev = counts[e];
      counts[e] = (count: (prev?.count ?? 0) + 1, mine: (prev?.mine ?? false) || r['userId'] == myId);
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 2),
      child: Wrap(
        spacing: 4,
        children: [
          for (final entry in counts.entries)
            InkWell(
              onTap: () => onReactionTap(entry.key),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: entry.value.mine
                      ? VeyonColors.bubbleMe.withValues(alpha: dark ? 0.35 : 0.14)
                      : (dark ? VeyonColors.bubbleThemDark : Colors.white),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: dark ? VeyonColors.line : Colors.black12),
                ),
                child: Text('${entry.key} ${entry.value.count}',
                    style: TextStyle(fontSize: 12.5, color: dark ? Colors.white : VeyonColors.inkLight)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (message.deleted) {
      return Text('🚫 This message was deleted',
          style: TextStyle(color: BubbleInk.dim(context), fontStyle: FontStyle.italic, fontSize: 14));
    }
    if (message.plaintext == null) {
      return Text("Can't decrypt this message", style: TextStyle(color: BubbleInk.dim(context), fontStyle: FontStyle.italic));
    }
    switch (message.kind) {
      case 'product':
        return ProductBubble(message: message, mine: mine);
      case 'auto':
        return AutoReplyBody(text: message.plaintext ?? message.ciphertext);
      case 'poll':
        return PollCard(
            message: message, mine: mine, myId: myId, pending: pending, onVote: onVote, onShowVotes: onShowVotes, onClose: onClosePoll);
      case 'file' when message.isViewOnce:
        return ViewOnceCard(
          message: message,
          mine: mine,
          myId: myId,
          pending: pending,
          nameOf: replyToSender,
          isGroup: isGroup,
          onOpen: onOpenViewOnce,
        );
      case 'file':
      case 'voice':
        return _FileContent(message: message, convKey: convKey, senderLabel: mine ? 'You' : senderName);
      case 'location':
        return _LocationCard(payload: message.payload ?? const {});
      case 'contact':
        return _ContactCard(payload: message.payload ?? const {});
    }
    final pr = splitPrivateReply(message.plaintext);
    final text = pr?.text ?? message.plaintext!;
    if (pr == null && _isJumboEmoji(text)) return Text(text, style: const TextStyle(fontSize: 44));
    final Widget body = message.mentionAll
        ? Text.rich(everyoneSpan(text, TextStyle(color: BubbleInk.of(context), fontSize: 14.5),
            active: true, accent: mine ? BubbleInk.of(context) : Theme.of(context).colorScheme.secondary))
        : _LinkifiedText(text: text);
    final link = firstLink(text);
    if (translation == null && pr == null && link == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pr != null) PrivateQuote(quote: pr.quote, mine: mine),
        body,
        if (link != null) LinkPreviewCard(url: link),
        if (translation != null)
          TranslationBlock(t: translation!, onHide: onTranslationHide, onChange: onTranslationChange),
      ],
    );
  }

  static Color? _parseColor(String? hex) {
    if (hex == null || !hex.startsWith('#') || hex.length != 7) return null;
    final v = int.tryParse(hex.substring(1), radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }
}

/// Message text with tappable links (opened in the browser), like app.js's linkify.
class _LinkifiedText extends StatelessWidget {
  final String text;
  const _LinkifiedText({required this.text});

  static final _urlRe = RegExp(r'(https?:\/\/[^\s<]+[^\s<.,;:!?\)\]\}"' "'" r'])', caseSensitive: false);

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: BubbleInk.of(context), fontSize: 14.5);
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _urlRe.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(decoration: TextDecoration.underline, color: BubbleInk.link(context)),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

class _LocationCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _LocationCard({required this.payload});

  @override
  Widget build(BuildContext context) {
    final lat = (payload['lat'] as num?)?.toDouble();
    final lng = (payload['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return Text('📍 Location', style: TextStyle(color: BubbleInk.of(context)));
    // Same map link the website uses.
    final url = Uri.parse('https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=16/$lat/$lng');
    return InkWell(
      onTap: () => launchUrl(url, mode: LaunchMode.externalApplication),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_on_rounded, color: BubbleInk.of(context), size: 30),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Location', style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w600)),
                Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)} · open map',
                    style: TextStyle(color: BubbleInk.dim(context), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _ContactCard({required this.payload});

  @override
  Widget build(BuildContext context) {
    final name = payload['name'] as String? ?? 'Contact';
    final phone = payload['phone'] as String? ?? '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircleAvatar(radius: 18, child: Icon(Icons.person_rounded)),
        const SizedBox(width: 10),
        Flexible(
          child: InkWell(
            onTap: phone.isEmpty ? null : () => launchUrl(Uri(scheme: 'tel', path: phone)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w600)),
                Text(phone, style: TextStyle(color: BubbleInk.dim(context), fontSize: 12.5)),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy number',
          icon: Icon(Icons.copy_rounded, size: 18, color: BubbleInk.dim(context)),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: phone));
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Number copied.')));
          },
        ),
      ],
    );
  }
}

/// Time + delivery state under each bubble, like the website:
/// clock = waiting to send (offline), ✓ sent, ✓✓ delivered, blue ✓✓ read.
class _BubbleFooter extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final bool pending;
  final bool pinned;
  final VoidCallback? onEditedTap;
  const _BubbleFooter({required this.message, required this.mine, required this.pending, this.pinned = false, this.onEditedTap});

  @override
  Widget build(BuildContext context) {
    final time = DateTime.tryParse(message.createdAt)?.toLocal();
    final label = time == null
        ? ''
        : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    Widget? tick;
    if (mine && !message.deleted) {
      if (pending) {
        tick = Icon(Icons.schedule_rounded, size: 13, color: BubbleInk.dim(context));
      } else if (message.readAt != null) {
        tick = const Icon(Icons.done_all_rounded, size: 14, color: Color(0xFF7CC4FF));
      } else if (message.deliveredAt != null) {
        tick = Icon(Icons.done_all_rounded, size: 14, color: BubbleInk.dim(context));
      } else {
        tick = Icon(Icons.done_rounded, size: 14, color: BubbleInk.dim(context));
      }
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pinned) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.push_pin_rounded, size: 11, color: BubbleInk.dim(context))),
        if (message.expiresAt != null && !message.deleted)
          Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.timer_outlined, size: 11, color: BubbleInk.dim(context))),
        if (message.editedAt != null && !message.deleted)
          GestureDetector(
            onTap: onEditedTap,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text('edited', style: TextStyle(color: BubbleInk.dim(context), fontSize: 10.5, decoration: TextDecoration.underline)),
            ),
          ),
        Text(label, style: TextStyle(color: BubbleInk.dim(context), fontSize: 10.5)),
        if (tick != null) ...[const SizedBox(width: 3), tick],
      ],
    );
  }
}

/// A `file`/`voice` bubble's body: `message.plaintext` holds the already-
/// decrypted metadata JSON. Images (and GIFs/stickers) show inline
/// (downloaded+decrypted lazily, then cached on disk so they never need
/// re-fetching); voice notes get a player; any other file shows a name/size
/// row that downloads+caches into app storage on tap.
class _FileContent extends ConsumerStatefulWidget {
  final ChatMessage message;
  final SecretKey? convKey;
  final String senderLabel;
  const _FileContent({required this.message, required this.convKey, this.senderLabel = 'Voice message'});

  @override
  ConsumerState<_FileContent> createState() => _FileContentState();
}

class _FileContentState extends ConsumerState<_FileContent> {
  final _cache = FileCache();
  Uint8List? _bytes;
  bool _loading = false;
  String? _error;

  String? _transcript; // "Convert to text" result (or progress / error)
  bool _transcribing = false;

  Map<String, dynamic>? get _meta {
    try {
      return jsonDecode(widget.message.plaintext ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  bool get _isImage => (_meta?['mime'] as String? ?? '').startsWith('image/');

  bool get _isVideo => (_meta?['mime'] as String? ?? '').startsWith('video/');

  bool get _isSmall => _meta?['sticker'] == true || _meta?['gif'] == true;

  /// Storage & data → Automatic download: show what's already on this phone,
  /// and download the rest only when that setting allows it right now.
  /// Stickers and GIFs are tiny and always load.
  Future<void> _autoLoad() async {
    if (_bytes != null || _loading) return;
    if (_isImage && _isSmall) return _load();
    final kind = _isImage ? 'photos' : _isVoice ? 'voice' : _isVideo ? 'videos' : null;
    if (kind == null) return;
    final cached = await _cache.load(widget.message.id);
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }
    if (await shouldAutoDownload(kind) && mounted) await _load();
  }

  bool get _isVoice => widget.message.kind == 'voice';

  /// Transcripts survive the bubble scrolling away (and are never asked twice).
  static final Map<String, String> _transcripts = {};

  @override
  void initState() {
    super.initState();
    _autoLoad();
    if (_isVoice) {
      _transcript = _transcripts[widget.message.id];
      if (_transcript == null && PrefsStore.instance.autoTranscribe) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _transcribe();
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant _FileContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The key arrives after the cached bubble was first built — retry then.
    if (oldWidget.convKey == null && widget.convKey != null && _bytes == null && !_loading) _autoLoad();
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// One player for the whole app: keeps playing while you scroll or leave
  /// the chat, with speed control and a mini-player.
  Future<void> _togglePlay() async {
    final sender = widget.senderLabel;
    await ref.read(voicePlaybackProvider).toggle(
      id: widget.message.id,
      title: '🎤 $sender',
      bytes: () async {
        if (_bytes == null) await _load();
        return _bytes;
      },
    );
  }

  /// Voice note → text via the backend's local Whisper service (the audio is
  /// decrypted here first; the server never keeps it) — the website's
  /// "Convert to text" button.
  Future<void> _transcribe() async {
    setState(() {
      _transcribing = true;
      _transcript = 'Transcribing…';
    });
    try {
      if (_bytes == null) await _load();
      if (_bytes == null) throw StateError('Could not load the voice note.');
      final meta = _meta ?? const {};
      final text = await ref.read(sessionControllerProvider).api.transcribe(
            _bytes!,
            filename: meta['name'] as String? ?? 'voice-note.m4a',
            mime: meta['mime'] as String? ?? 'audio/mp4',
          );
      final shown = text.trim().isEmpty ? '(No speech detected.)' : text.trim();
      _transcripts[widget.message.id] = shown;
      if (mounted) setState(() => _transcript = shown);
    } catch (e) {
      final msg = e.toString().replaceFirst(RegExp(r'^(ApiException\(\d+\)|Bad state): '), '');
      if (mounted) setState(() => _transcript = 'Could not transcribe: $msg');
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<void> _load() async {
    final meta = _meta;
    final filePath = widget.message.filePath;
    if (meta == null || filePath == null) return;
    setState(() => _loading = true);
    try {
      final cached = await _cache.load(widget.message.id);
      if (cached != null) {
        if (mounted) setState(() { _bytes = cached; _loading = false; });
        return;
      }
      final blobIv = meta['blobIv'] as String;
      // Signal files carry their own key; older ones need the chat's.
      if (widget.convKey == null && !blobIv.startsWith('k:')) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final session = ref.read(sessionControllerProvider);
      final blob = await session.api.downloadBlob(filePath);
      final decrypted = await decryptFileBytes(widget.convKey, Uint8List.fromList(blob), blobIv);
      await _cache.save(widget.message.id, decrypted);
      if (mounted) setState(() { _bytes = decrypted; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Could not load attachment'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    final name = meta?['name'] as String? ?? 'Attachment';
    final size = meta?['size'] as int? ?? widget.message.fileSize ?? 0;
    final small = meta?['sticker'] == true || meta?['gif'] == true;

    if (_isImage) {
      if (_bytes != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: GestureDetector(
            onTap: () => showDialog(
              context: context,
              builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(_bytes!))),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: small ? 180 : 320),
              child: Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        );
      }
      return SizedBox(
        width: small ? 120 : 180,
        height: small ? 120 : 140,
        child: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : _error != null
                  ? Text(_error!, style: TextStyle(color: BubbleInk.dim(context), fontSize: 12))
                  : InkWell(
                      onTap: _load,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.download_rounded, color: BubbleInk.dim(context)),
                            const SizedBox(height: 4),
                            Text(size > 0 ? '${_formatSize(size)} · tap to download' : 'Tap to download',
                                style: TextStyle(color: BubbleInk.dim(context), fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
        ),
      );
    }

    if (_isVoice) {
      final vp = ref.watch(voicePlaybackProvider);
      final mineNow = vp.currentId == widget.message.id;
      final playing = vp.isPlaying(widget.message.id);
      final position = mineNow ? vp.position : Duration.zero;
      final duration = mineNow ? vp.duration : Duration.zero;
      final total = duration > Duration.zero ? duration : Duration(seconds: (size / 2000).round().clamp(0, 600));
      final player = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, color: BubbleInk.of(context), size: 32),
            onPressed: _loading ? null : _togglePlay,
          ),
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(
              value: total.inMilliseconds == 0 ? 0 : position.inMilliseconds / total.inMilliseconds,
              backgroundColor: BubbleInk.of(context).withValues(alpha: 0.24),
            ),
          ),
          const SizedBox(width: 8),
          Text(_formatDuration(playing || position > Duration.zero ? position : total),
              style: TextStyle(color: BubbleInk.dim(context), fontSize: 11)),
          const SizedBox(width: 4),
          InkWell(
            onTap: vp.cycleSpeed,
            borderRadius: BorderRadius.circular(99),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(99)),
              child: Text(vp.speedLabel, style: TextStyle(color: BubbleInk.of(context), fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
          IconButton(
            tooltip: 'Convert to text',
            visualDensity: VisualDensity.compact,
            icon: _transcribing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.text_snippet_outlined, size: 20, color: BubbleInk.dim(context)),
            onPressed: _transcribing ? null : _transcribe,
          ),
        ],
      );
      if (_transcript == null) return player;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          player,
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(_transcript!, style: TextStyle(color: BubbleInk.of(context), fontSize: 13.5)),
          ),
        ],
      );
    }

    return InkWell(
      onTap: _loading ? null : () => _openWithSystem(name),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_rounded, color: BubbleInk.of(context)),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, style: TextStyle(color: BubbleInk.of(context), fontSize: 13.5), overflow: TextOverflow.ellipsis),
                Text(_formatSize(size), style: TextStyle(color: BubbleInk.dim(context), fontSize: 11)),
              ],
            ),
          ),
          if (_loading) const Padding(padding: EdgeInsets.only(left: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
        ],
      ),
    );
  }

  /// Decrypts the file, writes it to a temp folder under its real name and
  /// hands it to the phone's own viewer (PDF reader, Office, gallery…) —
  /// the website's equivalent is the browser downloading/opening it.
  Future<void> _openWithSystem(String name) async {
    final messenger = ScaffoldMessenger.of(context);
    await _load();
    final bytes = _bytes;
    if (bytes == null) {
      messenger.showSnackBar(SnackBar(content: Text(_error ?? 'Could not load attachment')));
      return;
    }
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/open/${widget.message.id}');
      await dir.create(recursive: true);
      final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${dir.path}/$safeName');
      await file.writeAsBytes(bytes, flush: true);
      final result = await OpenFilex.open(file.path, type: _meta?['mime'] as String?);
      if (result.type != ResultType.done) {
        messenger.showSnackBar(SnackBar(content: Text(result.type == ResultType.noAppToOpen ? 'No app on this phone can open this file.' : result.message)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open file: $e')));
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Chat wallpaper: Default, upload a photo, or a preset — plus how a photo
/// fits (Cover / Fit / Stretch / Tile). Same choices as the website.
class _WallpaperPickerSheet extends ConsumerStatefulWidget {
  final Conversation conversation;
  const _WallpaperPickerSheet({required this.conversation});

  @override
  ConsumerState<_WallpaperPickerSheet> createState() => _WallpaperPickerSheetState();
}

const _fitLabels = {'cover': 'Cover', 'contain': 'Fit', 'fill': 'Stretch', 'tile': 'Tile'};

class _WallpaperPickerSheetState extends ConsumerState<_WallpaperPickerSheet> {
  bool _saving = false;
  late String _fit = widget.conversation.wallpaperFit;

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await action();
      await ref.read(conversationsProvider.notifier).refresh();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), ''))));
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _uploadPhoto() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final file = result?.files.singleOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final mime = lookupMimeType(file.name) ?? 'image/jpeg';
    if (!{'image/jpeg', 'image/png', 'image/webp'}.contains(mime)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please choose a JPEG, PNG or WebP image.')));
      return;
    }
    final api = ref.read(sessionControllerProvider).api;
    await _run(() async {
      await api.uploadWallpaperPhoto(widget.conversation.id, bytes, mime);
      wallpaperVersions[widget.conversation.id] = (wallpaperVersions[widget.conversation.id] ?? 0) + 1;
    }, done: 'Wallpaper updated.');
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(sessionControllerProvider).api;
    final current = widget.conversation.wallpaper;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Chat wallpaper', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _swatch(null, 'Default', () => _run(() => api.setWallpaper(widget.conversation.id, null))),
                _tile(
                  label: current == 'photo' ? 'Change photo' : '+ Upload photo',
                  selected: current == 'photo',
                  onTap: _uploadPhoto,
                  child: const Icon(Icons.add_photo_alternate_outlined, color: VeyonColors.muted),
                ),
                for (final entry in kWallpaperPresets.entries)
                  _swatch(entry.key, kWallpaperLabels[entry.key]!, () => _run(() => api.setWallpaper(widget.conversation.id, entry.key))),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Photo fit', style: TextStyle(color: VeyonColors.muted)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [for (final e in _fitLabels.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                    selected: {_fit},
                    onSelectionChanged: (s) => setState(() => _fit = s.first),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving || _fit == widget.conversation.wallpaperFit
                      ? null
                      : () => _run(() => api.setWallpaperFit(widget.conversation.id, _fit), done: 'Wallpaper updated.'),
                  child: const Text('Set'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile({required String label, required bool selected, required VoidCallback onTap, Widget? child, Gradient? gradient}) {
    return InkWell(
      onTap: _saving ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 84,
        height: 60,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          gradient: gradient,
          color: gradient == null ? const Color(0xFF1B2340) : null,
          borderRadius: BorderRadius.circular(12),
          border: selected ? Border.all(color: Colors.white, width: 2) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            child ?? const SizedBox.shrink(),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _swatch(String? key, String label, VoidCallback onTap) {
    final colors = key == null ? [const Color(0xFF141A33), const Color(0xFF141A33)] : kWallpaperPresets[key]!;
    return _tile(label: label, selected: widget.conversation.wallpaper == key, onTap: onTap, gradient: LinearGradient(colors: colors));
  }
}

class _SendButton extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  const _SendButton({required this.onTap, this.icon = Icons.arrow_upward_rounded});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(gradient: VeyonColors.bubbleGradient, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}


class _AdminsOnlyBar extends StatelessWidget {
  final bool announcement;
  const _AdminsOnlyBar({required this.announcement});

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.campaign_rounded, size: 18, color: Theme.of(context).colorScheme.secondary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                announcement ? 'Only community admins can post announcements.' : 'Only admins can send messages in this group.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: VeyonColors.muted),
              ),
            ),
          ]),
        ),
      );
}
