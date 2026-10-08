/**
 * End-to-end encryption, built entirely on the browser's Web Crypto API.
 *
 * How it fits together
 * ────────────────────
 * On registration each user generates an ECDH P-256 keypair.
 *   · The PUBLIC key is uploaded in the clear — every peer needs it.
 *   · The PRIVATE key is wrapped with AES-GCM under a key derived from the
 *     user's password (PBKDF2, 250k iterations) and only then uploaded. The
 *     server stores an opaque blob it has no way to open: it only ever receives
 *     a bcrypt hash of the password, never the password itself.
 *
 * To talk to someone, both sides run ECDH against the other's public key. That
 * produces an identical shared secret on each end without it ever crossing the
 * wire; HKDF turns it into an AES-GCM key. The server stores ciphertext + IV and
 * routes it, and that is genuinely all it can do.
 *
 * Honest limitation
 * ─────────────────
 * This is static-static ECDH: the pair's key is stable for the life of their
 * keypairs. It does NOT give per-message forward secrecy — someone who both
 * recorded your traffic AND later stole a private key could read the history.
 * The Signal Double Ratchet solves that by rotating keys every message. See the
 * README for what upgrading to libsignal would involve.
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

const PBKDF2_ITERATIONS = 250_000;

// ── base64 helpers ──────────────────────────────────────────
export function bufToB64(buf) {
  const bytes = new Uint8Array(buf);
  let binary = '';
  // Chunked — String.fromCharCode(...hugeArray) blows the call stack on big files.
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

export function b64ToBuf(b64) {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

// ── identity keypair ────────────────────────────────────────

export async function generateIdentity() {
  return crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,               // extractable — we must export to wrap and to store
    ['deriveKey', 'deriveBits']
  );
}

export async function exportPublicKey(keyPair) {
  return crypto.subtle.exportKey('jwk', keyPair.publicKey);
}

export async function importPublicKey(jwk) {
  return crypto.subtle.importKey(
    'jwk', jwk,
    { name: 'ECDH', namedCurve: 'P-256' },
    true, []
  );
}

// ── password-wrapped private key ────────────────────────────

async function deriveWrappingKey(password, salt) {
  const material = await crypto.subtle.importKey(
    'raw', enc.encode(password), 'PBKDF2', false, ['deriveKey']
  );
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}

/** Wraps the private key for storage. Returns a JSON-safe object. */
export async function wrapPrivateKey(keyPair, password) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));

  const jwk = await crypto.subtle.exportKey('jwk', keyPair.privateKey);
  const wrapKey = await deriveWrappingKey(password, salt);

  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    wrapKey,
    enc.encode(JSON.stringify(jwk))
  );

  return {
    v: 1,
    salt: bufToB64(salt),
    iv: bufToB64(iv),
    data: bufToB64(ciphertext),
  };
}

/** Reverses wrapPrivateKey. Throws if the password is wrong (GCM tag fails). */
export async function unwrapPrivateKey(wrapped, password) {
  const salt = new Uint8Array(b64ToBuf(wrapped.salt));
  const iv = new Uint8Array(b64ToBuf(wrapped.iv));
  const wrapKey = await deriveWrappingKey(password, salt);

  let plain;
  try {
    plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv }, wrapKey, b64ToBuf(wrapped.data)
    );
  } catch {
    throw new Error('Could not unlock your encryption key — wrong password?');
  }

  const jwk = JSON.parse(dec.decode(plain));
  return crypto.subtle.importKey(
    'jwk', jwk,
    { name: 'ECDH', namedCurve: 'P-256' },
    true, ['deriveKey', 'deriveBits']
  );
}

// ── device linking (move an identity to a new device, no password) ──
//
// A new device generates a throwaway ECDH keypair and shows its public half
// in a QR. The already-signed-in device scans it, does ECDH against that
// ephemeral key (HKDF label below keeps it distinct from message/wrap keys),
// and encrypts its OWN private identity key under the result. Only the new
// device — the sole holder of the matching ephemeral private key — can
// decrypt it. The server relays the ciphertext without ever being able to
// read it, exactly like a message.

