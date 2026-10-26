import '../../core/signal/signal_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../core/local_cache.dart';
import '../../core/storage_clear.dart';
import '../conversations/conversations_provider.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../auth/session.dart';
import '../groups/group_tools.dart';

/// Disappearing-message timers a chat can use (same choices as the website).
const kDisappearOptions = <int, String>{0: 'Off', 86400: '24 hours', 604800: '7 days', 7776000: '90 days'};

String disappearLabel(int seconds) => kDisappearOptions[seconds] ?? 'Off';

class ChatState {
  final List<ChatMessage> messages;
  final bool loading;
  final bool peerTyping;
  final bool offline;
  final String? error;

  /// Group chats only: userId → member row (displayName, avatarColor, …),
  /// for the sender name above each message.
  final Map<String, Map<String, dynamic>> members;

  /// Group chats: who's in this group's call right now (empty = no call).
  final Set<String> callParticipants;

  /// The chat's pinned message (decrypted) and who pinned it.
  final ChatMessage? pinned;
  final String? pinnedBy;

  /// Disappearing-messages timer, seconds (0 = off) — shared by the chat.
  final int disappearSeconds;

  /// One-shot friendly notice for a snackbar ("Bob pinned a message.").
  final String? notice;

  const ChatState({
    this.messages = const [],
    this.loading = true,
    this.peerTyping = false,
    this.offline = false,
    this.error,
    this.members = const {},
    this.callParticipants = const {},
    this.pinned,
    this.pinnedBy,
    this.disappearSeconds = 0,
    this.notice,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? loading,
    bool? peerTyping,
    bool? offline,
    String? error,
    Map<String, Map<String, dynamic>>? members,
    Set<String>? callParticipants,
    ChatMessage? pinned,
    String? pinnedBy,
    bool clearPinned = false,
    int? disappearSeconds,
    String? notice,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        loading: loading ?? this.loading,
        peerTyping: peerTyping ?? this.peerTyping,
        offline: offline ?? this.offline,
        error: error,
        members: members ?? this.members,
        callParticipants: callParticipants ?? this.callParticipants,
        pinned: clearPinned ? null : (pinned ?? this.pinned),
        pinnedBy: clearPinned ? null : (pinnedBy ?? this.pinnedBy),
        disappearSeconds: disappearSeconds ?? this.disappearSeconds,
        notice: notice,
      );
}

/// One controller per open conversation — resolves the encryption key
/// (direct: static-static ECDH with the peer; group: unwrap the shared
/// content key), loads and decrypts history, and stays live via the WS frame
/// stream: new messages, receipts, reactions, edits and deletes. Cached
/// messages (already decrypted) show immediately and remain the fallback
/// whenever the network isn't available.
class ChatController extends StateNotifier<ChatState> {
  final Session session;
  final Conversation conversation;
  final LocalCache _cache;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  /// Signal edits made on this phone: messageId -> the new text.
  final _pendingEdits = <String, String>{};
  Timer? _typingTimer;
  SecretKey? _key;
  final _uuid = const Uuid();

  Timer? _expiryTimer;

  ChatController(this.session, this.conversation, {LocalCache? cache})
      : _cache = cache ?? LocalCache(),
        super(ChatState(disappearSeconds: conversation.disappearSeconds, pinnedBy: conversation.pinnedBy)) {
    _init();
    // Disappearing messages leave the screen the moment they expire (the
    // server deletes them for good shortly after).
    _expiryTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pruneExpired());
  }

  void _pruneExpired() {
    if (!mounted) return;
    final keep = state.messages.where((m) => !m.isExpired).toList();
    if (keep.length != state.messages.length) {
      state = state.copyWith(messages: keep, clearPinned: state.pinned?.isExpired ?? false);
      _persist();
    }
  }

  String get _myId => session.user!.id;

  Future<void> _init() async {
    // Opening a chat answers a "mark as unread".
    ConversationsController.clearMarkedUnread(conversation.id);
    final cached = await _cache.loadMessages(conversation.id);
    if (cached.isNotEmpty) {
      state = state.copyWith(
        messages: cached.map((j) => ChatMessage.fromJson(j)).where((m) => !m.isExpired && !isCleared(m)).toList(),
        loading: false, // something to show already — no blocking spinner
      );
    }
    if (conversation.isGroup) _setMembers(await _cache.loadMembers(conversation.id));
    // Listen from the start, not only after a successful load — otherwise a
    // chat opened offline would never come alive once the connection returns.
    _listenToSocket();
    await _syncFromServer();
  }

