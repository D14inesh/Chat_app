// Chat backup — WhatsApp-style end-to-end encrypted backup.
//
// Signal messages can be opened only once, on the device they reach, so this
// device's saved copy is the only readable one. Losing the device (or its
// site data) would lose them for good. A backup keeps them safe: everything
// this device has opened is packed up, locked with a key made from a backup
// password only the person knows, and the locked file is kept on the server.
// The server can store it but never read it. Forget the password and the
// backup can't be opened — by anyone.
//
// File format (shared with the phone app, lib/core/chat_backup.dart):
//   "VBK1" | iterations (u32, big-endian) | salt (16) | iv (12) | AES-256-GCM( gzip( JSON ) )
//   key = PBKDF2-HMAC-SHA256(password, salt, iterations) → 32 bytes
//   JSON = { v: 1, userId, createdAt, kept: [{ id, text, editedAt }] }
// Photos, videos and voice notes aren't copied into the backup: their keys
// are inside the backed-up messages, so they open again from those.

import { app, openModal } from './core.js';
import * as Sig from '../signal.js';
import { localStore } from '../localstore.js';

const MAGIC = [0x56, 0x42, 0x4b, 0x31]; // "VBK1"
const ITERATIONS = 250000; // same cost as the sign-in key (crypto.js)
const DAY = 24 * 60 * 60 * 1000;
const PERIODS = { daily: DAY, weekly: 7 * DAY, off: 0 };

const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

// ── This device's backup settings (the key, never the password) ──
const confKey = () => `veyon.backup.${app.state.me?.id}`;
function readConf() {
  try { return JSON.parse(localStorage.getItem(confKey()) || 'null'); } catch { return null; }
}
function writeConf(conf) {
  try {
    if (conf) localStorage.setItem(confKey(), JSON.stringify(conf));
    else localStorage.removeItem(confKey());
  } catch { /* storage blocked */ }
}

// ── Crypto ──
async function deriveKey(password, salt, iterations) {
  const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations }, base, 256);
  return new Uint8Array(bits);
}

async function pipe(bytes, stream) {
  return new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(stream)).arrayBuffer());
}

async function seal(payload, keyBytes, salt, iterations) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey('raw', keyBytes, 'AES-GCM', false, ['encrypt']);
  const zipped = await pipe(new TextEncoder().encode(JSON.stringify(payload)), new CompressionStream('gzip'));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, zipped));
  const out = new Uint8Array(4 + 4 + 16 + 12 + ct.length);
  out.set(MAGIC, 0);
  new DataView(out.buffer).setUint32(4, iterations);
  out.set(salt, 8);
  out.set(iv, 24);
  out.set(ct, 36);
  return out;
}

function header(bytes) {
  if (bytes.length < 36 || MAGIC.some((b, i) => bytes[i] !== b)) throw new Error('This isn’t a chat backup.');
  return {
    iterations: new DataView(bytes.buffer, bytes.byteOffset).getUint32(4),
    salt: bytes.slice(8, 24),
    iv: bytes.slice(24, 36),
    ct: bytes.slice(36),
  };
}

/** Throws 'WRONG_PASSWORD' when the key doesn't open it. */
async function open(bytes, keyBytes) {
  const h = header(bytes);
  let zipped;
  try {
    const key = await crypto.subtle.importKey('raw', keyBytes, 'AES-GCM', false, ['decrypt']);
    zipped = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: h.iv }, key, h.ct));
  } catch {
    throw new Error('WRONG_PASSWORD');
  }
  return JSON.parse(new TextDecoder().decode(await pipe(zipped, new DecompressionStream('gzip'))));
}

// ── Server ──
const info = () => app.api('/api/backup').then((r) => r.backup).catch(() => null);

async function download() {
  const res = await fetch(app.apiUrl('/api/backup/data'), { credentials: 'include' });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error('Could not download the backup.');
  return new Uint8Array(await res.arrayBuffer());
}

