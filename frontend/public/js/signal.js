/**
 * Signal protocol (X3DH + Double Ratchet) for this browser.
 *
 * Every phone and browser is its own Signal device. Its private keys are
 * made here and never leave this browser (IndexedDB, one database per
 * account). The server's key directory (backend/app/api/v1/signal.py) only
 * holds the public halves, and each message is sealed once per receiving
 * device (backend/app/utils/signal_envelopes.py).
 *
 * A Double-Ratchet message can be opened exactly once — its key is deleted
 * after use (that's what gives forward secrecy). So everything opened here
 * is kept here ("plain" store) and read back from there afterwards.
 *
 * The crypto itself is the open-source libsignal port in vendor/libsignal.js
 * (built from @privacyresearch/libsignal-protocol-typescript); nothing here
 * re-implements it.
 */
import { bufToB64, b64ToBuf } from './crypto.js';

const PREKEY_FIRST = 20;       // uploaded at set-up, so a new device is reachable within a second
const PREKEY_BATCH = 100;      // one-time pre-keys uploaded at a time
const PREKEY_LOW = 30;         // top up below this many left on the server
const DEVICE_CACHE_MS = 60_000;

let lib = null;                // the Signal library, loaded on first use
let db = null;                 // this account's IndexedDB
let api = null;                // app.js api()
let me = null;                 // { id }
let myDevice = null;           // this browser's Signal device number
const deviceCache = new Map(); // userId -> { at, devices: [n…] }
const opened = new Map();      // messageId -> plaintext (memory copy of "plain")
// Opening a message waits until this account's storage is open (a page
// reload renders history before set-up finishes).
let dbOpened;
let dbReady = new Promise((resolve) => { dbOpened = resolve; });

// ── IndexedDB: tiny key/value stores ─────────────────────────
const STORES = ['state', 'prekeys', 'signed', 'sessions', 'identities', 'plain'];

function openDb(userId) {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(`veyon-signal-${userId}`, 1);
    req.onupgradeneeded = () => { for (const s of STORES) if (!req.result.objectStoreNames.contains(s)) req.result.createObjectStore(s); };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
function tx(store, mode, fn) {
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode);
    const r = fn(t.objectStore(store));
    t.oncomplete = () => resolve(r?.result);
    t.onerror = () => reject(t.error);
  });
}
const get = (store, key) => tx(store, 'readonly', (s) => s.get(String(key)));
const put = (store, key, value) => tx(store, 'readwrite', (s) => s.put(value, String(key)));
const del = (store, key) => tx(store, 'readwrite', (s) => s.delete(String(key)));
const keys = (store) => tx(store, 'readonly', (s) => s.getAllKeys());

// ── The store the Signal library reads and writes ────────────
const protocolStore = {
  getIdentityKeyPair: () => get('state', 'identity'),
  getLocalRegistrationId: () => get('state', 'registrationId'),
  // Trust on first use, like Signal/WhatsApp; a changed key is accepted
  // (the person reinstalled) and recorded so a safety-number notice can show.
  isTrustedIdentity: async () => true,
  saveIdentity: async (address, key) => {
    const name = String(address).split('.')[0];
    const old = await get('identities', name);
    await put('identities', name, key);
    return !!old && bufToB64(old) !== bufToB64(key);
  },
  loadPreKey: (id) => get('prekeys', id),
  storePreKey: (id, kp) => put('prekeys', id, kp),
  removePreKey: (id) => del('prekeys', id),
  loadSignedPreKey: (id) => get('signed', id),
  storeSignedPreKey: (id, kp) => put('signed', id, kp),
  removeSignedPreKey: (id) => del('signed', id),
  loadSession: (address) => get('sessions', address),
  storeSession: (address, record) => put('sessions', address, record),
};

// Wire format: the library's message body is a "binary string".
const binToB64 = (s) => btoa(s);
const b64ToArrayBuffer = (s) => b64ToBuf(s);

async function loadLib() {
  if (!lib) {
    lib = await import('./vendor/libsignal.js');
    lib.setWebCrypto(window.crypto);
  }
  return lib;
}

// ── Set-up: make / register this browser's keys ─────────────
async function makePreKeys(count) {
  const L = await loadLib();
  const start = (await get('state', 'nextPreKeyId')) || 1;
  const out = [];
  for (let id = start; id < start + count; id++) {
    const pk = await L.KeyHelper.generatePreKey(id);
    await put('prekeys', id, pk.keyPair);
    out.push({ keyId: id, publicKey: bufToB64(pk.keyPair.pubKey) });
  }
  await put('state', 'nextPreKeyId', start + count);
  return out;
}