  /// Resolves the key (works offline for direct chats and for groups opened
  /// here before) and fetches history. Runs on open and again every time the
  /// connection comes back.
  Future<void> _syncFromServer() async {
    try {
      _key ??= await resolveConversationKey(session, conversation);
    } catch (e) {
      _showOfflineOrError(e);
      return;
    }
    if (state.pinned == null && conversation.pinnedMessage != null) {
      final pinned = await _decrypt(ChatMessage.fromJson(conversation.pinnedMessage!));
      if (mounted && !pinned.isExpired) state = state.copyWith(pinned: pinned, pinnedBy: conversation.pinnedBy);
    }
    try {
      if (conversation.isGroup) {
        final members = (await session.api.listMembers(conversation.id)).cast<Map<String, dynamic>>();
        _setMembers(members);
        await _cache.saveMembers(conversation.id, members);
      }
      await _loadHistory();
      session.ws?.sendRead(conversationId: conversation.id);
      // Is a group call already going on? (Room membership is live server
      // state only — the website asks the same way when a group opens.)
      if (conversation.isGroup) session.ws?.send({'type': 'group-call-query', 'conversationId': conversation.id});
      state = state.copyWith(loading: false, offline: false);
    } catch (e) {
      _showOfflineOrError(e);
    }
  }

  void _setMembers(List<Map<String, dynamic>> list) {
    if (list.isEmpty) return;
    state = state.copyWith(members: {for (final m in list) m['id'] as String: m});
  }

  /// Display name for a message's sender (groups) — "You" for my own.
  String senderName(String userId) {
    if (userId == _myId) return 'You';
    if (!conversation.isGroup) return conversation.peer?.displayName ?? '';
    return state.members[userId]?['displayName'] as String? ?? 'Former member';
  }

  void _showOfflineOrError(Object e) {
    // If there's anything on screen (cached history), that's still a usable
    // view — just flag offline. Only a chat with nothing at all shows an error.
    if (state.messages.isEmpty) {
      state = state.copyWith(loading: false, offline: true, error: 'Offline — this chat will load when you reconnect.');
    } else {
      state = state.copyWith(loading: false, offline: true);
    }
  }

  Future<void> _loadHistory() async {
    final raw = await session.api.listMessages(conversation.id);
    final decrypted = <ChatMessage>[];
    for (final j in raw) {
      final json = j as Map<String, dynamic>;
      decrypted.add(await _decrypt(ChatMessage.fromJson(json), envelope: json['envelope'] as Map<String, dynamic>?));
    }
    // Keep my still-unsent (queued offline) messages visible.
    final serverIds = decrypted.map((m) => m.id).toSet();
    final pending = state.messages.where((m) => !serverIds.contains(m.id) && isPending(m));
    // Anything cleared in Storage & data stays gone from this phone.
    state = state.copyWith(messages: [...decrypted.where((m) => !m.isExpired && !isCleared(m)), ...pending], loading: false);
    await _persist();
  }

  /// True for a message I sent that the server hasn't confirmed yet.
  bool isPending(ChatMessage m) => session.ws?.isPending(m.id) ?? false;

  /// Decrypts the body and every reaction. Text kinds get their text;
  /// file/voice/location/contact get their JSON payload (as a string).
  Future<ChatMessage> _decrypt(ChatMessage msg, {Map<String, dynamic>? envelope}) async {
    if (msg.kind == 'auto') return msg.copyWith(plaintext: msg.ciphertext);
    var out = msg;
    if (msg.ciphertext == 'signal') {
      // Signal: this phone's own sealed copy, opened once and kept.
      String? text;
      try {
        text = await SignalService.instance.open(
            id: msg.id, senderId: msg.senderId, iv: msg.iv, editedAt: msg.editedAt, envelope: envelope);
      } catch (_) {}
      out = out.copyWith(
          plaintext: text ??
              (ChatMessage.jsonKinds.contains(msg.kind)
                  ? null
                  : msg.senderId == _myId
                      ? '🔒 Sent from your other device before this phone was set up'
                      : '🔒 Sent before this phone was set up'));
    } else {
      if (_key == null) return msg;
      try {
        out = out.copyWith(plaintext: await decryptText(_key!, msg.ciphertext, msg.iv));
      } catch (_) {
        out = out.copyWith(plaintext: ChatMessage.jsonKinds.contains(msg.kind) ? null : '🔒 Could not decrypt this message.');
      }
    }
    if (_key == null) return out;
    if (msg.reactions.isNotEmpty) {
      out = out.copyWith(reactions: [for (final r in msg.reactions) await _decryptReaction(r)]);
    }
    return out;
  }

