/// Field names match shared.py's shape_user()/routes/users.py's shapeUser()
/// exactly — this is the JSON the API actually returns, camelCase throughout.
class AppUser {
  final String id;
  final String username;
  final String displayName;
  final String avatarColor;
  final String about;
  final String? photoUrl;
  final Map<String, dynamic>? publicKey; // JWK — see core/crypto/jwk.dart
  final String? lastSeen; // ISO 8601 string; parsed to DateTime only where needed
  final bool? youBlocked;
  final bool? blockedYou;
  // {palette, mode, structure} -- always present server-side (merged over
  // DEFAULT_APPEARANCE by shape_user()), so this is non-null once decoded
  // from any real API response.
  final Map<String, dynamic>? appearance;

  /// Public business profile (only when enabled): {category, description,
  /// address, hours, email, website}.
  final Map<String, dynamic>? business;

  /// My own saved business settings, including a disabled draft — only
  /// present on my own profile (from /api/auth/me).
  final Map<String, dynamic>? businessSettings;

  /// My own mobile number + Gmail (only on my own profile). `contactVerified`
  /// false = an older account that must add them before continuing.
  final String? phone;
  final String? email;
  final bool? contactVerified;

  /// Only on my own profile.
  final bool isAdmin;
  final bool hasRecoveryKey;
  /// Date of birth (YYYY-MM-DD); 1-to-1 chats are for 18+.
  final String? birthDate;
  final bool isAdult;
  /// Every 1-to-1 chat sits behind the chat-lock PIN.
  final bool privateLock;
  /// Message / call notifications on (saved on the account, same as the website).
  final bool notifyMessages;
  final bool notifyCalls;

  const AppUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.avatarColor,
    required this.about,
    this.photoUrl,
    this.publicKey,
    this.lastSeen,
    this.youBlocked,
    this.blockedYou,
    this.appearance,
    this.business,
    this.businessSettings,
    this.phone,
    this.email,
    this.contactVerified,
    this.isAdmin = false,
    this.hasRecoveryKey = false,
    this.birthDate,
    this.isAdult = false,
    this.privateLock = false,
    this.notifyMessages = true,
    this.notifyCalls = true,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        username: json['username'] as String,
        displayName: json['displayName'] as String,
        avatarColor: json['avatarColor'] as String,
        about: json['about'] as String? ?? '',
        photoUrl: json['photoUrl'] as String?,
        publicKey: json['publicKey'] as Map<String, dynamic>?,
        lastSeen: json['lastSeen'] as String?,
        youBlocked: json['youBlocked'] as bool?,
        blockedYou: json['blockedYou'] as bool?,
        appearance: json['appearance'] as Map<String, dynamic>?,
        business: json['business'] as Map<String, dynamic>?,
        businessSettings: json['businessSettings'] as Map<String, dynamic>?,
        phone: json['phone'] as String?,
        email: json['email'] as String?,
        contactVerified: json['contactVerified'] as bool?,
        isAdmin: json['isAdmin'] as bool? ?? false,
        hasRecoveryKey: json['hasRecoveryKey'] as bool? ?? false,
        birthDate: json['birthDate'] as String?,
        isAdult: json['isAdult'] as bool? ?? false,
        privateLock: json['privateLock'] as bool? ?? false,
        notifyMessages: json['notifyMessages'] as bool? ?? true,
        notifyCalls: json['notifyCalls'] as bool? ?? true,
      );

  /// Same shape fromJson reads — used to keep the signed-in user on-device so
  /// the app can open offline.
  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'displayName': displayName,
        'avatarColor': avatarColor,
        'about': about,
        'photoUrl': photoUrl,
        'publicKey': publicKey,
        'lastSeen': lastSeen,
        'youBlocked': youBlocked,
        'blockedYou': blockedYou,
        'appearance': appearance,
        'business': business,
        'businessSettings': businessSettings,
        'phone': phone,
        'email': email,
        'contactVerified': contactVerified,
        'isAdmin': isAdmin,
        'hasRecoveryKey': hasRecoveryKey,
        'birthDate': birthDate,
        'isAdult': isAdult,
        'privateLock': privateLock,
        'notifyMessages': notifyMessages,
        'notifyCalls': notifyCalls,
      };

  AppUser copyWith({
    Map<String, dynamic>? appearance,
    String? displayName,
    String? about,
    String? photoUrl,
    Map<String, dynamic>? businessSettings,
    String? phone,
    String? email,
    bool? contactVerified,
    bool? hasRecoveryKey,
    String? birthDate,
    bool? isAdult,
    bool? privateLock,
    bool? notifyMessages,
    bool? notifyCalls,
  }) =>
      AppUser(
        id: id,
        username: username,
        displayName: displayName ?? this.displayName,
        avatarColor: avatarColor,
        about: about ?? this.about,
        photoUrl: photoUrl ?? this.photoUrl,
        publicKey: publicKey,
        lastSeen: lastSeen,
        youBlocked: youBlocked,
        blockedYou: blockedYou,
        appearance: appearance ?? this.appearance,
        business: business,
        businessSettings: businessSettings ?? this.businessSettings,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        contactVerified: contactVerified ?? this.contactVerified,
        isAdmin: isAdmin,
        hasRecoveryKey: hasRecoveryKey ?? this.hasRecoveryKey,
        birthDate: birthDate ?? this.birthDate,
        isAdult: isAdult ?? this.isAdult,
        privateLock: privateLock ?? this.privateLock,
        notifyMessages: notifyMessages ?? this.notifyMessages,
        notifyCalls: notifyCalls ?? this.notifyCalls,
      );
}
