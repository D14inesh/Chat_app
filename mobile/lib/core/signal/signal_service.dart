/// Signal protocol (X3DH + Double Ratchet) for this phone — the app's
/// side of the website's js/signal.js; both talk the same Signal format
/// (checked by an interop test in both directions).
///
/// This phone is its own Signal device: its private keys are made here and
/// never leave it (app-private storage). The server's key directory only
/// holds the public halves, and every message is sealed once per receiving
/// device. A Double-Ratchet message can be opened only once, so whatever is
/// opened here is kept here and read back from there afterwards — the chat
/// screen, notifications and chat-list previews all go through [open].
library signal_service;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:path_provider/path_provider.dart';

import '../api_client.dart';

const _preKeyFirst = 20; // at set-up, so a new phone is reachable straight away
const _preKeyBatch = 100;
const _preKeyLow = 30;
const _deviceCacheTtl = Duration(seconds: 60);

/// The library's store, saved to a file after every change.
class _Store implements SignalProtocolStore {
  _Store(this.identity, this.registrationId, this.onChange);

  final IdentityKeyPair identity;
  final int registrationId;
  final Future<void> Function() onChange;
  final preKeys = InMemoryPreKeyStore();
  final signed = InMemorySignedPreKeyStore();
  final sessions = InMemorySessionStore();
  final identities = <String, Uint8List>{}; // "user.device" -> identity key

  // Identity: trust on first use, accept a changed key (they reinstalled).
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => identity;
  @override
  Future<int> getLocalRegistrationId() async => registrationId;
  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? key) async {
    if (key == null) return false;
    final k = address.toString();
    final old = identities[k];
    identities[k] = key.serialize();
    await onChange();
    return old != null && base64Encode(old) != base64Encode(identities[k]!);
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? key, Direction direction) async => true;
  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final k = identities[address.toString()];
    return k == null ? null : IdentityKey.fromBytes(k, 0);
  }

  // Pre-keys.
  @override
  Future<PreKeyRecord> loadPreKey(int id) => preKeys.loadPreKey(id);
  @override
  Future<void> storePreKey(int id, PreKeyRecord r) async {
    await preKeys.storePreKey(id, r);
    await onChange();
  }

  @override
  Future<bool> containsPreKey(int id) => preKeys.containsPreKey(id);
  @override
  Future<void> removePreKey(int id) async {
    await preKeys.removePreKey(id);
    await onChange();
  }

  // Signed pre-keys.
  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int id) => signed.loadSignedPreKey(id);
  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() => signed.loadSignedPreKeys();
  @override
  Future<void> storeSignedPreKey(int id, SignedPreKeyRecord r) async {
    await signed.storeSignedPreKey(id, r);
    await onChange();
  }

  @override
  Future<bool> containsSignedPreKey(int id) => signed.containsSignedPreKey(id);
  @override
  Future<void> removeSignedPreKey(int id) async {
    await signed.removeSignedPreKey(id);
    await onChange();
  }

  // Sessions.
  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress a) => sessions.loadSession(a);
  @override
  Future<List<int>> getSubDeviceSessions(String name) => sessions.getSubDeviceSessions(name);
  @override
  Future<void> storeSession(SignalProtocolAddress a, SessionRecord r) async {
    await sessions.storeSession(a, r);
    await onChange();
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress a) => sessions.containsSession(a);
  @override
  Future<void> deleteSession(SignalProtocolAddress a) async {
    await sessions.deleteSession(a);
    await onChange();
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    await sessions.deleteAllSessions(name);
    await onChange();
  }

  Map<String, dynamic> toJson() => {
        'identity': base64Encode(identity.serialize()),
        'registrationId': registrationId,
        'preKeys': {for (final e in preKeys.store.entries) '${e.key}': base64Encode(e.value)},
        'signed': {for (final e in signed.store.entries) '${e.key}': base64Encode(e.value)},
        'sessions': {for (final e in sessions.sessions.entries) '${e.key.getName()}.${e.key.getDeviceId()}': base64Encode(e.value)},
        'identities': {for (final e in identities.entries) e.key: base64Encode(e.value)},
      };

  static _Store fromJson(Map<String, dynamic> j, Future<void> Function() onChange) {
    final s = _Store(IdentityKeyPair.fromSerialized(base64Decode(j['identity'] as String)), j['registrationId'] as int, onChange);
    (j['preKeys'] as Map).forEach((k, v) => s.preKeys.store[int.parse(k as String)] = base64Decode(v as String));
    (j['signed'] as Map).forEach((k, v) => s.signed.store[int.parse(k as String)] = base64Decode(v as String));
    (j['sessions'] as Map).forEach((k, v) {
      final parts = (k as String).split('.');
      s.sessions.sessions[SignalProtocolAddress(parts[0], int.parse(parts[1]))] = base64Decode(v as String);
    });
    (j['identities'] as Map).forEach((k, v) => s.identities[k as String] = base64Decode(v as String));
    return s;
  }
}