  Future<Map<String, dynamic>> _decryptReaction(Map<String, dynamic> r) async {
    if (r['emoji'] != null) return r;
    try {
      return {...r, 'emoji': await decryptText(_key!, r['ciphertext'] as String, r['iv'] as String)};
    } catch (_) {
      return r;
    }
  }

  Future<void> _persist() => _cache.saveMessages(conversation.id, state.messages.map((m) => m.toJson()).toList());

  void _replace(String id, ChatMessage Function(ChatMessage) change) {
    state = state.copyWith(messages: [for (final m in state.messages) m.id == id ? change(m) : m]);
  }

  void _listenToSocket() {
    _wsSub = session.ws?.frames.listen((frame) async {
      final type = frame['type'];
      final mine = frame['conversationId'] == conversation.id;
      if (type == 'connected') {
        await _syncFromServer(); // back online — catch up on what was missed
      } else if (type == 'disconnected') {
        state = state.copyWith(offline: true);
      } else if (type == 'error' && frame['tempId'] != null &&
          state.messages.any((m) => m.id == frame['tempId'])) {
        // The server refused a queued message (e.g. blocked) — drop the bubble.
        state = state.copyWith(
          messages: state.messages.where((m) => m.id != frame['tempId']).toList(),
          error: frame['error'] as String?,
        );
        await _persist();
      } else if (type == 'error' && frame['tempId'] == null && frame['error'] is String) {
        // e.g. "You can only edit your own messages." — show it.
        state = state.copyWith(error: frame['error'] as String);
      } else if (type == 'message' && mine) {
        final raw = frame['message'] as Map<String, dynamic>;
        final msg = await _decrypt(ChatMessage.fromJson(raw), envelope: raw['envelope'] as Map<String, dynamic>?);
        if (state.messages.any((m) => m.id == msg.id)) return;
        state = state.copyWith(messages: [...state.messages, msg]);
        await _persist();
        session.ws?.sendRead(conversationId: conversation.id);
      } else if (type == 'sent' && mine) {
        // Swap the optimistic bubble (matched by tempId) for the confirmed one.
        final tempId = frame['tempId'] as String?;
        final raw = frame['message'] as Map<String, dynamic>;
        if (raw['ciphertext'] == 'signal') {
          // My own Signal message: keep what I wrote (there's no copy for this phone).
          final mineText = state.messages.where((m) => m.id == tempId).firstOrNull?.plaintext;
          if (mineText != null) await SignalService.instance.keep(raw['id'] as String, mineText);
        }
        final msg = await _decrypt(ChatMessage.fromJson(raw));
        final updated = state.messages.where((m) => m.id != tempId && m.id != msg.id).toList()..add(msg);
        state = state.copyWith(messages: updated);
        await _persist();
      } else if (type == 'group-call-state' && mine) {
        state = state.copyWith(callParticipants: ((frame['participantIds'] as List<dynamic>?) ?? const []).cast<String>().toSet());
      } else if (type == 'group-call-participant-joined' && mine && frame['userId'] is String) {
        state = state.copyWith(callParticipants: {...state.callParticipants, frame['userId'] as String});
      } else if (type == 'group-call-participant-left' && mine && frame['userId'] is String) {
        state = state.copyWith(callParticipants: {...state.callParticipants}..remove(frame['userId']));
      } else if (type == 'typing' && mine) {
        final typing = frame['isTyping'] == true;
        state = state.copyWith(peerTyping: typing);
        // Safety net (as on the website): if the "stopped" frame is lost,
        // don't leave "typing…" stuck forever.
        _typingTimer?.cancel();
        if (typing) {
          _typingTimer = Timer(const Duration(seconds: 4), () {
            if (mounted) state = state.copyWith(peerTyping: false);
          });
        }
      } else if (type == 'receipts' && mine) {
        // Live ✓✓ / blue ✓✓ on my own messages.
        final ids = ((frame['messageIds'] as List<dynamic>?) ?? const []).toSet();
        final status = frame['status'] as String? ?? 'delivered';
        state = state.copyWith(
          messages: state.messages.map((m) => ids.contains(m.id) ? m.withReceipt(status) : m).toList(),
        );
        await _persist();
      } else if (type == 'poll-votes' && mine) {
        final votes = ((frame['votes'] as List<dynamic>?) ?? const []).map((v) => Map<String, dynamic>.from(v as Map)).toList();
        _replace(frame['messageId'] as String, (m) => m.copyWith(votes: votes));
        await _persist();
      } else if (type == 'poll-closed' && mine) {
        _replace(frame['messageId'] as String, (m) => m.copyWith(pollClosesAt: frame['closesAt'] as String?));
        await _persist();
      } else if (type == 'message-pinned' && mine) {
        final raw = frame['message'] as Map<String, dynamic>?;
        final by = frame['pinnedBy'] as String?;
        if (raw == null) {
          final had = state.pinned != null;
          state = state.copyWith(clearPinned: true, notice: had ? 'Message unpinned.' : null);
        } else {
          final pinned = await _decrypt(ChatMessage.fromJson(raw));
          final isNew = state.pinned?.id != pinned.id;
          state = state.copyWith(pinned: pinned, pinnedBy: by, notice: isNew && by != null ? '${senderName(by)} pinned a message.' : null);
        }
      } else if (type == 'disappearing-changed' && mine) {
        final seconds = (frame['seconds'] as num?)?.toInt() ?? 0;
        final who = senderName(frame['byUserId'] as String? ?? '');
        state = state.copyWith(
          disappearSeconds: seconds,
          notice: seconds == 0
              ? '$who turned off disappearing messages.'
              : '$who turned on disappearing messages (${disappearLabel(seconds)}).',
        );
      } else if (type == 'view-once-opened' && mine) {
        final userId = frame['userId'] as String;
        _replace(frame['messageId'] as String, (m) => m.copyWith(openedBy: {...m.openedBy, userId}.toList()));
        await _persist();
      } else if (type == 'reaction' && mine) {
        await _applyReaction(frame);
      } else if (type == 'message-deleted' && mine) {
        _replace(frame['messageId'] as String, (m) => m.copyWith(deleted: true, reactions: const []));
        await _persist();
      } else if (type == 'message-edited' && mine) {
        final id = frame['messageId'] as String;
        final ciphertext = frame['ciphertext'] as String;
        final iv = frame['iv'] as String;
        final editedAt = frame['editedAt']?.toString();
        String? text;
        try {
          if (ciphertext == 'signal') {
            final mineEdit = _pendingEdits.remove(id);
            if (mineEdit != null) {
              await SignalService.instance.keep(id, mineEdit, editedAt: editedAt);
              text = mineEdit;
            } else {
              final old = state.messages.where((m) => m.id == id).firstOrNull;
              text = await SignalService.instance.open(
                  id: id, senderId: old?.senderId ?? '', iv: iv, editedAt: editedAt,
                  envelope: frame['envelope'] as Map<String, dynamic>?);
            }
          } else if (_key != null) {
            text = await decryptText(_key!, ciphertext, iv);
          }
        } catch (_) {}
        _replace(id, (m) => m.copyWith(
              ciphertext: ciphertext,
              iv: iv,
              editedAt: frame['editedAt']?.toString() ?? DateTime.now().toUtc().toIso8601String(),
              plaintext: text,
            ));
        await _persist();
      }
    });
  }