// ── Back up ──
/** Packs up everything this device has opened, merged with what's already
 *  in the backup (other devices' messages are kept), and uploads it.
 *  Returns false when the backup on the server uses a different password. */
async function backUpNow(conf = readConf()) {
  if (!conf) throw new Error('Backup is off.');
  const key = unb64(conf.key);
  const mine = await Sig.exportKept();
  const merged = new Map();

  const existing = await download().catch(() => null);
  if (existing) {
    const h = header(existing);
    if (b64(h.salt) !== conf.salt) return false;
    try {
      const old = await open(existing, key);
      for (const k of old.kept || []) merged.set(String(k.id), k);
    } catch (err) {
      if (err.message === 'WRONG_PASSWORD') return false;
      throw err;
    }
  }
  for (const k of mine) merged.set(k.id, k); // this device's copy wins

  const kept = [...merged.values()];
  const payload = { v: 1, userId: app.state.me.id, createdAt: new Date().toISOString(), kept };
  const blob = await seal(payload, key, unb64(conf.salt), conf.iterations);
  const form = new FormData();
  form.append('blob', new Blob([blob]), 'backup.bin');
  form.append('messageCount', String(kept.length));
  form.append('device', 'Web browser');
  await app.api('/api/backup', { method: 'PUT', body: form });
  writeConf({ ...conf, last: Date.now() });
  return true;
}

// ── Restore ──
/** Opens the server backup with `password` and puts its messages back.
 *  Turns backup on for this device with the same password. */
async function restore(password) {
  const bytes = await download();
  if (!bytes) throw new Error('There’s no backup to restore.');
  const h = header(bytes);
  const key = await deriveKey(password, h.salt, h.iterations);
  const data = await open(bytes, key); // throws WRONG_PASSWORD
  if (data.userId && data.userId !== app.state.me.id) throw new Error('This backup belongs to another account.');

  const kept = data.kept || [];
  const added = await Sig.importKept(kept);
  // Saved "couldn't open this" copies would hide the restored text.
  for (const k of kept) await localStore.deleteMessage(k.id);
  // Restoring brings back what was cleared in Storage & data, too.
  try { localStorage.removeItem('vesper-cleared-before'); } catch { /* ignore */ }

  writeConf({ salt: b64(h.salt), iterations: h.iterations, key: b64(key), freq: readConf()?.freq || 'daily', last: Date.now() });
  return { total: kept.length, added };
}

/** Sign-out: this device's opened messages go, so its backup settings go
 *  too (signing in again offers the restore). */
export function forgetBackupHere(userId) {
  try {
    localStorage.removeItem(`veyon.backup.${userId}`);
    localStorage.removeItem(`veyon.backup.asked.${userId}`);
  } catch { /* ignore */ }
}

// ── Automatic backup + new-device restore prompt (called after sign-in) ──
export function startBackupWatcher() {
  setTimeout(async () => {
    const conf = readConf();
    if (conf) {
      const period = PERIODS[conf.freq] || 0;
      if (period && Date.now() - (conf.last || 0) >= period) {
        backUpNow(conf).catch(() => { /* tries again next time */ });
      }
      return;
    }
    // Backup not set up on this device yet: offer the restore once.
    const askedKey = `veyon.backup.asked.${app.state.me?.id}`;
    try { if (localStorage.getItem(askedKey)) return; } catch { return; }
    const backup = await info();
    if (!backup) return;
    try { localStorage.setItem(askedKey, '1'); } catch { /* ignore */ }
    openRestoreDialog(backup, { firstRun: true });
  }, 4000);
}

