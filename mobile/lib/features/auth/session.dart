import '../../core/signal/signal_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav_key.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/crypto/identity.dart';
import '../../core/crypto/keys.dart';
import '../../core/local_cache.dart';
import '../../core/local_notifications.dart';
import '../../core/secure_key_store.dart';
import '../../core/chat_backup.dart';
import '../../core/ws_client.dart';
import '../../models/user.dart';

class Session {
  final ApiClient api;
  final AppUser? user;
  final EcKeyPair? identityKeyPair;
  final WsClient? ws;

  const Session({required this.api, this.user, this.identityKeyPair, this.ws});

  bool get isSignedIn => user != null && identityKeyPair != null;

  Session copyWith({AppUser? user, EcKeyPair? identityKeyPair, WsClient? ws}) => Session(
        api: api,
        user: user ?? this.user,
        identityKeyPair: identityKeyPair ?? this.identityKeyPair,
        ws: ws ?? this.ws,
      );
}

class SessionController extends StateNotifier<Session> {
  final SecureKeyStore _keyStore;

  SessionController(ApiClient api, {SecureKeyStore? keyStore})
      : _keyStore = keyStore ?? SecureKeyStore(),
        super(Session(api: api));

  Future<void> _connectAndSetSession(AppUser user, EcKeyPair keyPair) async {
    await _keyStore.saveSessionKey(keyPair);
    await _keyStore.saveUser(user.toJson());
    _enter(user, keyPair);
    _rescheduleReminders();
  }

  /// Signs in locally and starts the live connection. The socket keeps
  /// retrying on its own (see WsClient), so a server that's unreachable right
  /// now never blocks getting into the app.
  void _enter(AppUser user, EcKeyPair keyPair) {
    final ws = WsClient(
      uri: Uri.parse('${AppConfig.wsBaseUrl}/ws'),
      cookieProvider: state.api.sessionCookieHeader,
      deviceId: state.api.deviceId,
    );
    // This phone's Signal keys (made once, kept on the phone).
    SignalService.instance.init(state.api, user.id);
    ws.connect();
    ws.frames.listen((f) async {
      if (f['type'] == 'signal-devices-changed') SignalService.instance.forgetDevices(f['userId'] as String);
      // The server says devices changed under a queued Signal message: take
      // the new list, seal it again and resend — wherever the app is.
      if (f['type'] == 'signal-mismatch' && f['tempId'] is String) {
        final frame = ws.outboxFrame(f['tempId'] as String);
        if (frame == null || frame['_signalText'] == null) return;
        final tries = (frame['_tries'] as int? ?? 0) + 1;
        if (tries > 3) return;
        await SignalService.instance.applyDeviceList(Map<String, dynamic>.from(f['devices'] as Map));
        final envelopes = await SignalService.instance.seal(
            (frame['_members'] as List).cast<String>(), frame['_signalText'] as String);
        ws.resend(f['tempId'] as String, {...frame, 'envelopes': envelopes, '_tries': tries});
      }
    });
    // A dropped connection may mean "Log out all other devices" was used
    // elsewhere — ask the server; a definite 401 signs this phone out.
    ws.frames.listen((f) {
      if (f['type'] == 'disconnected' && state.isSignedIn) _syncWithServer();
    });
    state = state.copyWith(user: user, identityKeyPair: keyPair, ws: ws);
  }

  /// Back in the foreground: retry the connection now instead of waiting out
  /// the backoff, and re-check the session with the server.
  void onAppResumed() {
    state.ws?.reconnectNow();
    if (state.isSignedIn) _syncWithServer();
  }

  /// Local (on-device) notifications, unlike the account's server data,
  /// don't survive an app reinstall/reboot on their own -- re-arming every
  /// still-future reminder on each sign-in is the simplest way to keep this
  /// device's alarms in sync with the server's list without real push infra.
  Future<void> _rescheduleReminders() async {
    try {
      final rows = await state.api.listReminders();
      for (final r in rows) {
        final row = r as Map<String, dynamic>;
        if (row['notifiedAt'] != null) continue;
        final at = DateTime.parse(row['remindAt'] as String).toLocal();
        if (at.isBefore(DateTime.now())) continue;
        await LocalNotifications.scheduleReminder(
          id: row['id'] as String,
          content: row['content'] as String,
          category: row['category'] as String,
          remindAt: at,
        );
      }
    } catch (_) {
      // Best-effort -- reminders still show/manage fine from their own
      // screen even if this sync pass fails (e.g. offline sign-in restore).
    }
  }