  Future<void> _applyReaction(Map<String, dynamic> frame) async {
    final messageId = frame['messageId'] as String;
    final userId = frame['userId'] as String;
    Map<String, dynamic>? added;
    if (frame['removed'] != true) {
      added = await _decryptReaction({'userId': userId, 'ciphertext': frame['ciphertext'], 'iv': frame['iv']});
    }
    _replace(messageId, (m) => m.copyWith(reactions: [
          ...m.reactions.where((r) => r['userId'] != userId),
          if (added != null) added,
        ]));
    await _persist();
  }

  /// The resolved conversation key, exposed read-only so the chat screen can
  /// decrypt a tapped-open attachment's actual bytes on demand.
  SecretKey? get resolvedKey => _key;

  bool _ensureKey() {
    if (_key != null) return true;
    // Only possible for a group never opened on this phone while online —
    // its key has never been seen here, so there's nothing to encrypt with.
    state = state.copyWith(offline: true, error: 'Connect once to open this group, then you can message offline.');
    return false;
  }

  /// Adds my own message to the list straight away and queues it (the
  /// outbox survives closing the app; it's delivered when the connection
  /// returns — same as the website's outbox).
  Future<void> _sendEncrypted({
    required String kind,
    required String plaintext,
    required CipherEnvelope envelope,
    String? replyToId,
    String? filePath,
    int? fileSize,
    bool viewOnce = false,
    // Plain frame fields that go along: pollClosesAt, mentionAll.
    Map<String, dynamic> extras = const {},
  }) async {
    final tempId = _uuid.v4();
    final optimistic = ChatMessage(
      id: tempId,
      senderId: _myId,
      kind: kind,
      ciphertext: envelope.ciphertext,
      iv: envelope.iv,
      filePath: filePath,
      fileSize: fileSize,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      replyToId: replyToId,
      viewOnce: viewOnce,
      plaintext: plaintext,
      pollClosesAt: extras['pollClosesAt'] as String?,
      mentionAll: extras['mentionAll'] == true,
    );
    state = state.copyWith(messages: [...state.messages, optimistic]);
    await _persist();
    session.ws?.sendMessage(
      conversationId: conversation.id,
      ciphertext: envelope.ciphertext,
      iv: envelope.iv,
      kind: kind,
      tempId: tempId,
      replyToId: replyToId,
      filePath: filePath,
      fileSize: fileSize,
      viewOnce: viewOnce,
      extras: extras,
    );
  }

