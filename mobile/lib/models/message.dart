import 'dart:convert';

/// Field names match the backend's shape_message() exactly. `ciphertext`/`iv`
/// arrive as opaque base64 strings — decrypting them into `plaintext` is the
/// UI layer's job (via core/crypto/keys.dart's deriveSharedKey/decryptText),
/// never done here, so this model stays valid for both encrypted-at-rest
/// (as stored/cached) and decrypted-for-display states.
class ChatMessage {
  final String id;
  final String senderId;
  final String kind; // 'text' | 'file' | 'voice' | 'location' | 'contact' | 'poll'
  final String ciphertext;
  final String iv;
  final String? filePath;
  final int? fileSize;
  final String createdAt;
  final String? deliveredAt;
  final String? readAt;
  final String? editedAt;
  final String? replyToId;
  /// `{userId, ciphertext, iv}` from the server, plus a decrypted `emoji`
  /// added client-side (kept in the cache so reactions show offline).
  final List<Map<String, dynamic>> reactions;

  /// Polls: `[{userId, choices: [optionIndex, ...]}]` — only the option
  /// numbers are visible to the server; the question/options are encrypted.
  final List<Map<String, dynamic>> votes;

  /// View-once photo/video, and who has already opened it.
  final bool viewOnce;
  final List<String> openedBy;

  /// Disappearing messages: when it vanishes (null = never).
  final String? expiresAt;

  /// Set when the sender deleted it for everyone while this chat was open
  /// (deleted messages are left out of history on the next load).
  final bool deleted;

  /// Populated client-side after decryption; null until then. Kept separate
  /// from the wire fields above rather than mutating them, so re-decrypting
  /// (e.g. after a key-cache clear) is always possible from the original data.
  final String? plaintext;

  /// Polls: when it closes (null = open until closed by hand).
  final String? pollClosesAt;
  /// "@everyone" in a group.
  final bool mentionAll;

