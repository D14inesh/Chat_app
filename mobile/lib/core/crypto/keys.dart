/// Key derivation, wrapping, and message/content encryption â€” a 1:1 port of
/// public/js/crypto.js's functions. Every parameter (algorithm, empty HKDF
/// salt, info strings, PBKDF2 iteration count, IV length) is matched exactly
/// so mobile-created keys/messages interoperate with the existing web app on
/// the same shared database. See the crypto section of the project plan for
/// the full parameter table this was verified against.
library keys;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'b64.dart';
import 'identity.dart';
import 'jwk.dart';
import 'p256.dart';

const _hkdfInfoDeviceLink = 'vesper-chat/v1/device-link';
const _hkdfInfoMessageKey = 'vesper-chat/v1/message-key';
const _hkdfInfoKeyWrap = 'vesper-chat/v1/key-wrap';
const _pbkdf2Iterations = 250000;

final AesGcm _aesGcm256 = AesGcm.with256bits();
final Hmac _hmacSha256 = Hmac.sha256();

/// {ciphertext, iv} â€” both standard base64, matching crypto.js's
/// encryptText/decryptText wire shape exactly.
class CipherEnvelope {
  final String ciphertext;
  final String iv;
  const CipherEnvelope({required this.ciphertext, required this.iv});
}

/// {wrappedKey, wrappedIv} â€” the per-recipient content-key envelope shape
/// (also reused, structurally, by device-link sealing).
class WrappedKey {
  final String wrappedKey;
  final String wrappedIv;
  const WrappedKey({required this.wrappedKey, required this.wrappedIv});
}

// â”€â”€ AES-GCM encrypt/decrypt helpers (WebCrypto-compatible framing) â”€â”€â”€â”€â”€
//
// WebCrypto's crypto.subtle.encrypt() returns ciphertext with the 16-byte
// GCM tag appended at the end, as one buffer. package:cryptography instead
// returns a SecretBox with cipherText/mac separated â€” these helpers convert
// between the two so the base64 actually on the wire matches crypto.js's.