  /// Text (and stickers, which are just big emoji text). Works offline.
  Future<void> sendText(String text, {String? replyToId, Map<String, dynamic>? privateQuote}) async {
    var body = text.trim();
    if (body.isEmpty || !_ensureKey()) return;
    // "@everyone" from a group admin notifies every member.
    final mentionAll = conversation.iAmAdmin && mentionsEveryone(body);
    // "Reply privately": the quoted group message travels inside the encrypted text.
    if (privateQuote != null) body = packPrivateReply(privateQuote, body);
    // Signal protocol (1-to-1): sealed separately for every device.
    if (session.ws != null && session.ws!.isConnected &&
        await SignalService.instance.useFor(isGroup: conversation.isGroup, peerId: conversation.peer?.id)) {
      try {
        await _sendSealed(body, replyToId: replyToId);
        return;
      } catch (_) {
        // Couldn't seal right now (e.g. the connection dropped) — the older
        // encryption below still keeps it end-to-end encrypted.
      }
    }
    await _sendEncrypted(
      kind: 'text',
      plaintext: body,
      envelope: await encryptText(_key!, body),
      replyToId: replyToId,
      extras: mentionAll ? const {'mentionAll': true} : const {},
    );
  }

  /// The Signal path of [sendText]: the frame carries one sealed copy per
  /// device, plus (kept on this phone only) the text so it can be sealed
  /// again if the server says the devices changed.
  Future<void> _sendSealed(
    String body, {
    String kind = 'text',
    String? replyToId,
    String? filePath,
    int? fileSize,
    bool viewOnce = false,
    Map<String, dynamic> extras = const {},
  }) async {
    final members = [conversation.peer!.id, _myId];
    final envelopes = await SignalService.instance.seal(members, body);
    final tempId = _uuid.v4();
    final optimistic = ChatMessage(
      id: tempId,
      senderId: _myId,
      kind: kind,
      ciphertext: 'signal',
      iv: 'signal',
      filePath: filePath,
      fileSize: fileSize,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      replyToId: replyToId,
      viewOnce: viewOnce,
      plaintext: body,
      pollClosesAt: extras['pollClosesAt'] as String?,
      mentionAll: extras['mentionAll'] == true,
    );
    state = state.copyWith(messages: [...state.messages, optimistic]);
    await _persist();
    session.ws?.sendMessage(
      conversationId: conversation.id,
      ciphertext: 'signal',
      iv: 'signal',
      kind: kind,
      tempId: tempId,
      replyToId: replyToId,
      filePath: filePath,
      fileSize: fileSize,
      viewOnce: viewOnce,
      extras: {...extras, 'envelopes': envelopes, '_signalText': body, '_members': members},
    );
  }

  /// Location (`{lat, lng}`) or contact (`{name, phone}`) — JSON payloads,
  /// exactly app.js's sendJsonMessage. Works offline.
  Future<void> sendJson(String kind, Map<String, dynamic> payload, {String? replyToId, Map<String, dynamic> extras = const {}}) async {
    if (!_ensureKey()) return;
    final json = jsonEncode(payload);
    if (session.ws != null && session.ws!.isConnected &&
        await SignalService.instance.useFor(isGroup: conversation.isGroup, peerId: conversation.peer?.id)) {
      try {
        await _sendSealed(json, kind: kind, replyToId: replyToId, extras: extras);
        return;
      } catch (_) {/* fall back to the older encryption below */}
    }
    await _sendEncrypted(kind: kind, plaintext: json, envelope: await encryptText(_key!, json), replyToId: replyToId, extras: extras);
  }

