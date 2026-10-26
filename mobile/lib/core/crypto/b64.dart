/// Standard base64 (WITH padding) — matches crypto.js's bufToB64/b64ToBuf,
/// which use the browser's btoa/atob. Used for ciphertext, IVs, PBKDF2
/// salts, and wrapped-key blobs — everything EXCEPT the JWK x/y/d fields
/// (those are base64url, no padding — see jwk.dart).
library b64;

import 'dart:convert';
import 'dart:typed_data';

String bufToB64(List<int> bytes) => base64Encode(bytes);

Uint8List b64ToBuf(String b64) => base64Decode(b64);
