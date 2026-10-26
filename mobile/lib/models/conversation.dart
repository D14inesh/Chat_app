import 'user.dart';

/// Mirrors shared.py's shape_conversation() — one class covering both the
/// 'direct' and 'group' shapes it can return, since the API discriminates
/// by the `kind` field rather than a different endpoint/type.
class LastMessagePreview {
  final String id;
  final String senderId;
  final String kind;
  final String ciphertext;
  final String iv;
  final String createdAt;
  final String? deliveredAt;
  final String? readAt;
  final bool viewOnce;

  const LastMessagePreview({
    required this.id,
    required this.senderId,
    required this.kind,
    required this.ciphertext,
    required this.iv,
    required this.createdAt,
    this.deliveredAt,
    this.readAt,
    this.viewOnce = false,
  });

  factory LastMessagePreview.fromJson(Map<String, dynamic> json) => LastMessagePreview(
        id: json['id'] as String,
        senderId: json['senderId'] as String,
        kind: json['kind'] as String,
        ciphertext: json['ciphertext'] as String,
        iv: json['iv'] as String,
        createdAt: json['createdAt'] as String,
        deliveredAt: json['deliveredAt'] as String?,
        readAt: json['readAt'] as String?,
        viewOnce: json['viewOnce'] as bool? ?? false,
      );
}

class Conversation {
  final String id;
  final String kind; // 'direct' | 'group'
  final int unread;
  final bool favorite;
  final String? wallpaper;
  final String? wallpaperPhotoUrl;
  final String wallpaperFit;
  final bool muted;
  /// Muted for a while ("8 hours", "1 week"); null = always / not muted.
  final String? mutedUntil;
  /// Pinned to the top of my chat list (up to 3); null = not pinned.
  final String? pinnedAt;
  bool get pinned => pinnedAt != null;
  /// Hidden behind my chat-lock PIN (per person, like muted).
  final bool locked;
  /// Archived by me: out of the main list, no notifications.
  final bool archived;
  final LastMessagePreview? lastMessage;

  /// Disappearing-messages timer for everyone in the chat (0 = off).
  final int disappearSeconds;

  /// The chat's pinned message as the server sent it (still encrypted), and
  /// who pinned it. Shared by everyone in the chat.
  final Map<String, dynamic>? pinnedMessage;
  final String? pinnedBy;

  // 'direct' only
  final String? status; // 'pending' | 'accepted'
  final String? requestedBy;
  final AppUser? peer;

  // 'group' only
  final String? title;
  final String? avatarColor;
  final int? memberCount;
  final String description;
  final bool onlyAdminsSend;
  final String myRole; // owner | admin | member
  final String? inviteCode; // admins only
  final int joinRequests; // admins only
  final String? communityId;
  final bool isAnnouncement;

  bool get iAmAdmin => isGroup && (myRole == 'owner' || myRole == 'admin');
  /// Admin-only group and I'm a plain member: no composer.
  bool get sendLocked => isGroup && onlyAdminsSend && !iAmAdmin;

  const Conversation({
    required this.id,
    required this.kind,
    required this.unread,
    required this.favorite,
    this.wallpaper,
    this.wallpaperPhotoUrl,
    required this.wallpaperFit,
    required this.muted,
    this.mutedUntil,
    this.pinnedAt,
    this.locked = false,
    this.archived = false,
    this.lastMessage,
    this.disappearSeconds = 0,
    this.pinnedMessage,
    this.pinnedBy,
    this.status,
    this.requestedBy,
    this.peer,
    this.title,
    this.avatarColor,
    this.memberCount,
    this.description = '',
    this.onlyAdminsSend = false,
    this.myRole = 'member',
    this.inviteCode,
    this.joinRequests = 0,
    this.communityId,
    this.isAnnouncement = false,
  });

  Conversation copyWith({
    int? unread,
    bool? favorite,
    bool? muted,
    String? status,
    int? disappearSeconds,
    String? title,
    String? description,
    bool? onlyAdminsSend,
    String? myRole,
    String? inviteCode,
    bool clearInvite = false,
    int? joinRequests,
    bool? archived,
    String? mutedUntil,
    bool clearMutedUntil = false,
    String? pinnedAt,
    bool clearPinnedAt = false,
  }) =>
      Conversation(
        id: id,
        kind: kind,
        unread: unread ?? this.unread,
        favorite: favorite ?? this.favorite,
        wallpaper: wallpaper,
        wallpaperPhotoUrl: wallpaperPhotoUrl,
        wallpaperFit: wallpaperFit,
        muted: muted ?? this.muted,
        mutedUntil: clearMutedUntil ? null : (mutedUntil ?? this.mutedUntil),
        pinnedAt: clearPinnedAt ? null : (pinnedAt ?? this.pinnedAt),
        locked: locked,
        archived: archived ?? this.archived,
        lastMessage: lastMessage,
        disappearSeconds: disappearSeconds ?? this.disappearSeconds,
        pinnedMessage: pinnedMessage,
        pinnedBy: pinnedBy,
        status: status ?? this.status,
        requestedBy: requestedBy,
        peer: peer,
        title: title ?? this.title,
        avatarColor: avatarColor,
        memberCount: memberCount,
        description: description ?? this.description,
        onlyAdminsSend: onlyAdminsSend ?? this.onlyAdminsSend,
        myRole: myRole ?? this.myRole,
        inviteCode: clearInvite ? null : (inviteCode ?? this.inviteCode),
        joinRequests: joinRequests ?? this.joinRequests,
        communityId: communityId,
        isAnnouncement: isAnnouncement,
      );

  bool get isGroup => kind == 'group';
  bool get isPending => status == 'pending';

  /// What to show in the chat list / header — the peer's name for a direct
  /// chat, the group title otherwise.
  String displayName(String fallback) => isGroup ? (title ?? fallback) : (peer?.displayName ?? fallback);

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        kind: json['kind'] as String,
        unread: json['unread'] as int? ?? 0,
        favorite: json['favorite'] as bool? ?? false,
        wallpaper: json['wallpaper'] as String?,
        wallpaperPhotoUrl: json['wallpaperPhotoUrl'] as String?,
        wallpaperFit: json['wallpaperFit'] as String? ?? 'cover',
        muted: json['muted'] as bool? ?? false,
        mutedUntil: json['mutedUntil'] as String?,
        pinnedAt: json['pinnedAt'] as String?,
        locked: json['locked'] as bool? ?? false,
        archived: json['archived'] as bool? ?? false,
        lastMessage: json['lastMessage'] == null
            ? null
            : LastMessagePreview.fromJson(json['lastMessage'] as Map<String, dynamic>),
        disappearSeconds: json['disappearSeconds'] as int? ?? 0,
        pinnedMessage: json['pinnedMessage'] as Map<String, dynamic>?,
        pinnedBy: json['pinnedBy'] as String?,
        status: json['status'] as String?,
        requestedBy: json['requestedBy'] as String?,
        peer: json['peer'] == null ? null : AppUser.fromJson(json['peer'] as Map<String, dynamic>),
        title: json['title'] as String?,
        avatarColor: json['avatarColor'] as String?,
        memberCount: json['memberCount'] as int?,
        description: json['description'] as String? ?? '',
        onlyAdminsSend: json['onlyAdminsSend'] as bool? ?? false,
        myRole: json['myRole'] as String? ?? 'member',
        inviteCode: json['inviteCode'] as String?,
        joinRequests: json['joinRequests'] as int? ?? 0,
        communityId: json['communityId'] as String?,
        isAnnouncement: json['isAnnouncement'] as bool? ?? false,
      );
}