  /// The poll's creator (or a group admin) closes it now.
  void closePoll(ChatMessage poll) {
    if (session.ws == null || !session.ws!.isConnected) {
      state = state.copyWith(error: 'Closing a poll needs a connection.');
      return;
    }
    session.ws!.send({'type': 'close-poll', 'conversationId': conversation.id, 'messageId': poll.id});
  }

  // ── Polls, pins, disappearing & view-once ──────────────────────────

  /// Vote on a poll (tap your own single choice again to take it back;
  /// multi-choice polls toggle each option). Shown straight away.
  void vote(ChatMessage poll, int option) {
    if (isPending(poll) || poll.pollClosed) return;
    final multi = poll.payload?['multi'] == true;
    final current = {
      for (final v in poll.votes)
        if (v['userId'] == _myId) ...((v['choices'] as List<dynamic>).cast<num>().map((n) => n.toInt())),
    };
    final List<int> next;
    if (multi) {
      if (!current.remove(option)) current.add(option);
      next = current.toList()..sort();
    } else {
      next = current.contains(option) ? [] : [option];
    }
    final others = poll.votes.where((v) => v['userId'] != _myId).toList();
    _replace(poll.id, (m) => m.copyWith(votes: next.isEmpty ? others : [...others, {'userId': _myId, 'choices': next}]));
    session.ws?.send({'type': 'poll-vote', 'conversationId': conversation.id, 'messageId': poll.id, 'choices': next});
  }

  /// Pin a message for everyone (null = unpin).
  void pin(String? messageId) {
    if (session.ws == null || !session.ws!.isConnected) {
      state = state.copyWith(error: 'Pinning needs a connection.');
      return;
    }
    session.ws!.send({'type': 'pin-message', 'conversationId': conversation.id, 'messageId': messageId});
  }

  void setDisappearing(int seconds) {
    if (session.ws == null || !session.ws!.isConnected) {
      state = state.copyWith(error: 'Changing this needs a connection.');
      return;
    }
    session.ws!.send({'type': 'set-disappearing', 'conversationId': conversation.id, 'seconds': seconds});
  }

  /// A view-once photo/video was just shown — never again on any device.
  void markViewOnceOpened(ChatMessage m) {
    _replace(m.id, (x) => x.copyWith(openedBy: {...x.openedBy, _myId}.toList()));
    _persist();
    session.ws?.send({'type': 'view-once-opened', 'conversationId': conversation.id, 'messageId': m.id});
  }

  /// The whole history, oldest first (for Export / Summarize). Pages
  /// through everything the server has, decrypting as it goes.
  Future<List<ChatMessage>> loadFullHistory({void Function(int loaded)? onProgress, int maxPages = 400}) async {
    _key ??= await resolveConversationKey(session, conversation);
    final all = <ChatMessage>[];
    String? before;
    for (var page = 0; page < maxPages; page++) {
      final raw = await session.api.listMessages(conversation.id, before: before);
      if (raw.isEmpty) break;
      final batch = <ChatMessage>[];
      for (final j in raw) {
        batch.add(await _decrypt(ChatMessage.fromJson(j as Map<String, dynamic>)));
      }
      all.insertAll(0, batch);
      onProgress?.call(all.length);
      before = batch.first.createdAt;
      if (raw.length < 50) break;
    }
    return all;
  }

