/// Chat backup — WhatsApp-style end-to-end encrypted backup (the website's
/// features/backup.js; same file format, so a backup made on the phone opens
/// on the website and the other way round).
///
/// Signal messages can be opened only once, on the device they reach, so this
/// phone's saved copy is the only readable one. A backup keeps them safe:
/// everything this phone has opened is packed up, locked with a key made from
/// a backup password only the person knows, and the locked file is kept on
/// the server, which can store it but never read it.
///
/// File: "VBK1" | iterations (u32 BE) | salt (16) | iv (12) | AES-256-GCM(gzip(JSON)) + tag
/// key = PBKDF2-HMAC-SHA256(password, salt, iterations) → 32 bytes
/// JSON = {v: 1, userId, createdAt, kept: [{id, text, editedAt}]}
library chat_backup;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'prefs_store.dart';
import 'signal/signal_service.dart';

const _magic = [0x56, 0x42, 0x4b, 0x31]; // "VBK1"
const backupIterations = 250000; // same cost as the sign-in key
const _periods = {'daily': Duration(days: 1), 'weekly': Duration(days: 7)};

class WrongBackupPassword implements Exception {
  @override
  String toString() => 'Wrong backup password.';
}

class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

/// What the server knows about the backup (never its contents).
class BackupInfo {
  final int size;
  final int messageCount;
  final String device;
  final DateTime createdAt;
  BackupInfo.fromJson(Map<String, dynamic> j)
      : size = (j['size'] as num).toInt(),
        messageCount = (j['messageCount'] as num?)?.toInt() ?? 0,
        device = j['device'] as String? ?? '',
        createdAt = DateTime.parse(j['createdAt'] as String).toLocal();
}

/// This phone's backup settings: the key (never the password).
class BackupConf {
  final String salt;
  final int iterations;
  final String key;
  final String freq; // daily | weekly | off
  final int last; // ms since epoch
  const BackupConf({required this.salt, required this.iterations, required this.key, this.freq = 'daily', this.last = 0});

  BackupConf copyWith({String? freq, int? last}) =>
      BackupConf(salt: salt, iterations: iterations, key: key, freq: freq ?? this.freq, last: last ?? this.last);

  Map<String, dynamic> toJson() => {'salt': salt, 'iterations': iterations, 'key': key, 'freq': freq, 'last': last};
  factory BackupConf.fromJson(Map<String, dynamic> j) => BackupConf(
        salt: j['salt'] as String,
        iterations: (j['iterations'] as num).toInt(),
        key: j['key'] as String,
        freq: j['freq'] as String? ?? 'daily',
        last: (j['last'] as num?)?.toInt() ?? 0,
      );
}

// ── File format (pure — also used by the tests) ──
Future<List<int>> deriveBackupKey(String password, List<int> salt, int iterations) async {
  final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
  final key = await pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  return key.extractBytes();
}

Future<Uint8List> sealBackup(Map<String, dynamic> payload, List<int> key, List<int> salt, int iterations) async {
  final zipped = GZipCodec().encode(utf8.encode(jsonEncode(payload)));
  final iv = _random(12);
  final box = await AesGcm.with256bits().encrypt(zipped, secretKey: SecretKey(key), nonce: iv);
  final out = BytesBuilder()
    ..add(_magic)
    ..add((ByteData(4)..setUint32(0, iterations)).buffer.asUint8List())
    ..add(salt)
    ..add(iv)
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return out.toBytes();
}

({int iterations, List<int> salt, List<int> iv, List<int> body}) backupHeader(List<int> bytes) {
  if (bytes.length < 36 + 16 || List.generate(4, (i) => bytes[i]).join() != _magic.join()) {
    throw BackupException("This isn't a chat backup.");
  }
  final b = Uint8List.fromList(bytes);
  return (
    iterations: ByteData.sublistView(b, 4, 8).getUint32(0),
    salt: b.sublist(8, 24),
    iv: b.sublist(24, 36),
    body: b.sublist(36),
  );
}

/// Throws [WrongBackupPassword] when the key doesn't open it.
Future<Map<String, dynamic>> openBackup(List<int> bytes, List<int> key) async {
  final h = backupHeader(bytes);
  final ct = h.body.sublist(0, h.body.length - 16);
  final tag = h.body.sublist(h.body.length - 16);
  List<int> zipped;
  try {
    zipped = await AesGcm.with256bits().decrypt(SecretBox(ct, nonce: h.iv, mac: Mac(tag)), secretKey: SecretKey(key));
  } on SecretBoxAuthenticationError {
    throw WrongBackupPassword();
  }
  return jsonDecode(utf8.decode(GZipCodec().decode(zipped))) as Map<String, dynamic>;
}

List<int> _random(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(256));
}

// ── The backup service ──
class ChatBackup {
  final ApiClient api;
  final String userId;
  ChatBackup(this.api, this.userId);

  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  String get _confKey => 'veyon_backup_$userId';
  String get _askedKey => 'veyon_backup_asked_$userId';