  Future<void> register({
    required String username,
    required String displayName,
    required String password,
    required String phone,
    required String email,
    required String otp,
    String? birthDate,
  }) async {
    final keyPair = await generateIdentity();
    final publicJwk = await exportPublicKey(keyPair);
    final wrapped = await wrapPrivateKey(keyPair, password);
    final result = await state.api.register(
      username: username,
      displayName: displayName,
      password: password,
      publicKey: publicJwk.toJson(),
      encPrivateKey: wrapped.toJson(),
      phone: phone,
      email: email,
      otp: otp,
      birthDate: birthDate,
    );
    final user = AppUser.fromJson(result['user'] as Map<String, dynamic>);
    await _connectAndSetSession(user, keyPair);
  }

  /// [onPending] runs when the server holds the sign-in for approval (a
  /// phone this account hasn't used before) and returns the final result.
  Future<void> login({
    required String username,
    required String password,
    Future<Map<String, dynamic>> Function(Map<String, dynamic> pending)? onPending,
  }) async {
    var result = await state.api.login(username: username, password: password);
    if (result['pending'] == true) {
      if (onPending == null) throw ApiException(0, 'Accept this sign-in from your Gmail, then sign in again.');
      result = await onPending(result);
    }
    final user = AppUser.fromJson(result['user'] as Map<String, dynamic>);
    final wrapped = WrappedPrivateKey.fromJson(result['encPrivateKey'] as Map<String, dynamic>);
    final keyPair = await unwrapPrivateKey(wrapped, password);
    await _connectAndSetSession(user, keyPair);
  }

  /// Used by the QR device-link flow once /api/link/poll returns 'ready'
  /// (which already set the session cookie server-side) -- the identity key
  /// pair has already been unwrapped by the caller via openIdentityFromLink.
  Future<void> loginWithLinkedIdentity(AppUser user, EcKeyPair keyPair) => _connectAndSetSession(user, keyPair);

  /// Called at app startup. Stays signed in until the user logs out:
  /// the key and profile saved on this phone are enough to open the app,
  /// with or without a connection. The server is checked in the background
  /// afterwards — only a definite "not signed in" (401) signs the user out;
  /// being offline or the server being down never does.
  Future<void> tryRestoreSession() async {
    final keyPair = await _keyStore.loadSessionKey();
    if (keyPair == null) return;

    final saved = await _keyStore.loadUser();
    if (saved != null) {
      _enter(AppUser.fromJson(saved), keyPair);
      _syncWithServer();
      return;
    }

    // Signed in with an older app version that didn't save the profile —
    // this one time it has to come from the server.
    try {
      final result = await state.api.me();
      final user = AppUser.fromJson(result['user'] as Map<String, dynamic>);
      await _keyStore.saveUser(user.toJson());
      _enter(user, keyPair);
      _rescheduleReminders();
    } on ApiException catch (e) {
      if (e.statusCode == 401) await _signOutLocally();
    } catch (_) {
      // Offline on that first launch — the login screen shows; next launch
      // with a connection fixes it.
    }
  }

