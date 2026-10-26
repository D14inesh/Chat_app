/// Resolves the AES-GCM content key for a conversation -- static-static ECDH
/// for a direct chat, unwrap-the-shared-key for a group. Extracted out of
/// ChatController so anything that needs to decrypt a message *outside* an
/// open chat screen (e.g. the starred-messages list, which spans many
/// conversations at once) can reuse the exact same resolution logic.
library key_resolver;

import 'package:cryptography/cryptography.dart';

import '../features/auth/session.dart';
import '../models/conversation.dart';
import 'api_client.dart';
import 'crypto/jwk.dart';
import 'crypto/keys.dart';
import 'local_cache.dart';

Future<SecretKey> resolveConversationKey(Session session, Conversation conversation) async {
  final myKeyPair = session.identityKeyPair!;
  if (!conversation.isGroup) {
    // Needs only the peer's public key, which the cached chat list carries —
    // works offline as-is.
    final peerJwk = EcPublicJwk.fromJson(conversation.peer!.publicKey!);
    return deriveSharedKey(myKeyPair, peerJwk);
  }

  final cache = LocalCache();
  Map<String, dynamic>? wrapped;
  try {
    final keyJson = await session.api.getGroupKey(conversation.id);
    final wrappedByUserId = keyJson['wrappedBy'] as String?;
    if (wrappedByUserId == null) {
      throw StateError('No key available for this group.');
    }
    final wrappedByUser = await session.api.getUser(wrappedByUserId);
    wrapped = {
      'wrappedKey': keyJson['wrappedKey'],
      'wrappedIv': keyJson['wrappedIv'],
      'wrapperPublicKey': wrappedByUser['publicKey'],
    };
    await cache.saveGroupKey(conversation.id, wrapped);
  } on ApiException {
    rethrow; // the server answered "no" — a cached key wouldn't be right
  } on StateError {
    rethrow;
  } catch (_) {
    // Offline — use the copy saved the last time this group was opened.
    wrapped = await cache.loadGroupKey(conversation.id);
    if (wrapped == null) rethrow;
  }

  final wrapperPublicKey = wrapped['wrapperPublicKey'] as Map<String, dynamic>?;
  if (wrapperPublicKey == null) {
    throw StateError("Could not resolve this group's encryption key.");
  }
  final wrapKey = await deriveWrapKey(myKeyPair, EcPublicJwk.fromJson(wrapperPublicKey));
  return unwrapContentKey(wrapKey, wrapped['wrappedKey'] as String, wrapped['wrappedIv'] as String);
}
