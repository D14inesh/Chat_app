/// Identity keypair generation/import/export — mirrors crypto.js's
/// generateIdentity/exportPublicKey/importPublicKey exactly (ECDH P-256).
library identity;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'jwk.dart';
import 'p256.dart';

/// Generates a new long-term ECDH P-256 identity keypair. Done in p256.dart
/// rather than with `Ecdh.p256().newKeyPair()`, which throws
/// UnimplementedError on Android (no pure-Dart P-256 in package:cryptography).
Future<EcKeyPair> generateIdentity() async => generateP256KeyPair();

Future<EcPublicJwk> exportPublicKey(EcKeyPair keyPair) async {
  final pub = await keyPair.extractPublicKey();
  return EcPublicJwk.fromCoordinates(
    Uint8List.fromList(pub.x),
    Uint8List.fromList(pub.y),
  );
}

Future<EcPrivateJwk> exportPrivateKeyJwk(EcKeyPair keyPair) async {
  final data = await keyPair.extract();
  return EcPrivateJwk.fromCoordinates(
    Uint8List.fromList(data.x),
    Uint8List.fromList(data.y),
    Uint8List.fromList(data.d),
  );
}

/// Imports a peer's public JWK as a usable ECDH public key — the Dart
/// equivalent of crypto.js's importPublicKey.
EcPublicKey importPublicKey(EcPublicJwk jwk) {
  return EcPublicKey(
    type: KeyPairType.p256,
    x: jwk.xBytes,
    y: jwk.yBytes,
  );
}

/// Re-imports a private key from its JWK form (after decrypting a
/// password-wrap or device-link seal) as a usable key pair.
EcKeyPair importPrivateKeyJwk(EcPrivateJwk jwk) {
  return EcKeyPairData(
    type: KeyPairType.p256,
    x: jwk.xBytes,
    y: jwk.yBytes,
    d: jwk.dBytes,
  );
}