async function deriveLinkKey(myPrivateKey, peerPublicJwk) {
  const peerKey = await importPublicKey(peerPublicJwk);
  const bits = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: peerKey }, myPrivateKey, 256
  );
  const hkdfMaterial = await crypto.subtle.importKey('raw', bits, 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    {
      name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0),
      info: enc.encode('vesper-chat/v1/device-link'),
    },
    hkdfMaterial,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}

/** Fresh ECDH P-256 keypair for one link attempt. Public half → QR. */
export async function generateLinkEphemeral() {
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']
  );
  return { privateKey: pair.privateKey, publicKeyJwk: await crypto.subtle.exportKey('jwk', pair.publicKey) };
}

/** Signed-in device: seal my identity private key for the ephemeral holder. */
export async function sealIdentityForLink(myPrivateKey, ephemeralPublicJwk) {
  const linkKey = await deriveLinkKey(myPrivateKey, ephemeralPublicJwk);
  const jwk = await crypto.subtle.exportKey('jwk', myPrivateKey);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, linkKey, enc.encode(JSON.stringify(jwk))
  );
  return { wrappedKey: bufToB64(ct), wrappedIv: bufToB64(iv) };
}

/** New device: recover the identity private key sealed by the other device. */
export async function openIdentityFromLink(ephemeralPrivateKey, accountPublicJwk, wrappedKey, wrappedIv) {
  const linkKey = await deriveLinkKey(ephemeralPrivateKey, accountPublicJwk);
  let plain;
  try {
    plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: new Uint8Array(b64ToBuf(wrappedIv)) },
      linkKey,
      b64ToBuf(wrappedKey)
    );
  } catch {
    throw new Error('Could not unlock the linked key — the QR may have been for a different account.');
  }
  const jwk = JSON.parse(dec.decode(plain));
  return crypto.subtle.importKey(
    'jwk', jwk, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
  );
}

// ── session persistence (survive refresh, not logout) ──────
//
// The unwrapped private key normally lives only in memory, so a page refresh
// wipes it and forces the password to be re-entered before messages can be
// read again. IndexedDB can hold a CryptoKey object directly (the browser
// structured-clones it), so instead we stash a NON-extractable copy there:
// it works exactly like the original for ECDH, but its raw bytes can never
// be pulled back out via exportKey — even a script that reads the database
// directly only gets a handle it can *use*, not one it can steal. That's
// still local storage rather than "forgotten the moment the tab closes", so
// callers must clear it on logout instead of relying on the page unloading.

const SESSION_DB = 'vesper-session';
const SESSION_STORE = 'keys';

function openSessionDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(SESSION_DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(SESSION_STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

/** Persists a non-extractable copy of `privateKey` for reuse after a refresh. */
export async function saveSessionKey(privateKey) {
  const jwk = await crypto.subtle.exportKey('jwk', privateKey);
  const locked = await crypto.subtle.importKey(
    'jwk', jwk, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveKey', 'deriveBits']
  );

  const db = await openSessionDb();
  await new Promise((resolve, reject) => {
    const tx = db.transaction(SESSION_STORE, 'readwrite');
    tx.objectStore(SESSION_STORE).put(locked, 'privateKey');
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  db.close();
}

/** Returns the persisted CryptoKey, or null if none was saved (or storage is unavailable). */
export async function loadSessionKey() {
  try {
    const db = await openSessionDb();
    const key = await new Promise((resolve, reject) => {
      const tx = db.transaction(SESSION_STORE, 'readonly');
      const req = tx.objectStore(SESSION_STORE).get('privateKey');
      req.onsuccess = () => resolve(req.result ?? null);
      req.onerror = () => reject(req.error);
    });
    db.close();
    return key;
  } catch {
    return null;
  }
}

export async function clearSessionKey() {
  try {
    const db = await openSessionDb();
    await new Promise((resolve, reject) => {
      const tx = db.transaction(SESSION_STORE, 'readwrite');
      tx.objectStore(SESSION_STORE).delete('privateKey');
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
    db.close();
  } catch { /* nothing to clear */ }
}

// ── per-conversation shared key ─────────────────────────────

const sharedKeyCache = new Map(); // peerPublicKey fingerprint -> CryptoKey

/**
 * Derives the AES-GCM key shared with one peer.
 * ECDH gives raw bits; HKDF then domain-separates them into an actual AES key
 * (using the raw ECDH output directly as key material is a classic mistake).
 */
export async function deriveSharedKey(myPrivateKey, peerPublicJwk) {
  const cacheKey = peerPublicJwk.x + '|' + peerPublicJwk.y;
  if (sharedKeyCache.has(cacheKey)) return sharedKeyCache.get(cacheKey);

  const peerKey = await importPublicKey(peerPublicJwk);

  const bits = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: peerKey }, myPrivateKey, 256
  );

  const hkdfMaterial = await crypto.subtle.importKey(
    'raw', bits, 'HKDF', false, ['deriveKey']
  );

  const key = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(0),
      info: enc.encode('vesper-chat/v1/message-key'),
    },
    hkdfMaterial,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );

  sharedKeyCache.set(cacheKey, key);
  return key;
}

export function clearKeyCache() {
  sharedKeyCache.clear();
}

// ── envelope encryption (groups & status) ───────────────────
//
// Groups and status posts have more than one reader, so there's no single
// "the" pairwise key to encrypt with. Instead: generate one random AES key
// (the "content key"), encrypt the actual content with it once, then wrap
// (encrypt) that content key separately for each recipient using a pairwise
// key derived the same way deriveSharedKey does — ECDH between the wrapper
// and that recipient, then HKDF.
//
// That pairwise wrap-key is deliberately NOT the same key deriveSharedKey
// produces for 1:1 chat messages, even though it starts from the same ECDH
// bits. A distinct HKDF `info` label below domain-separates it into a
// different key entirely. Reusing one key as both a message key and a
// key-encryption-key is exactly the kind of thing that turns one bug into
// two — a mistake in the group-wrapping code path would otherwise also be
// a mistake in that pair's entire 1:1 message history, and vice versa.

const wrapKeyCache = new Map(); // peerPublicKey fingerprint -> CryptoKey

/**
 * Generates a random per-group/per-status AES-GCM key. Extractable, unlike
 * deriveSharedKey's output — deriveSharedKey never needs to be exported
 * because it's re-derivable from the two keypairs at any time, but this key
 * is random and NOT re-derivable, so it must be exportable to be re-wrapped
 * for a member added after the group already exists.
 */
export async function generateContentKey() {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  const key = await crypto.subtle.importKey(
    'raw', raw, { name: 'AES-GCM' }, true, ['encrypt', 'decrypt']
  );
  return { key, raw };
}

export async function importContentKey(raw) {
  return crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, true, ['encrypt', 'decrypt']);
}

/** Same ECDH→HKDF shape as deriveSharedKey, but a distinct label and cache —
 *  see the note above for why this must not be the same key. */
export async function deriveWrapKey(myPrivateKey, peerPublicJwk) {
  const cacheKey = peerPublicJwk.x + '|' + peerPublicJwk.y;
  if (wrapKeyCache.has(cacheKey)) return wrapKeyCache.get(cacheKey);

  const peerKey = await importPublicKey(peerPublicJwk);

  const bits = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: peerKey }, myPrivateKey, 256
  );

  const hkdfMaterial = await crypto.subtle.importKey(
    'raw', bits, 'HKDF', false, ['deriveKey']
  );

  const key = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(0),
      info: enc.encode('vesper-chat/v1/key-wrap'),
    },
    hkdfMaterial,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );

  wrapKeyCache.set(cacheKey, key);
  return key;
}

/** Encrypts the content key's raw bytes under a wrap key. Same shape as
 *  encryptText, just operating on raw key bytes instead of UTF-8 text. */
export async function wrapContentKey(wrapKey, rawKeyBytes) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, wrapKey, rawKeyBytes);
  return { wrappedKey: bufToB64(ct), wrappedIv: bufToB64(iv) };
}

/** Reverses wrapContentKey and imports the result as a usable AES-GCM key. */
export async function unwrapContentKey(wrapKey, wrappedKey, wrappedIv) {
  const raw = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: new Uint8Array(b64ToBuf(wrappedIv)) },
    wrapKey,
    b64ToBuf(wrappedKey)
  );
  return importContentKey(new Uint8Array(raw));
}