Future<CipherEnvelope> _aesGcmEncryptBytes(SecretKey key, List<int> plaintext) async {
  final iv = _aesGcm256.newNonce(); // 12 random bytes, same as crypto.getRandomValues(new Uint8Array(12))
  final box = await _aesGcm256.encrypt(plaintext, secretKey: key, nonce: iv);
  final combined = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(box.cipherText.length, box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
  return CipherEnvelope(ciphertext: bufToB64(combined), iv: bufToB64(iv));
}

Future<Uint8List> _aesGcmDecryptBytes(SecretKey key, String ciphertextB64, String ivB64) async {
  final combined = b64ToBuf(ciphertextB64);
  final iv = b64ToBuf(ivB64);
  const tagLen = 16; // AES-GCM's standard 128-bit tag, same as WebCrypto's default
  if (combined.length < tagLen) {
    throw const FormatException('Ciphertext shorter than the GCM tag â€” corrupt data.');
  }
  final cipherText = combined.sublist(0, combined.length - tagLen);
  final mac = Mac(combined.sublist(combined.length - tagLen));
  final box = SecretBox(cipherText, nonce: iv, mac: mac);
  final clear = await _aesGcm256.decrypt(box, secretKey: key);
  return Uint8List.fromList(clear);
}

/// For the Signal protocol: a photo/video/voice note is locked with its own
/// brand-new random key, and that key (with name/type) goes into the message,
/// which Signal seals per device — same as crypto.js's sealFileForSignal.
Future<({Uint8List blob, Map<String, dynamic> meta})> sealFileForSignal(
  Uint8List bytes, {
  required String name,
  required String mime,
  Map<String, dynamic> extra = const {},
}) async {
  final fileKey = await _aesGcm256.newSecretKey();
  final iv = _aesGcm256.newNonce();
  final box = await _aesGcm256.encrypt(bytes, secretKey: fileKey, nonce: iv);
  final blob = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(box.cipherText.length, box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
  final raw = await fileKey.extractBytes();
  return (
    blob: blob,
    meta: <String, dynamic>{
      'name': name,
      'mime': mime,
      'size': bytes.length,
      'blobIv': 'k:${bufToB64(raw)}:${bufToB64(iv)}',
      ...extra,
    },
  );
}

// â”€â”€ ECDH -> HKDF-SHA256 (empty salt) -> AES-GCM-256 â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

Future<SecretKey> _ecdhThenHkdf(
  EcKeyPair myPrivateKey,
  EcPublicJwk peerPublicJwk,
  String infoLabel,
) async {
  final sharedSecret = await p256SharedSecret(myPrivateKey, peerPublicJwk.xBytes, peerPublicJwk.yBytes);
  final hkdf = Hkdf(hmac: _hmacSha256, outputLength: 32);
  return hkdf.deriveKey(
    secretKey: sharedSecret,
    nonce: const <int>[], // HKDF salt â€” MUST be empty, matching crypto.js exactly
    info: utf8.encode(infoLabel),
  );
}

final Map<String, SecretKey> _sharedKeyCache = {};
final Map<String, SecretKey> _wrapKeyCache = {};

/// The deterministic static-static ECDH 1:1 conversation key. Same inputs
/// always produce the same key â€” no handshake needed, both sides derive it
/// independently. Cached in-memory the same way crypto.js does.
Future<SecretKey> deriveSharedKey(EcKeyPair myPrivateKey, EcPublicJwk peerPublicJwk) async {
  final cacheKey = peerPublicJwk.cacheKey;
  final cached = _sharedKeyCache[cacheKey];
  if (cached != null) return cached;
  final key = await _ecdhThenHkdf(myPrivateKey, peerPublicJwk, _hkdfInfoMessageKey);
  _sharedKeyCache[cacheKey] = key;
  return key;
}

void clearKeyCache() => _sharedKeyCache.clear();

/// The key used only to wrap/unwrap a group or status content-key envelope
/// for one specific recipient â€” deliberately a different derived key from
/// deriveSharedKey even though it's computed from the same ECDH bits
/// (domain separation via a different HKDF info string).
Future<SecretKey> deriveWrapKey(EcKeyPair myPrivateKey, EcPublicJwk peerPublicJwk) async {
  final cacheKey = peerPublicJwk.cacheKey;
  final cached = _wrapKeyCache[cacheKey];
  if (cached != null) return cached;
  final key = await _ecdhThenHkdf(myPrivateKey, peerPublicJwk, _hkdfInfoKeyWrap);
  _wrapKeyCache[cacheKey] = key;
  return key;
}

/// Device-link key (phase 2 feature â€” QR sign-in â€” not wired into any MVP
/// screen yet, but the primitive is identical shape to the two above so it
/// costs nothing to have ready).
Future<SecretKey> deriveLinkKey(EcKeyPair myPrivateKey, EcPublicJwk peerPublicJwk) {
  return _ecdhThenHkdf(myPrivateKey, peerPublicJwk, _hkdfInfoDeviceLink);
}

// â”€â”€ Password-wrapped private key â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class WrappedPrivateKey {
  final int v;
  final String salt;
  final String iv;
  final String data;
  const WrappedPrivateKey({required this.v, required this.salt, required this.iv, required this.data});

  Map<String, dynamic> toJson() => {'v': v, 'salt': salt, 'iv': iv, 'data': data};
  factory WrappedPrivateKey.fromJson(Map<String, dynamic> json) => WrappedPrivateKey(
        v: json['v'] as int,
        salt: json['salt'] as String,
        iv: json['iv'] as String,
        data: json['data'] as String,
      );
}

Future<SecretKey> _deriveWrappingKey(String password, List<int> salt) async {
  final pbkdf2 = Pbkdf2(macAlgorithm: _hmacSha256, iterations: _pbkdf2Iterations, bits: 256);
  return pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
}

/// Encrypts the identity private key under a password-derived key for
/// server storage â€” exactly crypto.js's wrapPrivateKey. This is what gets
/// sent as `encPrivateKey` on register.
Future<WrappedPrivateKey> wrapPrivateKey(EcKeyPair keyPair, String password) async {
  final salt = _randomBytes(16);
  final wrapKey = await _deriveWrappingKey(password, salt);
  final jwk = await exportPrivateKeyJwk(keyPair);
  final plaintext = utf8.encode(jsonEncode(jwk.toJson()));
  final envelope = await _aesGcmEncryptBytes(wrapKey, plaintext);
  return WrappedPrivateKey(v: 1, salt: bufToB64(salt), iv: envelope.iv, data: envelope.ciphertext);
}

/// Decrypts a password-wrapped private key back into a usable key pair.
/// Throws with a user-facing message on a wrong password (GCM tag mismatch),
/// matching crypto.js's unwrapPrivateKey behavior.
Future<EcKeyPair> unwrapPrivateKey(WrappedPrivateKey wrapped, String password) async {
  final salt = b64ToBuf(wrapped.salt);
  final wrapKey = await _deriveWrappingKey(password, salt);
  late Uint8List plaintext;
  try {
    plaintext = await _aesGcmDecryptBytes(wrapKey, wrapped.data, wrapped.iv);
  } catch (_) {
    throw StateError('Could not unlock your encryption key â€” wrong password?');
  }
  final jwk = EcPrivateJwk.fromJson(jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>);
  return importPrivateKeyJwk(jwk);
}

// â”€â”€ Group / status content-key envelopes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// A random, per-group/per-status AES-256 content key. Extractable (unlike
/// the derived shared/wrap keys) because it must be re-wrapped whenever a
/// new member/viewer is added later.
Future<(SecretKey key, Uint8List raw)> generateContentKey() async {
  final raw = _randomBytes(32);
  return (SecretKey(raw), raw);
}

SecretKey importContentKey(Uint8List raw) => SecretKey(raw);

Future<WrappedKey> wrapContentKey(SecretKey wrapKey, Uint8List rawContentKeyBytes) async {
  final envelope = await _aesGcmEncryptBytes(wrapKey, rawContentKeyBytes);
  return WrappedKey(wrappedKey: envelope.ciphertext, wrappedIv: envelope.iv);
}

Future<SecretKey> unwrapContentKey(SecretKey wrapKey, String wrappedKey, String wrappedIv) async {
  final raw = await _aesGcmDecryptBytes(wrapKey, wrappedKey, wrappedIv);
  return importContentKey(raw);
}

// â”€â”€ Message text encryption â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

Future<CipherEnvelope> encryptText(SecretKey key, String text) {
  return _aesGcmEncryptBytes(key, utf8.encode(text));
}

Future<String> decryptText(SecretKey key, String ciphertext, String iv) async {
  final bytes = await _aesGcmDecryptBytes(key, ciphertext, iv);
  return utf8.decode(bytes);
}

// -- File/attachment encryption (mirrors crypto.js's encryptFile) --------

class FileEnvelope {
  /// Raw ciphertext+tag bytes for the file body -- uploaded to /api/upload
  /// exactly as-is (never base64-encoded; that endpoint stores opaque bytes).
  final Uint8List blob;
  final String metaCiphertext; // b64 -- goes in the message's `ciphertext` field
  final String metaIv; // b64 -- goes in the message's `iv` field
  const FileEnvelope({required this.blob, required this.metaCiphertext, required this.metaIv});
}

/// Encrypts a file's bytes under a fresh random IV, then seals the filename/
/// mime/size/that-IV together as the message's encrypted metadata -- the
/// server never learns the filename, mime type, or even the file body's own
/// nonce. Exactly crypto.js's encryptFile.
Future<FileEnvelope> encryptFile(
  SecretKey key,
  Uint8List bytes, {
  required String name,
  required String mime,
  Map<String, dynamic> extra = const {},
}) async {
  final iv = _aesGcm256.newNonce();
  final box = await _aesGcm256.encrypt(bytes, secretKey: key, nonce: iv);
  final blob = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(box.cipherText.length, box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
  final meta = await encryptText(key, jsonEncode({
    'name': name,
    'mime': mime,
    'size': bytes.length,
    'blobIv': bufToB64(iv),
    ...extra,
  }));
  return FileEnvelope(blob: blob, metaCiphertext: meta.ciphertext, metaIv: meta.iv);
}

Future<Map<String, dynamic>> decryptFileMeta(SecretKey key, String ciphertext, String iv) async {
  final text = await decryptText(key, ciphertext, iv);
  return jsonDecode(text) as Map<String, dynamic>;
}

/// Decrypts a downloaded file blob using the blobIv carried inside its
/// already-decrypted metadata (see decryptFileMeta) -- the file body's own
/// nonce never travels anywhere except sealed inside that metadata.
Future<Uint8List> decryptFileBytes(SecretKey? key, Uint8List blob, String blobIvB64) async {
  // A file sent over Signal carries its own one-time key: "k:<key>:<iv>"
  // (inside the sealed message — the server never sees it). Older files use
  // the chat's key.
  var fileKey = key;
  var ivText = blobIvB64;
  if (blobIvB64.startsWith('k:')) {
    final parts = blobIvB64.split(':');
    fileKey = SecretKey(b64ToBuf(parts[1]));
    ivText = parts[2];
  }
  if (fileKey == null) throw StateError('No key for this file.');
  final iv = b64ToBuf(ivText);
  const tagLen = 16;
  if (blob.length < tagLen) {
    throw const FormatException('File blob shorter than the GCM tag -- corrupt data.');
  }
  final cipherText = blob.sublist(0, blob.length - tagLen);
  final mac = Mac(blob.sublist(blob.length - tagLen));
  final box = SecretBox(cipherText, nonce: iv, mac: mac);
  final clear = await _aesGcm256.decrypt(box, secretKey: fileKey);
  return Uint8List.fromList(clear);
}

// -- Device-link identity sealing (phase 2 primitive, ready but unused) --

Future<WrappedKey> sealIdentityForLink(EcKeyPair myPrivateKey, EcPublicJwk ephemeralPublicJwk) async {
  final linkKey = await deriveLinkKey(myPrivateKey, ephemeralPublicJwk);
  final jwk = await exportPrivateKeyJwk(myPrivateKey);
  final envelope = await _aesGcmEncryptBytes(linkKey, utf8.encode(jsonEncode(jwk.toJson())));
  return WrappedKey(wrappedKey: envelope.ciphertext, wrappedIv: envelope.iv);
}

Future<EcKeyPair> openIdentityFromLink(
  EcKeyPair ephemeralPrivateKey,
  EcPublicJwk accountPublicJwk,
  String wrappedKey,
  String wrappedIv,
) async {
  final linkKey = await deriveLinkKey(ephemeralPrivateKey, accountPublicJwk);
  final plaintext = await _aesGcmDecryptBytes(linkKey, wrappedKey, wrappedIv);
  final jwk = EcPrivateJwk.fromJson(jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>);
  return importPrivateKeyJwk(jwk);
}

// â”€â”€ Safety number (out-of-band verification fingerprint) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

Future<String> safetyNumber(EcPublicJwk myPublicJwk, EcPublicJwk peerPublicJwk) async {
  final a = '${myPublicJwk.x}${myPublicJwk.y}';
  final b = '${peerPublicJwk.x}${peerPublicJwk.y}';
  final pair = ([a, b]..sort()).join();
  final digest = await Sha256().hash(utf8.encode(pair));
  final first15 = digest.bytes.sublist(0, 15);
  final digits = first15.map((b) => b.toString().padLeft(3, '0')).join();
  final groups = <String>[];
  for (var i = 0; i < digits.length; i += 5) {
    groups.add(digits.substring(i, (i + 5).clamp(0, digits.length)));
  }
  return groups.join(' ');
}

// crypto.getRandomValues() equivalent â€” dart:math's Random.secure() is
// backed by the platform CSPRNG (getrandom/arc4random/CryptGenRandom
// depending on OS), which is the correct and only appropriate source for
// salts and content keys. Do not replace this with the plain (non-secure)
// Random() â€” that one is NOT safe for cryptographic use.
final Random _secureRandom = Random.secure();

Uint8List _randomBytes(int length) {
  return Uint8List.fromList(List<int>.generate(length, (_) => _secureRandom.nextInt(256)));
}