async function registerFresh() {
  const L = await loadLib();
  for (const s of ['prekeys', 'signed', 'sessions']) await tx(s, 'readwrite', (st) => st.clear());
  const identity = await L.KeyHelper.generateIdentityKeyPair();
  const registrationId = L.KeyHelper.generateRegistrationId();
  const signed = await L.KeyHelper.generateSignedPreKey(identity, 1);
  await put('state', 'identity', identity);
  await put('state', 'registrationId', registrationId);
  await put('signed', 1, signed.keyPair);
  await put('state', 'nextPreKeyId', 1);
  const preKeys = await makePreKeys(PREKEY_FIRST);
  const { deviceId } = await api('/api/signal/devices', {
    method: 'POST',
    body: JSON.stringify({
      registrationId,
      identityKey: bufToB64(identity.pubKey),
      signedPreKey: { keyId: 1, publicKey: bufToB64(signed.keyPair.pubKey), signature: bufToB64(signed.signature) },
      preKeys,
    }),
  });
  await put('state', 'deviceId', deviceId);
  // The rest of the one-time keys follow in the background.
  makePreKeys(PREKEY_BATCH - PREKEY_FIRST)
    .then((more) => api('/api/signal/prekeys', { method: 'POST', body: JSON.stringify({ preKeys: more }) }))
    .catch(() => { /* topped up next time instead */ });
  return deviceId;
}

/** Called once after sign-in. Never throws: if anything fails, the app just
 *  keeps using the older encryption until next time. */
export async function initSignal(apiFn, user) {
  api = apiFn;
  me = user;
  try {
    db = await openDb(user.id);
    dbOpened();
    const local = await get('state', 'deviceId');
    const server = await api('/api/signal/me');
    if (!local || !(await get('state', 'identity')) || server.deviceId !== local) {
      myDevice = await registerFresh();
    } else {
      myDevice = local;
      if (server.preKeys < PREKEY_LOW) {
        await api('/api/signal/prekeys', { method: 'POST', body: JSON.stringify({ preKeys: await makePreKeys(PREKEY_BATCH) }) });
      }
    }
  } catch (err) {
    console.warn('[signal] not available on this device yet:', err);
    dbOpened();   // don't leave anything waiting on storage that won't open
    myDevice = null;
  }
  return myDevice;
}

export const signalReady = () => myDevice != null;

/** Sign-out: this browser's Signal keys and opened messages go with it. */
export async function wipeSignal(userId) {
  db?.close();
  db = null;
  dbReady = new Promise((resolve) => { dbOpened = resolve; });
  myDevice = null;
  opened.clear();
  deviceCache.clear();
  await new Promise((resolve) => {
    const req = indexedDB.deleteDatabase(`veyon-signal-${userId}`);
    req.onsuccess = req.onerror = req.onblocked = () => resolve();
  });
}

// ── Devices of a person ──────────────────────────────────────
async function devicesOf(userId, fresh = false) {
  const hit = deviceCache.get(userId);
  if (!fresh && hit && Date.now() - hit.at < DEVICE_CACHE_MS) return hit.devices;
  const { devices } = await api(`/api/signal/devices/${userId}`);
  deviceCache.set(userId, { at: Date.now(), devices });
  return devices;
}

/** Someone added or removed a device — look again before the next send. */
export function forgetDevices(userId) { deviceCache.delete(userId); }

/** The server said our device list was out of date: take its list, and drop
 *  sessions with devices that are gone. */
export async function applyDeviceList(map) {
  for (const [userId, devices] of Object.entries(map || {})) {
    deviceCache.set(userId, { at: Date.now(), devices });
    for (const address of await keys('sessions')) {
      const [name, dev] = String(address).split('.');
      if (name === userId && !devices.includes(Number(dev))) await del('sessions', address);
    }
  }
}

/** Use Signal for this chat? 1-to-1 chats, once this browser is set up and
 *  the other person has at least one Signal device. */
export async function useSignalFor(convo) {
  if (!signalReady() || convo?.kind !== 'direct' || !convo.peer) return false;
  try {
    return (await devicesOf(convo.peer.id)).length > 0;
  } catch {
    return false;
  }
}

