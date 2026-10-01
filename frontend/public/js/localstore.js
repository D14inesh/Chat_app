/**
 * On-device storage — the "your phone is the storage" layer, like WhatsApp.
 *
 * The server still holds the ciphertext (that's how a new device or another
 * tab catches up), but once THIS device has decrypted a message or downloaded
 * a piece of media, it keeps the readable copy in IndexedDB. After that:
 *   · opening a chat renders instantly from the local copy, even offline
 *   · a photo / video / voice note / sticker is never re-downloaded or
 *     re-decrypted — it's read straight off the device
 *
 * Everything here fails soft: a private window, cleared site data or a browser
 * that blocks IndexedDB just means the app behaves like it did before (fetch +
 * decrypt every time). Nothing is ever the ONLY copy — the server ciphertext
 * remains the source of truth.
 */

const DB_NAME = 'vesper-store';
const DB_VERSION = 2;
const MSG_STORE = 'messages';   // key: message id   → full server row + { _body }
const MEDIA_STORE = 'media';    // key: server path  → { blob, mime, ts }
const OUTBOX_STORE = 'outbox';  // key: tempId       → queued outgoing message

let dbPromise = null;

function openDb() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    let req;
    try {
      req = indexedDB.open(DB_NAME, DB_VERSION);
    } catch (err) {
      reject(err);
      return;
    }
    req.onupgradeneeded = () => {
      const db = req.result;
      const msgs = db.objectStoreNames.contains(MSG_STORE)
        ? req.transaction.objectStore(MSG_STORE)
        : db.createObjectStore(MSG_STORE);
      if (!msgs.indexNames.contains('byConvo')) msgs.createIndex('byConvo', 'conversationId');
      if (!db.objectStoreNames.contains(MEDIA_STORE)) db.createObjectStore(MEDIA_STORE);
      if (!db.objectStoreNames.contains(OUTBOX_STORE)) db.createObjectStore(OUTBOX_STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error('IndexedDB blocked'));
  }).catch((err) => {
    dbPromise = null;
    throw err;
  });
  return dbPromise;
}

function reqAsPromise(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function withStore(name, mode, fn) {
  const db = await openDb();
  const tx = db.transaction(name, mode);
  const result = await fn(tx.objectStore(name));
  await new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
  return result;
}

export const localStore = {
  available() {
    return typeof indexedDB !== 'undefined';
  },

  // ── messages ──
  async getMessage(id) {
    try { return await withStore(MSG_STORE, 'readonly', (s) => reqAsPromise(s.get(id))); }
    catch { return null; }
  },

  /** All cached rows for one conversation, oldest-first. */
  async getConversationMessages(conversationId) {
    try {
      return await withStore(MSG_STORE, 'readonly', (s) => {
        const idx = s.index('byConvo');
        return reqAsPromise(idx.getAll(IDBKeyRange.only(conversationId)));
      }).then((rows) => rows.sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt)));
    } catch { return []; }
  },

  /** Store a server message row plus its decrypted body (`body` may be a
   *  string, an object for file/voice/etc, or null when undecryptable). */
  async putMessage(m, body) {
    try {
      await withStore(MSG_STORE, 'readwrite', (s) => s.put({ ...m, _body: body }, m.id));
    } catch { /* storage full / unavailable — fine */ }
  },

  async putMessages(list) {
    try {
      await withStore(MSG_STORE, 'readwrite', (s) => {
        for (const { m, body } of list) s.put({ ...m, _body: body }, m.id);
      });
    } catch { /* ignore */ }
  },

  async deleteMessage(id) {
    try { await withStore(MSG_STORE, 'readwrite', (s) => s.delete(id)); } catch { /* ignore */ }
  },

  // ── media ──
  async getMedia(path) {
    try { return await withStore(MEDIA_STORE, 'readonly', (s) => reqAsPromise(s.get(path))); }
    catch { return null; }
  },

  async putMedia(path, blob, mime) {
    try {
      await withStore(MEDIA_STORE, 'readwrite', (s) => s.put({ blob, mime, ts: Date.now() }, path));
    } catch { /* storage full — the app still works, just re-downloads next time */ }
  },

  // ── outbox (messages sent while offline) ──
  async getOutbox() {
    try {
      return await withStore(OUTBOX_STORE, 'readonly', (s) => reqAsPromise(s.getAll()))
        .then((rows) => (rows || []).sort((a, b) => (a.queuedAt || 0) - (b.queuedAt || 0)));
    } catch { return []; }
  },
  async putOutbox(tempId, entry) {
    try { await withStore(OUTBOX_STORE, 'readwrite', (s) => s.put(entry, tempId)); }
    catch { /* storage full — the in-memory queue still tries this session */ }
  },
  async deleteOutbox(tempId) {
    try { await withStore(OUTBOX_STORE, 'readwrite', (s) => s.delete(tempId)); } catch { /* ignore */ }
  },

  // ── housekeeping ──
  async usage() {
    try {
      if (navigator.storage?.estimate) return await navigator.storage.estimate();
    } catch { /* ignore */ }
    return null;
  },

  async counts() {
    try {
      return await withStore(MSG_STORE, 'readonly', async (s) => {
        const msgs = await reqAsPromise(s.count());
        return { messages: msgs };
      });
    } catch { return { messages: 0 }; }
  },

  async clear() {
    try {
      const db = await openDb();
      const tx = db.transaction([MSG_STORE, MEDIA_STORE, OUTBOX_STORE], 'readwrite');
      tx.objectStore(MSG_STORE).clear();
      tx.objectStore(MEDIA_STORE).clear();
      tx.objectStore(OUTBOX_STORE).clear();
      await new Promise((resolve) => { tx.oncomplete = resolve; tx.onerror = resolve; });
    } catch { /* ignore */ }
  },
};