/// The two calls the Signal service needs from the server (a stand-in can
/// be given in tests).
abstract class SignalApi {
  Future<Map<String, dynamic>> getJson(String path);
  Future<Map<String, dynamic>> postJson(String path, [Object? data]);
}

class _ClientApi implements SignalApi {
  _ClientApi(this.api);
  final ApiClient api;
  @override
  Future<Map<String, dynamic>> getJson(String path) => api.getJson(path);
  @override
  Future<Map<String, dynamic>> postJson(String path, [Object? data]) => api.postJson(path, data);
}

class SignalService {
  SignalService._();
  static final instance = SignalService._();

  /// A separate instance (tests run two people side by side).
  @visibleForTesting
  SignalService.forTest();

  SignalApi? _api;
  String? _userId;
  _Store? _store;
  int? _myDevice;
  int _nextPreKeyId = 1;
  File? _stateFile;
  File? _keptFile;
  Map<String, dynamic> _kept = {}; // messageId -> {text, editedAt}
  final _deviceCache = <String, ({DateTime at, List<int> devices})>{};
  Future<void>? _ready;
  final _opening = <String, Future<String?>>{}; // one open per message at a time

  bool get ready => _myDevice != null;
  int? get deviceId => _myDevice;

  Future<Directory> _dir(String userId) async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/signal/$userId');
    await d.create(recursive: true);
    return d;
  }

  Future<void> _save() async {
    final s = _store;
    if (s == null || _stateFile == null) return;
    await _stateFile!.writeAsString(jsonEncode({...s.toJson(), 'deviceId': _myDevice, 'nextPreKeyId': _nextPreKeyId}));
  }

  /// After sign-in. Never throws: if anything fails, the app keeps using the
  /// older encryption until next time.
  Future<void> init(ApiClient api, String userId) => initWith(_ClientApi(api), userId);

  Future<void> initWith(SignalApi api, String userId) {
    _ready = _init(api, userId);
    return _ready!;
  }

  Future<void> _init(SignalApi api, String userId) async {
    _api = api;
    _userId = userId;
    _myDevice = null;
    try {
      final dir = await _dir(userId);
      _stateFile = File('${dir.path}/state.json');
      _keptFile = File('${dir.path}/kept.json');
      if (await _keptFile!.exists()) _kept = jsonDecode(await _keptFile!.readAsString()) as Map<String, dynamic>;
      int? local;
      if (await _stateFile!.exists()) {
        final j = jsonDecode(await _stateFile!.readAsString()) as Map<String, dynamic>;
        _store = _Store.fromJson(j, _save);
        local = j['deviceId'] as int?;
        _nextPreKeyId = j['nextPreKeyId'] as int? ?? 1;
      }
      final server = await api.getJson('/api/signal/me');
      if (_store == null || local == null || server['deviceId'] != local) {
        await _registerFresh();
      } else {
        _myDevice = local;
        if ((server['preKeys'] as num? ?? 0) < _preKeyLow) {
          await api.postJson('/api/signal/prekeys', {'preKeys': await _makePreKeys(_preKeyBatch)});
        }
      }
    } catch (_) {
      _myDevice = null;
    }
  }

  Future<List<Map<String, dynamic>>> _makePreKeys(int count) async {
    final out = <Map<String, dynamic>>[];
    for (final pk in generatePreKeys(_nextPreKeyId, count)) {
      await _store!.preKeys.storePreKey(pk.id, pk);
      out.add({'keyId': pk.id, 'publicKey': base64Encode(pk.getKeyPair().publicKey.serialize())});
    }
    _nextPreKeyId += count;
    await _save();
    return out;
  }

  Future<void> _registerFresh() async {
    final identity = generateIdentityKeyPair();
    final regId = generateRegistrationId(false);
    _store = _Store(identity, regId, _save);
    _nextPreKeyId = 1;
    final signed = generateSignedPreKey(identity, 1);
    await _store!.signed.storeSignedPreKey(signed.id, signed);
    final preKeys = await _makePreKeys(_preKeyFirst);
    final res = await _api!.postJson('/api/signal/devices', {
      'registrationId': regId,
      'identityKey': base64Encode(identity.getPublicKey().serialize()),
      'signedPreKey': {
        'keyId': signed.id,
        'publicKey': base64Encode(signed.getKeyPair().publicKey.serialize()),
        'signature': base64Encode(signed.signature),
      },
      'preKeys': preKeys,
    });
    _myDevice = (res['deviceId'] as num).toInt();
    await _save();
    // The rest of the one-time keys follow in the background.
    () async {
      try {
        await _api!.postJson('/api/signal/prekeys', {'preKeys': await _makePreKeys(_preKeyBatch - _preKeyFirst)});
      } catch (_) {/* topped up next time instead */}
    }();
  }

  /// Sign-out: this phone's Signal keys and opened messages go with it.
  Future<void> wipe(String userId) async {
    _store = null;
    _myDevice = null;
    _kept = {};
    _deviceCache.clear();
    try {
      final d = Directory('${(await getApplicationSupportDirectory()).path}/signal/$userId');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  // ── Devices of a person ──
  Future<List<int>> _devicesOf(String userId) async {
    final hit = _deviceCache[userId];
    if (hit != null && DateTime.now().difference(hit.at) < _deviceCacheTtl) return hit.devices;
    final res = await _api!.getJson('/api/signal/devices/$userId');
    final devices = ((res['devices'] as List?) ?? const []).map((d) => (d as num).toInt()).toList();
    _deviceCache[userId] = (at: DateTime.now(), devices: devices);
    return devices;
  }

  void forgetDevices(String userId) => _deviceCache.remove(userId);

  /// The server said the device list was out of date: take its list, and
  /// drop sessions with devices that are gone.
  Future<void> applyDeviceList(Map<String, dynamic> map) async {
    for (final e in map.entries) {
      final devices = (e.value as List).map((d) => (d as num).toInt()).toList();
      _deviceCache[e.key] = (at: DateTime.now(), devices: devices);
      for (final dev in await _store!.getSubDeviceSessions(e.key)) {
        if (!devices.contains(dev)) await _store!.deleteSession(SignalProtocolAddress(e.key, dev));
      }
    }
  }

  /// 1-to-1 chats, once this phone is set up and the other person has at
  /// least one Signal device.
  Future<bool> useFor({required bool isGroup, required String? peerId}) async {
    if (!ready || isGroup || peerId == null) return false;
    try {
      return (await _devicesOf(peerId)).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ── Sealing ──
  Future<void> _ensureSessions(String userId, List<int> devices) async {
    final missing = <int>[];
    for (final d in devices) {
      if (!await _store!.containsSession(SignalProtocolAddress(userId, d))) missing.add(d);
    }
    if (missing.isEmpty) return;
    final res = await _api!.getJson('/api/signal/bundles/$userId');
    for (final raw in (res['devices'] as List)) {
      final b = raw as Map<String, dynamic>;
      final dev = (b['deviceId'] as num).toInt();
      if (!missing.contains(dev)) continue;
      final spk = b['signedPreKey'] as Map<String, dynamic>;
      final pk = b['preKey'] as Map<String, dynamic>?;
      final bundle = PreKeyBundle(
        (b['registrationId'] as num).toInt(),
        dev,
        pk == null ? null : (pk['keyId'] as num).toInt(),
        pk == null ? null : Curve.decodePoint(base64Decode(pk['publicKey'] as String), 0),
        (spk['keyId'] as num).toInt(),
        Curve.decodePoint(base64Decode(spk['publicKey'] as String), 0),
        base64Decode(spk['signature'] as String),
        IdentityKey.fromBytes(base64Decode(b['identityKey'] as String), 0),
      );
      await SessionBuilder.fromSignalStore(_store!, SignalProtocolAddress(userId, dev)).processPreKeyBundle(bundle);
    }
  }

  /// Seals [text] for every device of everyone in [memberIds] (my own other
  /// devices too). Returns the envelopes for the 'send' frame.
  Future<List<Map<String, dynamic>>> seal(List<String> memberIds, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final out = <Map<String, dynamic>>[];
    for (final userId in memberIds) {
      final devices = (await _devicesOf(userId)).where((d) => !(userId == _userId && d == _myDevice)).toList();
      if (devices.isEmpty) continue;
      await _ensureSessions(userId, devices);
      for (final dev in devices) {
        final m = await SessionCipher.fromStore(_store!, SignalProtocolAddress(userId, dev)).encrypt(bytes);
        out.add({
          'userId': userId,
          'deviceId': dev,
          // On the wire: 3 = first message of a session, 1 = normal (the
          // website's library numbers a normal one 1; this library says 2).
          'type': m.getType() == CiphertextMessage.prekeyType ? 3 : 1,
          'body': base64Encode(m.serialize()),
        });
      }
    }
    return out;
  }

  // ── Opening ──
  /// Plain text of a Signal message: kept from before, else this device's
  /// envelope opened (once). Null when this device has nothing to read
  /// (sent before it was set up).
  Future<String?> open({
    required String id,
    required String senderId,
    required String iv,
    String? editedAt,
    Map<String, dynamic>? envelope,
  }) {
    // The chat screen and a notification may both ask at once; a ratchet
    // message can only be opened once, so they share the same attempt.
    final key = '$id@$editedAt';
    // (A block body on purpose: `=> _opening.remove(key)` would hand back
    // this very future, and whenComplete would wait on it forever.)
    return _opening[key] ??= _open(id, senderId, iv, editedAt, envelope).whenComplete(() {
      _opening.remove(key);
    });
  }

  Future<String?> _open(String id, String senderId, String iv, String? editedAt, Map<String, dynamic>? envelope) async {
    await _ready;
    final kept = _kept[id] as Map<String, dynamic>?;
    if (kept != null && kept['editedAt'] == editedAt) return kept['text'] as String?;
    if (envelope == null || _store == null) return kept?['text'] as String?;
    final senderDevice = int.tryParse(iv.split(':').last) ?? 1;
    final cipher = SessionCipher.fromStore(_store!, SignalProtocolAddress(senderId, senderDevice));
    final body = base64Decode(envelope['body'] as String);
    final plain = (envelope['type'] as num).toInt() == 3
        ? await cipher.decrypt(PreKeySignalMessage(body))
        : await cipher.decryptFromSignal(SignalMessage.fromSerialized(body));
    final text = utf8.decode(plain);
    await keep(id, text, editedAt: editedAt);
    return text;
  }

  // ── Chat backup (core/chat_backup.dart) ──
  /// Every message this phone has kept: [{id, text, editedAt}].
  Future<List<Map<String, dynamic>>> exportKept() async {
    await _ready;
    return [
      for (final e in _kept.entries)
        if ((e.value as Map?)?['text'] is String)
          {'id': e.key, 'text': (e.value as Map)['text'], 'editedAt': (e.value as Map)['editedAt']},
    ];
  }

  /// Put restored messages back. What this phone already has wins.
  Future<int> importKept(List<dynamic> list) async {
    await _ready;
    var added = 0;
    for (final k in list) {
      if (k is! Map || k['id'] == null || k['text'] is! String) continue;
      final id = k['id'].toString();
      if (_kept.containsKey(id)) continue;
      _kept[id] = {'text': k['text'], 'editedAt': k['editedAt']};
      added++;
    }
    if (added > 0) {
      try {
        await _keptFile?.writeAsString(jsonEncode(_kept));
      } catch (_) {}
    }
    return added;
  }

  /// Remember the plain text of a message (opened here, or written here).
  Future<void> keep(String id, String text, {String? editedAt}) async {
    _kept[id] = {'text': text, 'editedAt': editedAt};
    try {
      await _keptFile?.writeAsString(jsonEncode(_kept));
    } catch (_) {}
  }
}