// ── Sealing (one copy per device) ────────────────────────────
async function ensureSessions(userId, devices) {
  const L = await loadLib();
  const missing = [];
  for (const d of devices) {
    const rec = await get('sessions', `${userId}.${d}`);
    if (!rec) missing.push(d);
  }
  if (!missing.length) return;
  const { devices: bundles } = await api(`/api/signal/bundles/${userId}`);
  for (const b of bundles) {
    if (!missing.includes(b.deviceId)) continue;
    await new L.SessionBuilder(protocolStore, new L.SignalProtocolAddress(userId, b.deviceId)).processPreKey({
      registrationId: b.registrationId,
      identityKey: b64ToArrayBuffer(b.identityKey),
      signedPreKey: {
        keyId: b.signedPreKey.keyId,
        publicKey: b64ToArrayBuffer(b.signedPreKey.publicKey),
        signature: b64ToArrayBuffer(b.signedPreKey.signature),
      },
      preKey: b.preKey ? { keyId: b.preKey.keyId, publicKey: b64ToArrayBuffer(b.preKey.publicKey) } : undefined,
    });
  }
}

/** Seals `text` for every device of everyone in the chat (and my own other
 *  devices). Returns the envelopes for the 'send' frame. */
export async function seal(memberIds, text) {
  const L = await loadLib();
  const bytes = new TextEncoder().encode(text).buffer;
  const envelopes = [];
  for (const userId of memberIds) {
    const devices = (await devicesOf(userId)).filter((d) => !(userId === me.id && d === myDevice));
    if (!devices.length) continue;
    await ensureSessions(userId, devices);
    for (const deviceId of devices) {
      const m = await new L.SessionCipher(protocolStore, new L.SignalProtocolAddress(userId, deviceId)).encrypt(bytes);
      envelopes.push({ userId, deviceId, type: m.type === 3 ? 3 : 1, body: binToB64(m.body) });
    }
  }
  return envelopes;
}

// ── Opening (this device's copy) ─────────────────────────────
/** The plain text of a Signal message: from this browser's copy if it was
 *  opened before, else by opening this device's envelope (once). Returns
 *  null when there's nothing this device can read (sent from here before
 *  the copy was kept, or sent before this device existed). */
// Waits for this account's storage, but never forever.
const storageOpen = () => Promise.race([dbReady, new Promise((r) => setTimeout(r, 8000))]);

export async function open(message) {
  const id = message.id;
  if (opened.has(id)) return opened.get(id);
  await storageOpen();
  if (!db) return null;
  const kept = await get('plain', id);
  if (kept !== undefined && (kept.editedAt || null) === (message.editedAt || null)) {
    opened.set(id, kept.text);
    return kept.text;
  }
  const env = message.envelope;
  if (!env) return kept?.text ?? null;
  const L = await loadLib();
  const senderDevice = Number(String(message.iv || '').split(':')[1]);
  const cipher = new L.SessionCipher(protocolStore, new L.SignalProtocolAddress(message.senderId, senderDevice));
  const buf = b64ToArrayBuffer(env.body);
  const plain = env.type === 3 ? await cipher.decryptPreKeyWhisperMessage(buf) : await cipher.decryptWhisperMessage(buf);
  const text = new TextDecoder().decode(plain);
  await keep(id, text, message.editedAt);
  return text;
}

/** Remember the plain text of a message (opened here, or written here). */
export async function keep(messageId, text, editedAt = null) {
  opened.set(messageId, text);
  await storageOpen();
  if (db) await put('plain', messageId, { text, editedAt: editedAt || null });
}

// ── Chat backup (features/backup.js) ──────────────────────────
/** Every message this browser has kept: [{ id, text, editedAt }]. */
export async function exportKept() {
  await storageOpen();
  if (!db) return [];
  const ids = (await keys('plain')) || [];
  const values = (await tx('plain', 'readonly', (s) => s.getAll())) || [];
  return ids.map((id, i) => ({ id: String(id), text: values[i]?.text, editedAt: values[i]?.editedAt || null }))
    .filter((k) => typeof k.text === 'string');
}

/** Put restored messages back. What this browser already has wins. */
export async function importKept(list) {
  await storageOpen();
  if (!db) return 0;
  const have = new Set(((await keys('plain')) || []).map(String));
  const fresh = list.filter((k) => k && k.id && typeof k.text === 'string' && !have.has(String(k.id)));
  await tx('plain', 'readwrite', (s) => {
    for (const k of fresh) s.put({ text: k.text, editedAt: k.editedAt || null }, String(k.id));
  });
  for (const k of fresh) opened.set(String(k.id), k.text);
  return fresh.length;
}

export const myDeviceId = () => myDevice;