  /// Refreshes the profile (and, server-side, renews the session cookie).
  Future<void> _syncWithServer() async {
    try {
      final result = await state.api.me();
      final user = AppUser.fromJson(result['user'] as Map<String, dynamic>);
      await _keyStore.saveUser(user.toJson());
      if (state.isSignedIn) state = state.copyWith(user: user);
      _rescheduleReminders();
    } on ApiException catch (e) {
      if (e.statusCode == 401 && state.isSignedIn) {
        await _signOutLocally();
        final ctx = veyonNavigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          // One account per device: an older second account on this phone
          // is ended with the server's "belongs to @x" explanation.
          final deviceTaken = e.message.contains('belongs to @') || e.message.contains('suspended');
          ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
            content: Text(deviceTaken ? e.message : 'You were signed out from another device. Sign in again to continue.'),
            duration: Duration(seconds: deviceTaken ? 10 : 6),
          ));
        }
      }
    } catch (_) {
      // Offline — keep using the saved profile.
    }
  }

  /// Forgets this account on this phone (key, profile, cached chats, queued
  /// messages) — the same as the website's logout clearing its local store.
  Future<void> _signOutLocally() async {
    final uid = state.user?.id;
    if (uid != null) await SignalService.instance.wipe(uid);
    if (uid != null) await ChatBackup.forgetOnThisPhone(uid);
    await _keyStore.clearSessionKey();
    await _keyStore.clearUser();
    await LocalCache().clearAll();
    await state.ws?.clearOutbox();
    await state.ws?.close();
    clearKeyCache();
    state = Session(api: state.api);
  }

  /// Edit profile → Save. Keeps my appearance (the server's reply omits it).
  Future<void> updateProfile({required String displayName, required String about}) async {
    final row = await state.api.updateMe(displayName: displayName, about: about);
    final fresh = AppUser.fromJson(row);
    final user = state.user!.copyWith(displayName: fresh.displayName, about: fresh.about);
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  /// Business profile — `enabled` plus category/description/address/hours/
  /// email/website. Saved settings are kept on my profile for editing.
  Future<void> updateBusiness(Map<String, dynamic> business) async {
    final saved = await state.api.updateBusiness(business);
    final user = state.user!.copyWith(businessSettings: saved);
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  /// Saves a verified mobile number + Gmail (sign-up of older accounts, or a change).
  Future<void> updateContact({required String phone, required String email, required String otp}) async {
    final saved = await state.api.saveContact(phone: phone, email: email, otp: otp);
    final user = state.user!.copyWith(
      phone: saved['phone'] as String?,
      email: saved['email'] as String?,
      contactVerified: saved['contactVerified'] as bool?,
    );
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  Future<void> updateBirthDate(String birthDate, bool isAdult) async {
    final user = state.user!.copyWith(birthDate: birthDate, isAdult: isAdult);
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  /// Message / call notification switches (Chat features).
  Future<void> updateNotify({required bool messages, required bool calls}) async {
    final user = state.user!.copyWith(notifyMessages: messages, notifyCalls: calls);
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  Future<void> updatePrivateLock(bool on) async {
    final user = state.user!.copyWith(privateLock: on);
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  /// After saving a recovery key — keeps the profile's flag in step.
  Future<void> markRecoveryKeySaved() async {
    final user = state.user!.copyWith(hasRecoveryKey: true);
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  Future<void> updatePhoto(List<int> bytes, String mime) async {
    final row = await state.api.uploadMyPhoto(bytes, mime);
    final fresh = AppUser.fromJson(row);
    final user = state.user!.copyWith(photoUrl: fresh.photoUrl);
    await _keyStore.saveUser(user.toJson());
    state = state.copyWith(user: user);
  }

  /// Optimistic local update + best-effort server sync, same pattern as
  /// app.js's saveAppearanceToServer -- applying the new theme should never
  /// wait on a network round trip.
  Future<void> updateAppearance({String? palette, String? mode, String? structure}) async {
    final current = state.user?.appearance ?? const <String, dynamic>{};
    final optimistic = {...current, if (palette != null) 'palette': palette, if (mode != null) 'mode': mode, if (structure != null) 'structure': structure};
    state = state.copyWith(user: state.user?.copyWith(appearance: optimistic));
    try {
      final saved = await state.api.updateAppearance(palette: palette, mode: mode, structure: structure);
      state = state.copyWith(user: state.user?.copyWith(appearance: saved));
    } catch (_) {
      // Offline -- the optimistic local value stands; it'll sync next time
      // this or any other appearance change reaches the server.
    }
  }

  /// [releaseDevice] also frees this phone from the account (one account
  /// per device), so a different account can sign in here afterwards.
  /// Releasing needs the server, so it throws when offline instead of
  /// signing out with the phone still locked.
  Future<void> logout({bool releaseDevice = false}) async {
    if (releaseDevice) {
      await state.api.releaseDevice();
    } else {
      try {
        await state.api.logout();
      } catch (_) {
        // Offline — still sign out on this phone.
      }
    }
    await _signOutLocally();
  }
}

final apiClientProvider = FutureProvider<ApiClient>((ref) => ApiClient.create(AppConfig.apiBaseUrl));

final sessionControllerProvider =
    StateNotifierProvider<SessionController, Session>((ref) {
  final apiAsync = ref.watch(apiClientProvider);
  // Synchronously unwrap â€” app.dart gates on apiClientProvider being ready
  // before ever building anything that reads this, so `.value` is safe here.
  return SessionController(apiAsync.value!);
});