  Future<BackupConf?> conf() async {
    try {
      final raw = await _storage.read(key: _confKey);
      return raw == null ? null : BackupConf.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> setConf(BackupConf? c) async {
    if (c == null) {
      await _storage.delete(key: _confKey);
    } else {
      await _storage.write(key: _confKey, value: jsonEncode(c.toJson()));
    }
  }

  Future<BackupInfo?> info() async {
    try {
      final b = (await api.getJson('/api/backup'))['backup'];
      return b == null ? null : BackupInfo.fromJson(b as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<List<int>?> _download() async {
    try {
      return await api.fetchBytes('/api/backup/data');
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Packs up everything this phone has opened, merged with what's already
  /// in the backup (other devices' messages are kept), and uploads it.
  /// Returns false when the backup on the server uses a different password.
  Future<bool> backUpNow([BackupConf? c]) async {
    c ??= await conf();
    if (c == null) throw BackupException('Backup is off.');
    final key = base64Decode(c.key);
    final merged = <String, Map<String, dynamic>>{};

    final existing = await _download().catchError((_) => null);
    if (existing != null) {
      final h = backupHeader(existing);
      if (base64Encode(h.salt) != c.salt) return false;
      try {
        final old = await openBackup(existing, key);
        for (final k in (old['kept'] as List<dynamic>? ?? const [])) {
          merged[(k as Map)['id'].toString()] = Map<String, dynamic>.from(k);
        }
      } on WrongBackupPassword {
        return false;
      }
    }
    for (final k in await SignalService.instance.exportKept()) {
      merged[k['id'] as String] = k; // this phone's copy wins
    }

    final kept = merged.values.toList();
    final payload = {'v': 1, 'userId': userId, 'createdAt': DateTime.now().toUtc().toIso8601String(), 'kept': kept};
    final blob = await sealBackup(payload, key, base64Decode(c.salt), c.iterations);
    await api.putBackup(blob, messageCount: kept.length, device: 'Phone');
    await setConf(c.copyWith(last: DateTime.now().millisecondsSinceEpoch));
    return true;
  }

  /// Turns backup on (or changes its password) and backs up right away.
  Future<void> setPassword(String password, {bool change = false, bool replace = false}) async {
    final old = await conf();
    // Changing the password keeps what the current backup holds.
    if (change && old != null) {
      final existing = await _download().catchError((_) => null);
      if (existing != null) {
        try {
          final data = await openBackup(existing, base64Decode(old.key));
          await SignalService.instance.importKept(data['kept'] as List<dynamic>? ?? const []);
        } catch (_) {}
      }
    }
    final salt = _random(16);
    final key = await deriveBackupKey(password, salt, backupIterations);
    final c = BackupConf(salt: base64Encode(salt), iterations: backupIterations, key: base64Encode(key), freq: old?.freq ?? 'daily');
    if (change || replace) await api.deleteJson('/api/backup');
    await setConf(c);
    await backUpNow(c);
  }

  /// Opens the server backup with [password] and puts its messages back.
  /// Returns how many messages the backup held.
  Future<int> restore(String password) async {
    final bytes = await _download();
    if (bytes == null) throw BackupException("There's no backup to restore.");
    final h = backupHeader(bytes);
    final key = await deriveBackupKey(password, h.salt, h.iterations);
    final data = await openBackup(bytes, key); // throws WrongBackupPassword
    if (data['userId'] != null && data['userId'] != userId) {
      throw BackupException('This backup belongs to another account.');
    }
    final kept = data['kept'] as List<dynamic>? ?? const [];
    await SignalService.instance.importKept(kept);
    // Restoring brings back what was cleared in Storage & data, too.
    PrefsStore.instance.put('clearedBefore', <String, dynamic>{});
    final old = await conf();
    await setConf(BackupConf(
      salt: base64Encode(h.salt),
      iterations: h.iterations,
      key: base64Encode(key),
      freq: old?.freq ?? 'daily',
      last: DateTime.now().millisecondsSinceEpoch,
    ));
    return kept.length;
  }

  /// Sign-out: this phone's opened messages go, so its backup settings go
  /// too (signing in again offers the restore).
  static Future<void> forgetOnThisPhone(String userId) async {
    try {
      await _storage.delete(key: 'veyon_backup_$userId');
      await _storage.delete(key: 'veyon_backup_asked_$userId');
    } catch (_) {}
  }

  Future<void> turnOff() async {
    await api.deleteJson('/api/backup');
    await setConf(null);
  }

  /// After sign-in: backs up when one is due. Returns the backup to offer
  /// for restore when this phone has no backup set up yet (asked once).
  Future<BackupInfo?> onSignedIn() async {
    final c = await conf();
    if (c != null) {
      final period = _periods[c.freq];
      if (period != null && DateTime.now().millisecondsSinceEpoch - c.last >= period.inMilliseconds) {
        try {
          await backUpNow(c);
        } catch (_) {/* tries again next time */}
      }
      return null;
    }
    if (await _storage.read(key: _askedKey) != null) return null;
    final backup = await info();
    if (backup == null) return null;
    await _storage.write(key: _askedKey, value: '1');
    return backup;
  }
}