// ── UI ──
const fmtDate = (iso) => new Date(iso).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
function fmtSize(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
const backupLine = (b) => b
  ? `Last backup: ${fmtDate(b.createdAt)} · ${b.messageCount} messages · ${fmtSize(b.size)}${b.device ? ` · from ${b.device}` : ''}`
  : 'No backup yet.';

const NOTE = `Your chats are backed up locked with a password only you know.
  Nobody else can open the backup — and if you forget the password, your
  chats can’t be restored.`;

/** Settings → Chat backup. */
export async function openBackupPanel() {
  const { box, close } = openModal(`
    <h3>Chat backup</h3>
    <p class="appearance-note" style="margin:-4px 0 14px">${NOTE}</p>
    <div class="backup-status" id="bk-status">Checking…</div>
    <div id="bk-body"></div>`, { cardClass: 'backup-card' });
  box.firstElementChild.setAttribute('data-panel', '');

  const render = async () => {
    const backup = await info();
    const conf = readConf();
    box.querySelector('#bk-status').textContent = backupLine(backup);
    const body = box.querySelector('#bk-body');

    if (conf) {
      body.innerHTML = `
        <label class="backup-row"><span>Back up automatically</span>
          <select id="bk-freq">
            <option value="daily">Daily</option>
            <option value="weekly">Weekly</option>
            <option value="off">Off (only when I tap Back up)</option>
          </select>
        </label>
        <div class="modal-actions backup-actions">
          <button type="button" class="btn-primary" id="bk-now">Back up now</button>
          <button type="button" class="btn-secondary" id="bk-change">Change password</button>
          <button type="button" class="btn-danger" id="bk-off">Turn off</button>
        </div>`;
      body.querySelector('#bk-freq').value = conf.freq || 'daily';
      body.querySelector('#bk-freq').addEventListener('change', (e) => writeConf({ ...readConf(), freq: e.target.value }));
      body.querySelector('#bk-now').addEventListener('click', async (e) => {
        const btn = e.currentTarget;
        btn.disabled = true; btn.textContent = 'Backing up…';
        try {
          if (await backUpNow()) app.toast('Chats backed up.');
          else {
            app.toast('The backup was locked with a different password on another device. Enter that password to continue.', true);
            writeConf(null);
            openRestoreDialog(await info(), { onDone: render });
          }
        } catch (err) { app.toast(err.message, true); }
        btn.disabled = false; btn.textContent = 'Back up now';
        render();
      });
      body.querySelector('#bk-change').addEventListener('click', () => openPasswordDialog({ change: true, onDone: render }));
      body.querySelector('#bk-off').addEventListener('click', async () => {
        if (!confirm('Turn off backup and delete the backup? Messages on this device stay, but they won’t be backed up any more.')) return;
        try {
          await app.api('/api/backup', { method: 'DELETE' });
          writeConf(null);
          app.toast('Backup turned off and deleted.');
        } catch (err) { app.toast(err.message, true); }
        render();
      });
    } else if (backup) {
      body.innerHTML = `
        <p class="appearance-note">A backup of your chats was found. Restore it on this device with your backup password.</p>
        <div class="modal-actions backup-actions">
          <button type="button" class="btn-primary" id="bk-restore">Restore</button>
          <button type="button" class="btn-secondary" id="bk-new">Start a new backup</button>
        </div>`;
      body.querySelector('#bk-restore').addEventListener('click', () => openRestoreDialog(backup, { onDone: render }));
      body.querySelector('#bk-new').addEventListener('click', () => {
        if (!confirm('Start a new backup with a new password? The old backup will be replaced, and anything only in it will be lost.')) return;
        openPasswordDialog({ replace: true, onDone: render });
      });
    } else {
      body.innerHTML = `
        <div class="modal-actions backup-actions">
          <button type="button" class="btn-primary" id="bk-on">Turn on backup</button>
        </div>`;
      body.querySelector('#bk-on').addEventListener('click', () => openPasswordDialog({ onDone: render }));
    }
  };
  render();
  return close;
}

/** Choose a backup password (first time, or a new one), then back up. */
function openPasswordDialog({ change = false, replace = false, onDone } = {}) {
  const { box, close } = openModal(`
    <h3>${change ? 'New backup password' : 'Create a backup password'}</h3>
    <p class="appearance-note" style="margin:-4px 0 14px">
      At least 8 characters. Write it down somewhere safe — it can’t be reset,
      and without it the backup can’t be opened.
    </p>
    <form id="bk-pw-form">
      <div class="field"><label>Backup password</label><input type="password" id="bk-pw1" placeholder="At least 8 characters" autocomplete="new-password" minlength="8" required></div>
      <div class="field"><label>Type it again</label><input type="password" id="bk-pw2" autocomplete="new-password" minlength="8" required></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="bk-pw-cancel">Cancel</button>
        <button type="submit" class="btn-primary" id="bk-pw-ok">${change ? 'Change & back up' : 'Turn on & back up'}</button>
      </div>
    </form>`);
  box.querySelector('#bk-pw-cancel').addEventListener('click', close);
  box.querySelector('#bk-pw1').focus();
  box.querySelector('#bk-pw-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const pw1 = box.querySelector('#bk-pw1').value;
    const pw2 = box.querySelector('#bk-pw2').value;
    if (pw1.length < 8) { app.toast('Use at least 8 characters.', true); return; }
    if (pw1 !== pw2) { app.toast('The two passwords don’t match.', true); return; }
    const btn = box.querySelector('#bk-pw-ok');
    btn.disabled = true; btn.textContent = 'Backing up…';
    try {
      // Keep whatever the current backup has (other devices' messages) when
      // changing the password: open it with the old key first.
      let carry = [];
      const old = readConf();
      if (change && old) {
        const existing = await download().catch(() => null);
        if (existing) carry = (await open(existing, unb64(old.key)).catch(() => ({}))).kept || [];
      }
      const salt = crypto.getRandomValues(new Uint8Array(16));
      const key = await deriveKey(pw1, salt, ITERATIONS);
      const conf = { salt: b64(salt), iterations: ITERATIONS, key: b64(key), freq: old?.freq || 'daily', last: 0 };
      if (change || replace) await app.api('/api/backup', { method: 'DELETE' });
      if (carry.length) await Sig.importKept(carry);
      writeConf(conf);
      await backUpNow(conf);
      app.toast(change ? 'Backup password changed.' : 'Backup is on. Your chats are backed up.');
      close();
      onDone?.();
    } catch (err) {
      app.toast(err.message, true);
      btn.disabled = false; btn.textContent = change ? 'Change & back up' : 'Turn on & back up';
    }
  });
}

