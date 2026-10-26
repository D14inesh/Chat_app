/// A local privacy screen, not real security -- exactly the caveat app.js's
/// own app-lock code documents (app.js:9034-9035): the identity key this
/// gate would "protect" already sits in this device's secure storage
/// regardless of whether the gate is unlocked. Its only job is stopping a
/// casual glance at an unlocked phone from reading someone's chats.
library app_lock_store;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AppLockMethod { none, pin, pattern, biometric }

class AppLockStore {
  static const _methodKey = 'veyon_applock_method';
  static const _pinHashKey = 'veyon_applock_pin_hash';

  final FlutterSecureStorage _storage;
  AppLockStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  Future<AppLockMethod> getMethod() async {
    final raw = await _storage.read(key: _methodKey);
    return AppLockMethod.values.firstWhere((m) => m.name == raw, orElse: () => AppLockMethod.none);
  }

  Future<void> setPin(String pin) async {
    final hash = await _hash(pin);
    await _storage.write(key: _pinHashKey, value: hash);
    await _storage.write(key: _methodKey, value: AppLockMethod.pin.name);
  }

  Future<bool> verifyPin(String pin) async {
    final stored = await _storage.read(key: _pinHashKey);
    if (stored == null) return false;
    return stored == await _hash(pin);
  }

  /// A pattern is stored the same way as a PIN — a hash of the dot sequence
  /// ("0-4-8-7"), exactly like the website.
  Future<void> setPattern(List<int> dots) async {
    await _storage.write(key: _pinHashKey, value: await _hash(dots.join('-')));
    await _storage.write(key: _methodKey, value: AppLockMethod.pattern.name);
  }

  Future<bool> verifyPattern(List<int> dots) => verifyPin(dots.join('-'));

  Future<void> enableBiometric() async {
    await _storage.write(key: _methodKey, value: AppLockMethod.biometric.name);
  }

  Future<void> disable() async {
    await _storage.delete(key: _methodKey);
    await _storage.delete(key: _pinHashKey);
  }

  Future<String> _hash(String pin) async {
    final digest = await Sha256().hash(utf8.encode(pin));
    return base64Encode(digest.bytes);
  }
}
