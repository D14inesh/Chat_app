/// ECDH P-256 key generation and key agreement in pure Dart.
///
/// package:cryptography's `Ecdh.p256()` has no pure-Dart implementation — on
/// Android it throws `UnimplementedError`, which is what broke every chat
/// ("Could not load this conversation: UnimplementedError"). The curve math
/// is done here with pointycastle instead; keys keep using package:
/// cryptography's `EcKeyPairData` type so nothing else had to change.
///
/// The shared secret is the raw 32-byte X coordinate of d·Q — exactly what
/// WebCrypto's ECDH deriveBits/deriveKey produces in crypto.js — so keys
/// derived here match the web app's byte for byte.
library p256;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

final ECDomainParameters _domain = ECCurve_secp256r1();

// Curve constants, for validating a peer's public key before using it.
final BigInt _p = BigInt.parse('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff', radix: 16);
final BigInt _a = _p - BigInt.from(3);
final BigInt _b = BigInt.parse('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', radix: 16);

final Random _secureRandom = Random.secure();

BigInt _toBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

Uint8List _to32Bytes(BigInt value) {
  final out = Uint8List(32);
  var v = value;
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

bool _isOnCurve(BigInt x, BigInt y) {
  if (x < BigInt.zero || x >= _p || y < BigInt.zero || y >= _p) return false;
  final lhs = (y * y) % _p;
  final rhs = (x * x * x + _a * x + _b) % _p;
  return lhs == rhs;
}

/// A new random P-256 key pair (private scalar d in [1, n-1]).
EcKeyPairData generateP256KeyPair() {
  BigInt d;
  do {
    d = _toBigInt(List<int>.generate(32, (_) => _secureRandom.nextInt(256)));
  } while (d == BigInt.zero || d >= _domain.n);
  final q = (_domain.G * d)!;
  return EcKeyPairData(
    type: KeyPairType.p256,
    d: _to32Bytes(d),
    x: _to32Bytes(q.x!.toBigInteger()!),
    y: _to32Bytes(q.y!.toBigInteger()!),
  );
}

/// ECDH: the X coordinate of (my private scalar) × (peer public point).
Future<SecretKey> p256SharedSecret(EcKeyPair myKeyPair, List<int> peerX, List<int> peerY) async {
  final mine = await myKeyPair.extract();
  final x = _toBigInt(peerX);
  final y = _toBigInt(peerY);
  // Reject anything not on the curve — an off-curve point can leak bits of
  // the private key (invalid-curve attack). WebCrypto does the same check.
  if (!_isOnCurve(x, y)) {
    throw const FormatException('Peer public key is not a valid P-256 point.');
  }
  final shared = (_domain.curve.createPoint(x, y) * _toBigInt(mine.d))!;
  if (shared.isInfinity) {
    throw const FormatException('ECDH produced the point at infinity.');
  }
  return SecretKey(_to32Bytes(shared.x!.toBigInteger()!));
}
