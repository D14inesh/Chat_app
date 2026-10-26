/// Persists the unwrapped identity private key on-device between app
/// launches, so the user isn't asked for their password every time â€” the
/// mobile equivalent of crypto.js's saveSessionKey/loadSessionKey (which use
/// a non-extractable key kept in IndexedDB). Mobile has no direct analogue
/// of "non-extractable" for a key you also need to actively use for ECDH,
/// so the equivalent trust boundary here is the OS keystore instead:
/// flutter_secure_storage backs onto the iOS Keychain / Android Keystore,
/// which is the platform-appropriate place for key material at rest.
library secure_key_store;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'crypto/identity.dart';
import 'crypto/jwk.dart';

class SecureKeyStore {
  static const _keyName = 'veyon_identity_private_key_jwk';
  final FlutterSecureStorage _storage;

  SecureKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  Future<void> saveSessionKey(EcKeyPair keyPair) async {
    final jwk = await exportPrivateKeyJwk(keyPair);
    await _storage.write(key: _keyName, value: jsonEncode(jwk.toJson()));
  }

  Future<EcKeyPair?> loadSessionKey() async {
    final raw = await _storage.read(key: _keyName);
    if (raw == null) return null;
    try {
      final jwk = EcPrivateJwk.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return importPrivateKeyJwk(jwk);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearSessionKey() => _storage.delete(key: _keyName);

  // The signed-in user's profile, kept next to the key so the app can open
  // straight into the chats with no network — the server isn't needed to
  // know who's signed in on this phone.
  static const _userName = 'veyon_signed_in_user';

  Future<void> saveUser(Map<String, dynamic> userJson) =>
      _storage.write(key: _userName, value: jsonEncode(userJson));

  Future<Map<String, dynamic>?> loadUser() async {
    final raw = await _storage.read(key: _userName);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearUser() => _storage.delete(key: _userName);
}
