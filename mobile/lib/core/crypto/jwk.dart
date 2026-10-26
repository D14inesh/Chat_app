/// RFC 7518 JWK (JSON Web Key) helpers for EC P-256 keys, plus base64/base64url
/// codecs matching exactly what public/js/crypto.js produces and expects.
///
/// Two DIFFERENT base64 variants are used across the protocol, and mixing
/// them up is the easiest way to silently break interop with the web client:
///   - Ciphertext / IV / PBKDF2 salt / wrapped-key blobs: STANDARD base64,
///     WITH '=' padding (what JS's btoa/atob produce) — see b64.dart.
///   - JWK's own `x` / `y` / `d` fields: base64URL, WITHOUT padding, per
///     RFC 7518 §6.2.1 (this is what the browser's crypto.subtle.exportKey
///     ('jwk', ...) emits, and JOSE/JWK tooling in general expects).
library jwk;

import 'dart:convert';
import 'dart:typed_data';

/// Base64url-encodes without padding, matching JWK's x/y/d field format.
String base64UrlNoPad(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Decodes a base64url string that may be missing its padding (as JWK
/// fields always are) — Dart's base64Url.decode requires correct padding,
/// so this restores it before decoding.
Uint8List base64UrlDecodeNoPad(String input) {
  // Dart's base64Url codec already expects the '-'/'_' url-safe alphabet —
  // only the omitted '=' padding needs restoring before it will decode.
  final padded = input.padRight(
    input.length + ((4 - input.length % 4) % 4),
    '=',
  );
  return base64Url.decode(padded);
}

/// A P-256 EC public key in the exact JSON shape crypto.js's
/// `exportPublicKey`/`importPublicKey` produce/consume.
class EcPublicJwk {
  final String x; // base64url, no padding, 32 bytes
  final String y; // base64url, no padding, 32 bytes

  const EcPublicJwk({required this.x, required this.y});

  factory EcPublicJwk.fromCoordinates(Uint8List x, Uint8List y) {
    return EcPublicJwk(x: base64UrlNoPad(x), y: base64UrlNoPad(y));
  }

  Uint8List get xBytes => base64UrlDecodeNoPad(x);
  Uint8List get yBytes => base64UrlDecodeNoPad(y);

  /// Matches the field set/order crypto.subtle.exportKey('jwk', pubKey)
  /// would produce for an extractable ECDH P-256 public key. Field order in
  /// the map doesn't matter for JSON.parse/interop, only the field names
  /// and values do.
  Map<String, dynamic> toJson() => {
        'kty': 'EC',
        'crv': 'P-256',
        'x': x,
        'y': y,
        'ext': true,
        'key_ops': const <String>[],
      };

  factory EcPublicJwk.fromJson(Map<String, dynamic> json) {
    if (json['kty'] != 'EC' || json['crv'] != 'P-256') {
      throw const FormatException('Not a P-256 EC JWK');
    }
    return EcPublicJwk(x: json['x'] as String, y: json['y'] as String);
  }

  /// Same cache-key shape crypto.js uses (`peerPublicJwk.x + '|' + peerPublicJwk.y`)
  /// — keeping it identical matters only for our own in-memory cache, not
  /// for interop, but there's no reason to diverge.
  String get cacheKey => '$x|$y';
}

/// A P-256 EC private key in JWK shape — only ever produced transiently
/// (to be immediately JSON-encoded and AES-GCM encrypted for storage,
/// exactly like crypto.js's wrapPrivateKey does with `JSON.stringify(jwk)`)
/// or parsed back out of a decrypted wrap.
class EcPrivateJwk {
  final String x;
  final String y;
  final String d; // base64url, no padding, 32 bytes — the private scalar

  const EcPrivateJwk({required this.x, required this.y, required this.d});

  factory EcPrivateJwk.fromCoordinates(Uint8List x, Uint8List y, Uint8List d) {
    return EcPrivateJwk(
      x: base64UrlNoPad(x),
      y: base64UrlNoPad(y),
      d: base64UrlNoPad(d),
    );
  }

  Uint8List get xBytes => base64UrlDecodeNoPad(x);
  Uint8List get yBytes => base64UrlDecodeNoPad(y);
  Uint8List get dBytes => base64UrlDecodeNoPad(d);

  EcPublicJwk get publicJwk => EcPublicJwk(x: x, y: y);

  Map<String, dynamic> toJson() => {
        'kty': 'EC',
        'crv': 'P-256',
        'x': x,
        'y': y,
        'd': d,
        'ext': true,
        'key_ops': const ['deriveKey', 'deriveBits'],
      };

  factory EcPrivateJwk.fromJson(Map<String, dynamic> json) {
    if (json['kty'] != 'EC' || json['crv'] != 'P-256') {
      throw const FormatException('Not a P-256 EC JWK');
    }
    return EcPrivateJwk(
      x: json['x'] as String,
      y: json['y'] as String,
      d: json['d'] as String,
    );
  }
}