// ── message encryption ──────────────────────────────────────

/** Returns { ciphertext, iv } — both base64, both safe to hand to the server. */
export async function encryptText(key, text) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, key, enc.encode(text)
  );
  return { ciphertext: bufToB64(ct), iv: bufToB64(iv) };
}

export async function decryptText(key, ciphertext, iv) {
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: new Uint8Array(b64ToBuf(iv)) },
    key,
    b64ToBuf(ciphertext)
  );
  return dec.decode(plain);
}

/**
 * Encrypts a file's bytes plus its metadata.
 * The filename and MIME type are encrypted too — leaving them readable would
 * hand the server most of what it wanted to know anyway.
 */
/**
 * `extra` merges additional plaintext fields into the encrypted metadata
 * before it's sealed — e.g. a status photo's caption. Every existing caller
 * (messages, voice notes) passes none and is unaffected; the caption itself
 * ends up exactly as protected as the filename/mime already are.
 */
export async function encryptFile(key, file, extra = {}) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const bytes = await file.arrayBuffer();

  const blobCt = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, bytes);

  // blobIv travels INSIDE the encrypted metadata. The message row therefore holds
  // only the metadata ciphertext and its own IV, and the server learns nothing —
  // not the filename, not the type, not even the nonce for the file body.
  const meta = await encryptText(key, JSON.stringify({
    name: file.name,
    mime: file.type || 'application/octet-stream',
    size: file.size,
    blobIv: bufToB64(iv),
    ...extra,
  }));

  return {
    blob: new Blob([blobCt], { type: 'application/octet-stream' }),
    ciphertext: meta.ciphertext,
    iv: meta.iv,
  };
}

export async function decryptFileMeta(key, ciphertext, iv) {
  return JSON.parse(await decryptText(key, ciphertext, iv));
}

export async function decryptFileBytes(key, arrayBuffer, blobIv) {
  // A file sent over Signal carries its own one-time key: "k:<key>:<iv>"
  // (inside the sealed message — the server never sees it). Older files use
  // the chat's key.
  if (typeof blobIv === 'string' && blobIv.startsWith('k:')) {
    const [, rawKey, iv] = blobIv.split(':');
    const fileKey = await crypto.subtle.importKey('raw', b64ToBuf(rawKey), 'AES-GCM', false, ['decrypt']);
    return crypto.subtle.decrypt({ name: 'AES-GCM', iv: new Uint8Array(b64ToBuf(iv)) }, fileKey, arrayBuffer);
  }
  return crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: new Uint8Array(b64ToBuf(blobIv)) },
    key,
    arrayBuffer
  );
}

/**
 * For the Signal protocol: a photo/video/voice note is locked with its own
 * brand-new random key. That key (with the file's name and type) goes into
 * the message, which Signal then seals per device — so the server only ever
 * holds the locked file, never anything that opens it.
 */
export async function sealFileForSignal(file, extra = {}) {
  const fileKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const blobCt = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, fileKey, await file.arrayBuffer());
  const rawKey = await crypto.subtle.exportKey('raw', fileKey);
  const meta = {
    name: file.name,
    mime: file.type || 'application/octet-stream',
    size: file.size,
    blobIv: `k:${bufToB64(rawKey)}:${bufToB64(iv)}`,
    ...extra,
  };
  return { blob: new Blob([blobCt], { type: 'application/octet-stream' }), meta };
}

/**
 * A short human-comparable fingerprint of the conversation key, so two people
 * can read it aloud and confirm nobody swapped a public key in transit.
 */
export async function safetyNumber(myPublicJwk, peerPublicJwk) {
  const pair = [myPublicJwk.x + myPublicJwk.y, peerPublicJwk.x + peerPublicJwk.y]
    .sort()
    .join('|');
  const digest = await crypto.subtle.digest('SHA-256', enc.encode(pair));
  const bytes = new Uint8Array(digest).slice(0, 15);

  return [...bytes]
    .map((b) => String(b).padStart(3, '0'))
    .join('')
    .match(/.{1,5}/g)
    .join(' ');
}