/** Enter the backup password to restore (Settings, or first sign-in here). */
function openRestoreDialog(backup, { firstRun = false, onDone } = {}) {
  const { box, close } = openModal(`
    <h3>${firstRun ? 'Restore your chats?' : 'Restore backup'}</h3>
    <p class="appearance-note" style="margin:-4px 0 14px">
      ${backup ? app.escapeHtml(backupLine(backup)) : ''}<br>
      Enter your backup password to bring your messages back to this device.
    </p>
    <form id="bk-rs-form">
      <div class="field"><label>Backup password</label><input type="password" id="bk-rs-pw" autocomplete="current-password" required></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="bk-rs-skip">${firstRun ? 'Skip' : 'Cancel'}</button>
        <button type="submit" class="btn-primary" id="bk-rs-ok">Restore</button>
      </div>
    </form>`);
  box.querySelector('#bk-rs-skip').addEventListener('click', close);
  box.querySelector('#bk-rs-pw').focus();
  box.querySelector('#bk-rs-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = box.querySelector('#bk-rs-ok');
    btn.disabled = true; btn.textContent = 'Restoring…';
    try {
      const { total } = await restore(box.querySelector('#bk-rs-pw').value);
      close();
      onDone?.();
      app.toast(`Restored ${total} messages. Reloading…`);
      setTimeout(() => location.reload(), 1200);
    } catch (err) {
      app.toast(err.message === 'WRONG_PASSWORD' ? 'Wrong backup password.' : err.message, true);
      btn.disabled = false; btn.textContent = 'Restore';
    }
  });
}