  /// Encrypts the body under a fresh IV, uploads the opaque ciphertext blob,
  /// then sends the metadata (name/mime/size/blobIv + `extra`, e.g.
  /// `{gif: true}`) as a `file`- or `voice`-kind message. Unlike text,
  /// attachments need the connection right now — the upload is an HTTP request.
  Future<void> sendFile(
    Uint8List bytes, {
    required String name,
    required String mime,
    String kind = 'file',
    Map<String, dynamic> extra = const {},
    String? replyToId,
  }) async {
    if (!_ensureKey()) return;
    if (session.ws == null || !session.ws!.isConnected) {
      state = state.copyWith(offline: true, error: 'Attachments need a connection — try again when you\'re back online.');
      return;
    }
    try {
      if (await SignalService.instance.useFor(isGroup: conversation.isGroup, peerId: conversation.peer?.id)) {
        // Signal: the file gets its own key, sealed inside the message.
        final sealed = await sealFileForSignal(bytes, name: name, mime: mime, extra: extra);
        final up = await session.api.uploadBlob(sealed.blob);
        await _sendSealed(jsonEncode(sealed.meta),
            kind: kind,
            replyToId: replyToId,
            filePath: up['filePath'] as String,
            fileSize: up['fileSize'] as int,
            viewOnce: extra['viewOnce'] == true);
        return;
      }
      final envelope = await encryptFile(_key!, bytes, name: name, mime: mime, extra: extra);
      final upload = await session.api.uploadBlob(envelope.blob);
      final meta = jsonEncode({'name': name, 'mime': mime, 'size': bytes.length, ...extra});
      await _sendEncrypted(
        kind: kind,
        plaintext: meta,
        envelope: CipherEnvelope(ciphertext: envelope.metaCiphertext, iv: envelope.metaIv),
        replyToId: replyToId,
        filePath: upload['filePath'] as String,
        fileSize: upload['fileSize'] as int,
        viewOnce: extra['viewOnce'] == true,
      );
    } catch (e) {
      state = state.copyWith(error: 'Could not send the attachment: $e');
    }
  }

  /// GIF from the picker: the server fetches it from Tenor, then it's sent
  /// as an encrypted image with `{gif: true}` — same as the website.
  Future<void> sendGif(String url, {String? replyToId}) async {
    try {
      final bytes = await session.api.fetchGif(url);
      await sendFile(Uint8List.fromList(bytes), name: 'tenor.gif', mime: 'image/gif', extra: const {'gif': true}, replyToId: replyToId);
    } catch (e) {
      state = state.copyWith(error: 'Could not fetch that GIF.');
    }
  }

  /// Toggles my reaction: same emoji again removes it, a different one
  /// replaces it (the server keeps one reaction per person per message).
  Future<void> react(ChatMessage message, String emoji) async {
    if (!_ensureKey()) return;
    final current = message.reactions.where((r) => r['userId'] == _myId).firstOrNull;
    if (current?['emoji'] == emoji) {
      session.ws?.send({'type': 'react', 'conversationId': conversation.id, 'messageId': message.id, 'remove': true});
      return;
    }
    final env = await encryptText(_key!, emoji);
    session.ws?.send({
      'type': 'react',
      'conversationId': conversation.id,
      'messageId': message.id,
      'ciphertext': env.ciphertext,
      'iv': env.iv,
    });
  }

  /// Edits one of my text messages (shown straight away; the server's
  /// 'message-edited' echo confirms it for everyone).
  Future<void> editMessage(ChatMessage message, String newText) async {
    final text = newText.trim();
    if (text.isEmpty || !_ensureKey()) return;
    if (session.ws == null || !session.ws!.isConnected) {
      state = state.copyWith(error: 'Editing needs a connection.');
      return;
    }
    if (message.ciphertext == 'signal' && SignalService.instance.ready) {
      // A Signal message: the edit is sealed again for every device.
      _pendingEdits[message.id] = text;
      final envelopes = await SignalService.instance.seal([conversation.peer!.id, _myId], text);
      session.ws!.send({
        'type': 'edit-message',
        'conversationId': conversation.id,
        'messageId': message.id,
        'ciphertext': 'signal',
        'iv': 'signal',
        'envelopes': envelopes,
      });
      _replace(message.id, (m) => m.copyWith(plaintext: text, editedAt: DateTime.now().toUtc().toIso8601String()));
      await _persist();
      return;
    }
    final env = await encryptText(_key!, text);
    session.ws!.send({
      'type': 'edit-message',
      'conversationId': conversation.id,
      'messageId': message.id,
      'ciphertext': env.ciphertext,
      'iv': env.iv,
    });
    _replace(message.id, (m) => m.copyWith(
          ciphertext: env.ciphertext,
          iv: env.iv,
          plaintext: text,
          editedAt: DateTime.now().toUtc().toIso8601String(),
        ));
    await _persist();
  }

  /// Delete for everyone — only my own messages (the server enforces it too).
  Future<void> deleteForEveryone(List<ChatMessage> messages) async {
    if (session.ws == null || !session.ws!.isConnected) {
      state = state.copyWith(error: 'Deleting for everyone needs a connection.');
      return;
    }
    for (final m in messages.where((m) => m.senderId == _myId)) {
      session.ws!.send({'type': 'delete-message', 'conversationId': conversation.id, 'messageId': m.id});
    }
  }