  bool get pollClosed {
    final at = pollClosesAt == null ? null : DateTime.tryParse(pollClosesAt!);
    return at != null && !at.isAfter(DateTime.now());
  }

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.kind,
    required this.ciphertext,
    required this.iv,
    this.filePath,
    this.fileSize,
    required this.createdAt,
    this.deliveredAt,
    this.readAt,
    this.editedAt,
    this.replyToId,
    this.reactions = const [],
    this.votes = const [],
    this.viewOnce = false,
    this.openedBy = const [],
    this.expiresAt,
    this.deleted = false,
    this.plaintext,
    this.pollClosesAt,
    this.mentionAll = false,
  });

  /// Kinds whose decrypted body is a JSON object rather than plain text —
  /// same split as app.js's decryptBody.
  static const jsonKinds = {'file', 'voice', 'location', 'contact', 'poll', 'product'};

  /// The decrypted JSON body for file/voice/location/contact/poll, else null.
  Map<String, dynamic>? get payload {
    if (!jsonKinds.contains(kind) || plaintext == null) return null;
    try {
      return jsonDecode(plaintext!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  bool get isSticker => payload?['sticker'] == true;
  bool get isGif => payload?['gif'] == true;
  bool get isViewOnce => viewOnce || payload?['viewOnce'] == true;

  bool get isExpired {
    final at = expiresAt == null ? null : DateTime.tryParse(expiresAt!);
    return at != null && at.isBefore(DateTime.now());
  }

  /// Short one-line description — for reply quotes, the reply bar,
  /// forwarding and chat-list previews. Mirrors app.js's previewFor().
  String get preview {
    if (deleted) return 'This message was deleted';
    if (plaintext == null) return 'Encrypted message';
    switch (kind) {
      case 'poll':
        return '📊 ${payload?['question'] ?? 'Poll'}';
      case 'product':
        return '🛍 ${payload?['name'] ?? 'Product'}';
      case 'file':
        if (isViewOnce) {
          final video = (payload?['mime'] as String? ?? '').startsWith('video/');
          return video ? '🎥 Video · view once' : '📷 Photo · view once';
        }
        if (isGif) return 'GIF';
        if (isSticker) return 'Sticker';
        return payload?['name'] as String? ?? 'Attachment';
      case 'voice':
        return '🎤 Voice message';
      case 'location':
        return '📍 Location';
      case 'contact':
        return '👤 ${payload?['name'] ?? 'Contact'}';
      default:
        return stripPrivateReply(plaintext!);
    }
  }

  /// A "reply privately" message carries the quoted group message ahead of
  /// its text (see features/groups/group_tools.dart) — previews skip it.
  static String stripPrivateReply(String text) {
    if (!text.startsWith('\u2063PR')) return text;
    final end = text.indexOf('\u2063', 3);
    return end < 0 ? text : text.substring(end + 1);
  }

  ChatMessage copyWith({
    String? ciphertext,
    String? iv,
    String? deliveredAt,
    String? readAt,
    String? editedAt,
    List<Map<String, dynamic>>? reactions,
    List<Map<String, dynamic>>? votes,
    List<String>? openedBy,
    bool? deleted,
    String? plaintext,
    String? pollClosesAt,
  }) =>
      ChatMessage(
        id: id,
        senderId: senderId,
        kind: kind,
        ciphertext: ciphertext ?? this.ciphertext,
        iv: iv ?? this.iv,
        filePath: filePath,
        fileSize: fileSize,
        createdAt: createdAt,
        deliveredAt: deliveredAt ?? this.deliveredAt,
        readAt: readAt ?? this.readAt,
        editedAt: editedAt ?? this.editedAt,
        replyToId: replyToId,
        reactions: reactions ?? this.reactions,
        votes: votes ?? this.votes,
        viewOnce: viewOnce,
        openedBy: openedBy ?? this.openedBy,
        expiresAt: expiresAt,
        deleted: deleted ?? this.deleted,
        plaintext: plaintext ?? this.plaintext,
        pollClosesAt: pollClosesAt ?? this.pollClosesAt,
        mentionAll: mentionAll,
      );

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        senderId: json['senderId'] as String,
        kind: json['kind'] as String,
        ciphertext: json['ciphertext'] as String,
        iv: json['iv'] as String,
        filePath: json['filePath'] as String?,
        fileSize: json['fileSize'] as int?,
        createdAt: json['createdAt'] as String,
        deliveredAt: json['deliveredAt'] as String?,
        readAt: json['readAt'] as String?,
        editedAt: json['editedAt'] as String?,
        replyToId: json['replyToId'] as String?,
        reactions: (json['reactions'] as List<dynamic>? ?? [])
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(),
        votes: (json['votes'] as List<dynamic>? ?? [])
            .map((v) => Map<String, dynamic>.from(v as Map))
            .toList(),
        viewOnce: json['viewOnce'] as bool? ?? false,
        openedBy: (json['openedBy'] as List<dynamic>? ?? const []).cast<String>(),
        expiresAt: json['expiresAt'] as String?,
        deleted: json['deleted'] as bool? ?? false,
        plaintext: json['plaintext'] as String?,
        pollClosesAt: json['pollClosesAt'] as String?,
        mentionAll: json['mentionAll'] as bool? ?? false,
      );

  /// Includes `plaintext` (unlike the wire format from the API) — this is
  /// only ever used for the on-device cache, so a cached message can be
  /// shown offline without needing to re-derive any key or re-decrypt.
  Map<String, dynamic> toJson() => {
        'id': id,
        'senderId': senderId,
        'kind': kind,
        'ciphertext': ciphertext,
        'iv': iv,
        'filePath': filePath,
        'fileSize': fileSize,
        'createdAt': createdAt,
        'deliveredAt': deliveredAt,
        'readAt': readAt,
        'editedAt': editedAt,
        'replyToId': replyToId,
        'reactions': reactions,
        'votes': votes,
        'viewOnce': viewOnce,
        'openedBy': openedBy,
        'expiresAt': expiresAt,
        'deleted': deleted,
        'plaintext': plaintext,
        'pollClosesAt': pollClosesAt,
        'mentionAll': mentionAll,
      };

  /// Applies a live 'receipts' event ('delivered' or 'read'). The exact
  /// server timestamp doesn't travel with the event; "now" is close enough
  /// for the ticks, and the next history load replaces it with the real one.
  ChatMessage withReceipt(String status) {
    final now = DateTime.now().toUtc().toIso8601String();
    return copyWith(
      deliveredAt: deliveredAt ?? now, // read implies delivered
      readAt: status == 'read' ? (readAt ?? now) : readAt,
    );
  }

  ChatMessage withPlaintext(String text) => copyWith(plaintext: text);
}