  /// Delete for me — hides it from this account only; nobody else is affected.
  Future<void> deleteForMe(List<ChatMessage> messages) async {
    final failed = <String>[];
    for (final m in messages) {
      if (isPending(m)) continue; // never reached the server — nothing to hide there
      try {
        await session.api.hideMessage(m.id);
      } catch (_) {
        failed.add(m.id);
      }
    }
    final remove = messages.map((m) => m.id).toSet()..removeAll(failed);
    state = state.copyWith(
      messages: state.messages.where((m) => !remove.contains(m.id)).toList(),
      error: failed.isEmpty ? null : 'Some messages could not be deleted — check your connection.',
    );
    await _persist();
  }

  void setTyping(bool typing) {
    session.ws?.sendTyping(conversationId: conversation.id, isTyping: typing);
  }

  void clearError() => state = state.copyWith();

  bool _extending = false;

  /// Search reaches further back than the latest 50 messages: pages older
  /// history in (up to 10 × 50 = 500 messages), decrypting as it goes — the
  /// website's extendSearchHistory(). Best-effort; offline it just stops.
  Future<void> extendHistoryForSearch() async {
    if (_extending || _key == null) return;
    _extending = true;
    try {
      for (var batch = 0; batch < 10; batch++) {
        final oldest = state.messages.where((m) => !isPending(m)).firstOrNull;
        if (oldest == null) break;
        final raw = await session.api.listMessages(conversation.id, before: oldest.createdAt);
        if (raw.isEmpty) break;
        final have = state.messages.map((m) => m.id).toSet();
        final older = <ChatMessage>[];
        for (final j in raw) {
          final m = ChatMessage.fromJson(j as Map<String, dynamic>);
          if (!have.contains(m.id)) older.add(await _decrypt(m));
        }
        if (!mounted) return;
        state = state.copyWith(messages: [...older, ...state.messages]);
        if (raw.length < 50) break; // that was the start of the conversation
      }
    } catch (_) {
      // Search simply stays within what's already loaded.
    } finally {
      _extending = false;
    }
  }

  /// After "Clear chat" (server already cleared my view) — empty it here too.
  Future<void> clearLocal() async {
    state = state.copyWith(messages: const []);
    await _persist();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _typingTimer?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }
}

/// Forward — decrypt under the SOURCE chat's key, re-encrypt under the
/// TARGET chat's key and send as a new message. Files/voice notes are
/// downloaded, decrypted and re-uploaded, since a blob is only readable under
/// the chat it was sent to. Mirrors app.js's forwardMessageTo.
Future<void> forwardMessage({
  required Session session,
  required ChatMessage message,
  required SecretKey sourceKey,
  required Conversation target,
}) async {
  final targetKey = await resolveConversationKey(session, target);
  final tempId = const Uuid().v4();
  final ws = session.ws;
  if (ws == null) throw StateError('Not connected.');

  if (message.kind == 'file' || message.kind == 'voice') {
    final meta = message.payload ?? (throw StateError('This attachment can\'t be read.'));
    final blob = await session.api.downloadBlob(message.filePath!);
    final bytes = await decryptFileBytes(sourceKey, Uint8List.fromList(blob), meta['blobIv'] as String);
    final extra = Map<String, dynamic>.from(meta)..remove('name')..remove('mime')..remove('size')..remove('blobIv');
    final env = await encryptFile(
      targetKey,
      bytes,
      name: meta['name'] as String? ?? 'file',
      mime: meta['mime'] as String? ?? 'application/octet-stream',
      extra: extra,
    );
    final upload = await session.api.uploadBlob(env.blob);
    ws.sendMessage(
      conversationId: target.id,
      ciphertext: env.metaCiphertext,
      iv: env.metaIv,
      kind: message.kind,
      tempId: tempId,
      filePath: upload['filePath'] as String,
      fileSize: upload['fileSize'] as int,
    );
    return;
  }

  // text / location / contact — the decrypted body re-encrypted as-is.
  final body = message.plaintext ?? (throw StateError('This message can\'t be read.'));
  final env = await encryptText(targetKey, body);
  ws.sendMessage(conversationId: target.id, ciphertext: env.ciphertext, iv: env.iv, kind: message.kind, tempId: tempId);
}

final chatControllerProvider =
    StateNotifierProvider.family<ChatController, ChatState, Conversation>((ref, conversation) {
  final session = ref.watch(sessionControllerProvider);
  return ChatController(session, conversation);
});
