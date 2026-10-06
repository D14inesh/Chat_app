import {
  generateIdentity, exportPublicKey, wrapPrivateKey, unwrapPrivateKey,
  deriveSharedKey, clearKeyCache, encryptText, decryptText,
  encryptFile, decryptFileMeta, decryptFileBytes, safetyNumber, b64ToBuf, bufToB64,
  generateContentKey, deriveWrapKey, wrapContentKey, unwrapContentKey,
  saveSessionKey, loadSessionKey, clearSessionKey,
  generateLinkEphemeral, sealIdentityForLink, openIdentityFromLink,
} from './crypto.js';
import { localStore } from './localstore.js';
import * as F from './features/index.js';

// ═══════════════════════════════════════════════════════════
// Backend location (the API is served separately — see config.js)
// ═══════════════════════════════════════════════════════════

const API_BASE = (() => {
  const cfg = window.APP_CONFIG || {};
  if (cfg.apiBase) return cfg.apiBase.replace(/\/+$/, '');
  // Default: backend on the same host as this page, on its own port — so
  // localhost and LAN IPs both work without editing anything.
  const https = location.protocol === 'https:';
  const port = https ? (cfg.apiHttpsPort ?? 4443) : (cfg.apiHttpPort ?? 4000);
  return `${location.protocol}//${location.hostname}:${port}`;
})();

/** Backend paths ("/api/...") become absolute URLs on the API origin;
 *  anything else (blob:, data:, external) passes through untouched. */
function apiUrl(path) {
  return typeof path === 'string' && path.startsWith('/api/') ? API_BASE + path : path;
}

// ═══════════════════════════════════════════════════════════
// State
// ═══════════════════════════════════════════════════════════

const state = {
  me: null,
  privateKey: null,
  publicJwk: null,
  conversations: new Map(),   // id -> conversation
  keys: new Map(),            // conversationId -> AES CryptoKey
  plaintext: new Map(),       // messageId -> decrypted text (avoids re-decrypting)
  messages: new Map(),        // conversationId -> array of messages
  online: new Set(),
  activeId: null,
  ws: null,
  typingTimer: null,
  peerTypingTimer: null,
  searching: false,
  statuses: [],                // flat list from GET /api/status, newest first
  groupMembers: new Map(),     // conversationId -> members array (groups only)
  replyingTo: null,            // {id, senderId, previewText, senderName} or null
  editingId: null,             // messageId currently being edited, or null
  reactionPlaintext: new Map(), // "messageId:userId" -> decrypted emoji (or null)
  call: null,                  // active/ringing 1:1 call state, or null — see "Calling" section
  groupCall: null,             // active group-call room state, or null — see "Group calling" section
  liveGame: null,              // active/pending live game state, or null — see "Live games" section
  pendingGameInvite: null,     // an incoming invite awaiting Accept/Decline, or null
  starredIds: new Set(),       // message ids this user has starred
  labels: [],                  // [{id, name, color, conversationIds}] — custom chat lists
  chatSelectMode: false,       // sidebar "Select chats" bulk mode
  selectedChatIds: new Set(),
  msgSelectMode: false,        // "Select messages" bulk mode inside the open chat
  selectedMessageIds: new Set(),
  blockedIds: new Set(),       // user ids *I've* blocked
  voiceCommands: { active: false, recognizer: null }, // "Hey ARM" listener — see its own section
  chatFilter: 'all',           // sidebar tab: all | unread | favorites | groups | private
  appearance: null,            // { palette, mode, structure } — see applyAppearance
  outbox: new Map(),           // tempId -> queued outgoing message (offline); see localstore.js
};

const $ = (id) => document.getElementById(id);

// ═══════════════════════════════════════════════════════════
// Appearance — palette / light-dark / structure, synced per account
// ═══════════════════════════════════════════════════════════
// The look lives entirely in theme.css as CSS custom properties, keyed off
// three attributes on <html>: data-palette, data-theme (dark|light) and
// data-structure (floating|boxed). This module flips those attributes,
// caches the choice to localStorage (so index.html's <head> script can
// avoid a flash on the next load) and PATCHes it to the server so it
// follows the account to other devices. First paint is done by that head
// script; enterApp() re-applies whatever the server returns.

const APPEARANCE_DEFAULT = { palette: 'veyon', mode: 'dark', structure: 'floating' };
const APPEARANCE_ALLOWED = {
  palette: ['veyon', 'aurora', 'obsidian', 'nord', 'cyber', 'plum'],
  mode: ['dark', 'light'],
  structure: ['floating', 'boxed'],
};
// Browser-chrome colour — matches --bg for each palette/mode.
const THEME_COLORS = {
  'veyon:dark': '#0e0f11',    'veyon:light': '#f3f2ef',
  'aurora:dark': '#08090F',   'aurora:light': '#F3F3FB',
  'obsidian:dark': '#0A0A0B', 'obsidian:light': '#F1EEE7',
  'nord:dark': '#2E3440',     'nord:light': '#E5E9F0',
  'cyber:dark': '#05060A',    'cyber:light': '#05060A',
  'plum:dark': '#211A30',     'plum:light': '#FFF7FB',
};

function normalizeAppearance(raw) {
  const a = { ...APPEARANCE_DEFAULT };
  if (raw && typeof raw === 'object') {
    for (const key of Object.keys(APPEARANCE_ALLOWED)) {
      if (APPEARANCE_ALLOWED[key].includes(raw[key])) a[key] = raw[key];
    }
  }
  if (a.palette === 'cyber') a.mode = 'dark'; // neon has no light variant
  return a;
}

/** Applies an appearance choice to <html>, caches it, remembers it on state.
 *  Accepts a partial/unsanitised object. Returns the resolved one. */
function applyAppearance(raw) {
  const a = normalizeAppearance(raw);
  const root = document.documentElement;
  root.dataset.palette = a.palette;
  root.dataset.theme = a.mode;
  root.dataset.structure = a.structure;

  try { localStorage.setItem('vesper.appearance', JSON.stringify(a)); } catch { /* storage off */ }

  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.content = THEME_COLORS[`${a.palette}:${a.mode}`] || '#08090F';

  state.appearance = a;
  return a;
}

async function saveAppearanceToServer(patch) {
  try {
    const { appearance } = await api('/api/users/me/appearance', {
      method: 'PATCH',
      body: JSON.stringify(patch),
    });
    applyAppearance(appearance);
    if (state.me) state.me.appearance = state.appearance;
  } catch (err) {
    toast(err.message, true);
  }
}

// Kinds whose ciphertext is a JSON payload (decrypt-then-parse), vs 'text'
// which decrypts straight to a string. decryptFileMeta is a generic
// decrypt+JSON.parse despite its name — reused here for every JSON kind.
const JSON_KINDS = new Set(['file', 'voice', 'location', 'contact', 'poll', 'product']);

async function decryptBody(key, m) {
  // A business's automatic reply is plain text written by the server.
  if (m.kind === 'auto') return m.ciphertext;
  return JSON_KINDS.has(m.kind)
    ? decryptFileMeta(key, m.ciphertext, m.iv)
    : decryptText(key, m.ciphertext, m.iv);
}

/** Decrypt, but read the plaintext straight off this device if it was
 *  decrypted before — the "your phone is the storage" fast path. The cache
 *  is keyed by message id and invalidated when the message is edited. */
async function decryptBodyCached(key, m) {
  if (m.deleted) return null;
  try {
    const hit = await localStore.getMessage(m.id);
    if (hit && '_body' in hit && (hit.editedAt || null) === (m.editedAt || null)) {
      return hit._body;
    }
  } catch { /* fall through to a real decrypt */ }

  const body = await decryptBody(key, m);
  localStore.putMessage(m, body);
  return body;
}

/** Fetch + decrypt an attachment blob, or return the copy already on this
 *  device. Everything media-shaped (images, video, voice, stickers, GIFs,
 *  status media) goes through here. */
async function getDecryptedMediaBlob(filePath, key, blobIv, mime) {
  try {
    const cached = await localStore.getMedia(filePath);
    if (cached?.blob) return cached.blob;
  } catch { /* ignore, download it */ }

  const res = await fetch(apiUrl(`/api/upload/${filePath}`), { credentials: 'include' });
  if (!res.ok) throw new Error('Could not download the file.');
  const bytes = await decryptFileBytes(key, await res.arrayBuffer(), blobIv);
  const blob = new Blob([bytes], { type: mime || 'application/octet-stream' });
  localStore.putMedia(filePath, blob, mime);
  return blob;
}

// ═══════════════════════════════════════════════════════════
// HTTP
// ═══════════════════════════════════════════════════════════

async function api(path, options = {}) {
  const res = await fetch(apiUrl(path), {
    credentials: 'include',
    headers: options.body instanceof FormData
      ? {}
      : { 'Content-Type': 'application/json' },
    ...options,
  });

  const isJson = (res.headers.get('content-type') || '').includes('application/json');
  const data = isJson ? await res.json() : null;

  if (!res.ok) {
    // `status` tells a real server answer (e.g. 401) apart from being
    // offline — fetch() itself throws, with no status, when the server
    // can't be reached at all.
    const err = new Error(data?.error || `Request failed (${res.status})`);
    err.status = res.status;
    throw err;
  }
  return data;
}

// ── Offline copies of what boot needs (who I am, my chat list, group keys) ──
// Messages and media already live in localstore.js; these three small things
// are what let the app open with no connection instead of falling back to the
// login screen. Group keys are stored still wrapped (encrypted to my key).
const OFFLINE_ME_KEY = 'vesper.offline.me';
const OFFLINE_CONVOS_KEY = 'vesper.offline.conversations';
const OFFLINE_GROUPKEYS_KEY = 'vesper.offline.groupkeys';

function readOffline(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch { return fallback; }
}

function writeOffline(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage full / blocked — just no offline copy */ }
}

function clearOffline() {
  for (const key of [OFFLINE_ME_KEY, OFFLINE_CONVOS_KEY, OFFLINE_GROUPKEYS_KEY]) {
    try { localStorage.removeItem(key); } catch { /* ignore */ }
  }
}

// ═══════════════════════════════════════════════════════════
// Auth
// ═══════════════════════════════════════════════════════════

let authMode = 'login';

function setAuthMode(mode) {
  authMode = mode;
  const isRegister = mode === 'register';

  $('auth-sub').textContent = isRegister
    ? 'Create an account — keys are generated on this device.'
    : 'Private messaging, end to end.';
  $('auth-submit').textContent = isRegister ? 'Create account' : 'Sign in';
  $('field-display').classList.toggle('hidden', !isRegister);
  $('field-contact').classList.toggle('hidden', !isRegister);
  // Hidden required fields would block "Sign in" — disabled ones aren't checked.
  $('field-contact').querySelectorAll('input').forEach((i) => { i.disabled = !isRegister; });
  $('f-username-label').textContent = isRegister ? 'Username' : 'Username, mobile or Gmail';
  $('f-username').placeholder = isRegister ? 'ravi_kumar' : 'ravi_kumar or 98765 43210';
  $('forgot-password').classList.toggle('hidden', isRegister);
  $('auth-toggle').querySelector('span').textContent =
    isRegister ? 'Already have an account?' : 'New here?';
  $('toggle-mode').textContent = isRegister ? 'Sign in' : 'Create an account';
  $('f-password').setAttribute('autocomplete', isRegister ? 'new-password' : 'current-password');
  hideAuthError();
}

function showAuthError(msg) {
  const el = $('auth-error');
  el.textContent = msg;
  el.classList.remove('hidden');
  // The sign-up form is taller than the screen — bring the message into view.
  el.scrollIntoView({ block: 'center', behavior: 'smooth' });
}

function hideAuthError() {
  $('auth-error').classList.add('hidden');
}

$('toggle-mode').addEventListener('click', () => {
  setAuthMode(authMode === 'login' ? 'register' : 'login');
});

$('auth-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  hideAuthError();

  const btn = $('auth-submit');
  const original = btn.textContent;
  btn.disabled = true;

  const username = $('f-username').value.trim();
  const password = $('f-password').value;
  const displayName = $('f-display').value.trim();

  try {
    if (authMode === 'register') {
      const birthDate = $('f-birth').value;
      if (!birthDate) throw new Error('Enter your date of birth.');
      const contact = readSignupContact();
      if (!contact.otp) throw new Error('Tap “Send code”, then enter the 6-digit code from your Gmail.');
      btn.textContent = 'Generating keys…';

      // Key generation and PBKDF2 wrapping both happen here, in the browser.
      // The plaintext private key never exists anywhere else.
      const keyPair = await generateIdentity();
      const publicKey = await exportPublicKey(keyPair);
      const encPrivateKey = await wrapPrivateKey(keyPair, password);

      btn.textContent = 'Creating account…';
      const { user } = await api('/api/auth/register', {
        method: 'POST',
        body: JSON.stringify({ username, displayName, password, publicKey, encPrivateKey, birthDate, ...contact }),
      });

      state.privateKey = keyPair.privateKey;
      state.publicJwk = publicKey;
      await saveSessionKey(state.privateKey);
      await enterApp(user);
    } else {
      btn.textContent = 'Signing in…';
      const { user, encPrivateKey } = await api('/api/auth/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      });

      btn.textContent = 'Unlocking keys…';
      state.privateKey = await unwrapPrivateKey(encPrivateKey, password);
      state.publicJwk = (await api(`/api/users/${user.id}`)).user.publicKey;
      await saveSessionKey(state.privateKey);
      await enterApp(user);
    }
  } catch (err) {
    showAuthError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = original;
  }
});

/** This session was ended from another device ("Log out all other
 *  devices"): wipe this device's copy, back to the login screen. */
async function signedOutRemotely() {
  clearKeyCache();
  await clearSessionKey();
  await localStore.clear();
  clearOffline();
  try { sessionStorage.setItem('veyon.signedOutRemotely', '1'); } catch { /* ignore */ }
  location.reload();
}

if ((() => { try { return sessionStorage.getItem('veyon.signedOutRemotely'); } catch { return null; } })()) {
  try { sessionStorage.removeItem('veyon.signedOutRemotely'); } catch { /* ignore */ }
  setTimeout(() => toast('You were signed out from another device. Sign in again to continue.', true), 900);
}

$('logout-btn').addEventListener('click', () => signOut());

/** Signs this device out. `releaseDevice` also frees the device from this
 *  account (one account per device), so another account can sign in here. */
async function signOut(releaseDevice = false) {
  const path = releaseDevice ? '/api/auth/device/release' : '/api/auth/logout';
  try { await api(path, { method: 'POST' }); } catch { /* leaving anyway */ }
  state.ws?.close(1000, 'signed out');
  clearKeyCache();
  await clearSessionKey();
  await localStore.clear();   // the on-device copies are per-account
  clearOffline();
  location.reload();
}

// ═══════════════════════════════════════════════════════════
// Linked devices — QR sign-in on a new device, no password
// ═══════════════════════════════════════════════════════════
// The new device makes a throwaway ECDH keypair + a random device secret,
// shows a QR, and polls. The signed-in device scans it and seals its own
// identity private key to that ephemeral public key. The server only ever
// relays ciphertext — see db/schema.sql (link_requests) and routes/link.js.

const linkSecret = () => bufToB64(crypto.getRandomValues(new Uint8Array(32)));

// ── New / logged-out device: show a QR, wait for the seal ──
$('auth-link-device')?.addEventListener('click', openLinkReceiver);

async function openLinkReceiver() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Link this device</h3>
      <p class="appearance-note" style="margin:-6px 0 16px">
        On a device you're already signed in on, open
        <b>⋮ &nbsp;→&nbsp; Linked devices &nbsp;→&nbsp; Link a device</b> and scan this code.
      </p>
      <div class="qr-panel">
        <div class="link-qr-slot" id="link-qr-slot"><div class="link-spinner"></div></div>
        <p class="qr-hint" id="link-status">Preparing…</p>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="link-close">Close</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  let stopped = false;
  let code = null;
  const close = () => {
    stopped = true;
    if (code) api('/api/link/cancel', { method: 'POST', body: JSON.stringify({ code }) }).catch(() => {});
    box.remove();
  };
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#link-close').addEventListener('click', close);

  const statusEl = box.querySelector('#link-status');
  const slot = box.querySelector('#link-qr-slot');

  let ephemeral, deviceSecret;
  try {
    ephemeral = await generateLinkEphemeral();
    deviceSecret = linkSecret();
    ({ code } = await api('/api/link/start', {
      method: 'POST',
      body: JSON.stringify({ ephemeralPublicKey: ephemeral.publicKeyJwk, deviceSecret }),
    }));
  } catch (err) {
    statusEl.textContent = 'Could not start linking — ' + err.message;
    return;
  }
  if (stopped) return;

  slot.innerHTML = `<img src="${apiUrl(`/api/link/qr?code=${encodeURIComponent(code)}`)}" alt="Linking QR code" class="qr-image">`;
  statusEl.textContent = 'Waiting for the other device to scan…';

  const deadline = Date.now() + 180000;
  const tick = async () => {
    if (stopped) return;
    if (Date.now() > deadline) {
      statusEl.textContent = 'This code expired — close and try again.';
      slot.style.opacity = '0.3';
      return;
    }
    let r;
    try {
      r = await api('/api/link/poll', { method: 'POST', body: JSON.stringify({ code, deviceSecret }) });
    } catch {
      statusEl.textContent = 'This link request is no longer valid — close and try again.';
      slot.style.opacity = '0.3';
      return;
    }
    if (r.status === 'ready') {
      stopped = true;
      statusEl.textContent = 'Linked — unlocking your messages…';
      try {
        const privateKey = await openIdentityFromLink(
          ephemeral.privateKey, r.publicKey, r.wrappedKey, r.wrappedIv
        );
        state.privateKey = privateKey;
        state.publicJwk = r.publicKey;
        await saveSessionKey(privateKey);
        box.remove();
        await enterApp(r.user);
      } catch (err) {
        statusEl.textContent = err.message;
      }
      return;
    }
    setTimeout(tick, 2000);
  };
  setTimeout(tick, 1500);
}

// ── Signed-in device: scan the QR, seal the identity key ──
async function openLinkedDevicesPanel() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Linked devices</h3>
      <div class="linked-this-device">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>
        </svg>
        <div>
          <div class="ltd-name">This device</div>
          <div class="ltd-sub">${escapeHtml(navigator.platform || 'Signed in here')}</div>
        </div>
      </div>
      <p class="appearance-note" style="margin:14px 0 4px">
        Linking copies your encryption key straight to the other device — the server
        never sees it. Only link devices you own and trust.
      </p>
      <div id="link-scan-area" class="hidden" style="margin-top:14px">
        <video id="qr-scan-video" autoplay playsinline muted></video>
        <p class="qr-hint" id="qr-scan-status">Point the camera at the other device's QR.</p>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="linked-close">Close</button>
        <button type="button" class="btn-primary" id="linked-scan">Link a device</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  let scanHandle = null;
  const close = () => { scanHandle?.stop(); box.remove(); };
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#linked-close').addEventListener('click', close);

  box.querySelector('#linked-scan').addEventListener('click', async () => {
    const askManually = () => {
      const code = prompt('Enter the code shown on the other device:');
      if (code) completeDeviceLink(code.trim().toUpperCase(), box);
    };

    if (!scannerSupported()) { askManually(); return; }

    box.querySelector('#link-scan-area').classList.remove('hidden');
    box.querySelector('#linked-scan').classList.add('hidden');
    scanHandle = await startQrScanner(box, (code) => {
      scanHandle?.stop();
      scanHandle = null;
      completeDeviceLink(code, box);
    }, 'vesper:link:');

    // No camera / no decoder available — fall back instead of leaving a dead
    // video panel up.
    if (!scanHandle) {
      box.querySelector('#link-scan-area').classList.add('hidden');
      box.querySelector('#linked-scan').classList.remove('hidden');
      askManually();
    }
  });
}

async function completeDeviceLink(code, box) {
  const statusEl = box.querySelector('#qr-scan-status');
  const say = (m) => { if (statusEl) statusEl.textContent = m; else toast(m, true); };
  say('Linking…');
  try {
    const { ephemeralPublicKey } = await api('/api/link/claim', {
      method: 'POST', body: JSON.stringify({ code }),
    });

    // The key held in memory after a page refresh is non-extractable (see
    // crypto.js saveSessionKey) — it can't be handed to another device.
    // Re-derive an extractable copy from the password just for this seal.
    let identityKey = state.privateKey;
    try {
      await crypto.subtle.exportKey('jwk', identityKey);
    } catch {
      const pw = prompt('Enter your password to authorise linking a device:');
      if (!pw) { say('Linking cancelled.'); return; }
      say('Checking password…');
      const { encPrivateKey } = await api('/api/auth/me');
      identityKey = await unwrapPrivateKey(encPrivateKey, pw);
    }

    const { wrappedKey, wrappedIv } = await sealIdentityForLink(identityKey, ephemeralPublicKey);
    await api('/api/link/complete', {
      method: 'POST', body: JSON.stringify({ code, wrappedKey, wrappedIv }),
    });
    toast('Device linked — it will finish signing in on its own.');
    box.remove();
  } catch (err) {
    say(err.message);
  }
}

$('me-avatar').addEventListener('click', openEditProfile);

const PALETTE_META = [
  { key: 'veyon',    name: 'Veyon',           desc: 'Calm stone and indigo — soft and rounded, light or dark',
    sw: ['#f3f2ef', '#e3e9ff', '#4263eb', '#12b886'] },
  { key: 'aurora',   name: 'Aurora Glass',    desc: 'Frosted panels over a teal–violet aurora',
    sw: ['#08090F', '#7C5CFF', '#22D3EE', '#EC4899'] },
  { key: 'obsidian', name: 'Obsidian & Gold', desc: 'True black, warm charcoal, champagne gold',
    sw: ['#0A0A0B', '#141416', '#E8C77B', '#202024'] },
  { key: 'nord',     name: 'Nord Frost',      desc: 'Calm arctic blues — light or dark',
    sw: ['#2E3440', '#3B4252', '#88C0D0', '#5E81AC'] },
  { key: 'cyber',    name: 'Neon Cyberpunk',  desc: 'Black grid, magenta + cyan (dark only)',
    sw: ['#05060A', '#FF2E97', '#00F0FF', '#0E1119'] },
  { key: 'plum',     name: 'Sugar Plum',      desc: 'The original candy-pastel look',
    sw: ['#211A30', '#A76BC9', '#E3AEE0', '#7EE8C0'] },
];

/** Wires the palette / mode / layout controls inside an already-rendered
 *  Appearance panel (see openEditProfile). Optimistic apply, then PATCH. */
function wireAppearanceControls(box) {
  const paletteEls = [...box.querySelectorAll('#ap-palettes .palette-option')];
  const modeEls = [...box.querySelectorAll('#ap-mode button')];
  const structureEls = [...box.querySelectorAll('#ap-structure button')];
  const modeNote = box.querySelector('#ap-mode-note');
  if (!paletteEls.length) return;

  const paint = () => {
    const cur = state.appearance || normalizeAppearance(state.me?.appearance);
    paletteEls.forEach((el) => el.setAttribute('aria-checked', String(el.dataset.palette === cur.palette)));
    modeEls.forEach((el) => {
      el.classList.toggle('active', el.dataset.mode === cur.mode);
      el.setAttribute('aria-pressed', String(el.dataset.mode === cur.mode));
      el.disabled = cur.palette === 'cyber';
    });
    structureEls.forEach((el) => {
      el.classList.toggle('active', el.dataset.structure === cur.structure);
      el.setAttribute('aria-pressed', String(el.dataset.structure === cur.structure));
    });
    modeNote.textContent = cur.palette === 'cyber' ? 'Neon Cyberpunk is dark-only.' : '';
  };

  const change = (patch) => {
    applyAppearance({ ...(state.appearance || APPEARANCE_DEFAULT), ...patch });
    paint();
    saveAppearanceToServer(patch).then(paint);
  };

  paletteEls.forEach((el) => el.addEventListener('click', () => change({ palette: el.dataset.palette })));
  modeEls.forEach((el) => el.addEventListener('click', () => { if (!el.disabled) change({ mode: el.dataset.mode }); }));
  structureEls.forEach((el) => el.addEventListener('click', () => change({ structure: el.dataset.structure })));

  paint();
}

function openEditProfile() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Edit profile</h3>
      <div class="edit-profile-row">
        <div class="avatar lg" id="edit-profile-preview" style="background:${escapeAttr(state.me.avatarColor)}">
          ${avatarInner(state.me)}
        </div>
        <div>
          <input type="file" id="edit-profile-photo-input" accept="image/jpeg,image/png,image/webp" class="hidden">
          <button type="button" class="btn-secondary" id="edit-profile-choose-btn">Choose photo</button>
          <div class="edit-profile-hint">JPEG, PNG, or WebP — up to 5 MB.
            Not end-to-end encrypted, same as your username.</div>
        </div>
      </div>

      <div class="field">
        <label>Display name</label>
        <input type="text" id="edit-profile-name" maxlength="60" placeholder="Your name"
               value="${escapeAttr(state.me.displayName || '')}">
      </div>
      <div class="field">
        <label>About</label>
        <input type="text" id="edit-profile-about" maxlength="140" placeholder="Available"
               value="${escapeAttr(state.me.about || '')}">
        <div class="edit-profile-hint" style="max-width:none">Shown on your profile — visible to your contacts.</div>
      </div>
      <button type="button" class="btn-primary" id="edit-profile-save" style="margin-top:0">Save</button>

      ${F.businessSectionHtml()}

      <div class="field" style="margin-top:20px">
        <label>Appearance</label>
        <div class="appearance-note" style="margin:-2px 0 10px">Applies on every device you sign in from.</div>

        <div class="appearance-group" style="margin-top:0">
          <span class="appearance-label">Palette</span>
          <div class="palette-options" id="ap-palettes">
            ${PALETTE_META.map((p) => `
              <button type="button" class="palette-option" role="radio" data-palette="${p.key}">
                <span class="po-sw">${p.sw.map((c) => `<i style="background:${escapeAttr(c)}"></i>`).join('')}</span>
                <span class="po-text">
                  <span class="po-name">${escapeHtml(p.name)}</span>
                  <span class="po-desc">${escapeHtml(p.desc)}</span>
                </span>
              </button>`).join('')}
          </div>
        </div>

        <div class="appearance-group">
          <span class="appearance-label">Mode</span>
          <div class="appearance-seg" id="ap-mode">
            <button type="button" data-mode="dark">🌙 Dark</button>
            <button type="button" data-mode="light">☀️ Light</button>
          </div>
          <div class="appearance-note" id="ap-mode-note"></div>
        </div>

        <div class="appearance-group">
          <span class="appearance-label">Layout</span>
          <div class="appearance-seg" id="ap-structure">
            <button type="button" data-structure="floating">Floating</button>
            <button type="button" data-structure="boxed">Boxed</button>
          </div>
          <div class="appearance-note">Floating rounds each panel and leaves a gap; Boxed is edge-to-edge.</div>
        </div>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-primary" id="edit-profile-close">Done</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#edit-profile-close').addEventListener('click', close);
  box.querySelector('#edit-profile-choose-btn').addEventListener('click', () => {
    box.querySelector('#edit-profile-photo-input').click();
  });

  const saveBtn = box.querySelector('#edit-profile-save');
  saveBtn.addEventListener('click', async () => {
    const displayName = box.querySelector('#edit-profile-name').value.trim();
    const about = box.querySelector('#edit-profile-about').value.trim();
    if (!displayName) { toast('Display name can’t be empty.', true); return; }

    saveBtn.disabled = true;
    saveBtn.textContent = 'Saving…';
    try {
      const { user } = await api('/api/users/me', {
        method: 'PATCH',
        body: JSON.stringify({ displayName, about }),
      });
      state.me.displayName = user.displayName;
      state.me.about = user.about;
      $('me-name').textContent = user.displayName;
      toast('Profile saved.');
    } catch (err) {
      toast(err.message, true);
    } finally {
      saveBtn.disabled = false;
      saveBtn.textContent = 'Save';
    }
  });

  wireAppearanceControls(box);
  F.wireBusinessSection(box);

  box.querySelector('#edit-profile-photo-input').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    e.target.value = '';
    if (!file) return;

    const btn = box.querySelector('#edit-profile-choose-btn');
    btn.disabled = true;
    btn.textContent = 'Uploading…';
    try {
      const form = new FormData();
      form.append('photo', file);
      const { user } = await api('/api/users/me/photo', { method: 'POST', body: form });

      state.me.photoUrl = user.photoUrl;
      setAvatar($('me-avatar'), state.me);
      box.querySelector('#edit-profile-preview').innerHTML = avatarInner(state.me);
      toast('Profile photo updated.');
    } catch (err) {
      toast(err.message, true);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Choose photo';
    }
  });
}

// ═══════════════════════════════════════════════════════════
// Boot
// ═══════════════════════════════════════════════════════════

async function enterApp(user) {
  state.me = user;
  writeOffline(OFFLINE_ME_KEY, { user, publicJwk: state.publicJwk });
  applyAppearance(user.appearance); // server value wins over the localStorage cache

  $('auth-screen').classList.add('hidden');
  $('app-screen').classList.remove('hidden');

  setAvatar($('me-avatar'), user);
  $('me-avatar').classList.add('clickable-avatar');
  $('me-name').textContent = user.displayName;
  $('me-handle').textContent = '@' + user.username;

  await refreshPresence();
  await loadConversations();
  await hydrateOutbox();   // re-show messages queued offline before this reload
  buildSmartModel();       // learn your writing style from cached history (async, non-blocking)
  await loadStatuses();
  await loadStarredIds();
  await loadLabels();
  await loadBlockedIds();
  F.loadQuickReplies();    // "/" shortcuts in the composer (background)
  F.startExpiryWatcher();  // hides disappearing messages the moment they expire
  connectSocket();         // its 'open' handler flushes the outbox
  F.ensureContact(user);   // older accounts: add a mobile number + Gmail once
  F.ensureBirthDate(user); // …and a date of birth (1-to-1 chats are 18+)
  F.nudgeRecoveryKey(user);
  F.checkInviteHash();     // opened from a group invite link
  F.refreshMissedCalls();

  // "Hey ARM" is on unless this person turned it off (⋮ → Voice commands).
  // If mic access is refused, startVoiceCommandListener() just says so.
  if (voiceCommandsWanted()) startVoiceCommandListener({ quiet: true });
  else updateVoiceCommandsMenuLabel();
}

async function loadBlockedIds() {
  try {
    const { users } = await api('/api/users/me/blocked');
    state.blockedIds = new Set(users.map((u) => u.id));
  } catch { /* not worth failing boot over */ }
}

async function loadStarredIds() {
  try {
    const { starred } = await api('/api/messages/starred');
    state.starredIds = new Set(starred.map((m) => m.id));
  } catch { /* starred-state is decoration; not worth failing boot over */ }
}

async function loadLabels() {
  try {
    const { labels } = await api('/api/labels');
    state.labels = labels;
    renderChatFilterTabs();
  } catch { /* labels are decoration; not worth failing boot over */ }
}

/**
 * Stay signed in until the user logs out — across refreshes, closing the
 * browser and restarting the device. The unwrapped private key is kept in
 * IndexedDB (see crypto.js saveSessionKey); if it's missing (different
 * browser, cleared storage) the password prompt is the only honest option.
 *
 * Works offline too: if the server can't be reached, the app opens from this
 * device's saved copy (who I am, chat list, messages) and catches up when the
 * connection returns. Only a real "not signed in" answer from the server
 * (401) sends the user back to the login screen.
 */
async function tryResume() {
  const savedKey = await loadSessionKey();

  let user;
  let publicJwk;
  try {
    ({ user } = await api('/api/auth/me'));
    if (!savedKey) {
      setAuthMode('login');
      showAuthError('Your session is still active — enter your password to unlock your messages.');
      return;
    }
    publicJwk = (await api(`/api/users/${user.id}`)).user.publicKey;
  } catch (err) {
    if (err.status === 401) {
      await clearSessionKey();
      clearOffline();
      setAuthMode('login');
      // One account per device: a second account's old session ends here.
      if (/belongs to @/.test(err.message || '')) {
        await localStore.clear();
        showAuthError(err.message);
      }
      return;
    }
    // No answer from the server — open from the saved copy if there is one.
    const saved = readOffline(OFFLINE_ME_KEY, null);
    if (!savedKey || !saved?.user) {
      setAuthMode('login');
      if (!err.status) showAuthError('Can\'t reach the server. Check your connection and try again.');
      return;
    }
    user = saved.user;
    publicJwk = saved.publicJwk;
    toast('Offline — showing your saved chats. New messages send when you reconnect.');
  }

  state.privateKey = savedKey;
  state.publicJwk = publicJwk;
  await enterApp(user);
}

// ═══════════════════════════════════════════════════════════
// Conversations
// ═══════════════════════════════════════════════════════════

async function refreshPresence() {
  try {
    const { online } = await api('/api/presence');
    state.online = new Set(online);
  } catch { /* presence is decoration; not worth failing boot over */ }
}

async function loadConversations() {
  let conversations;
  try {
    ({ conversations } = await api('/api/conversations'));
    writeOffline(OFFLINE_CONVOS_KEY, conversations);
  } catch (err) {
    if (err.status) throw err;   // a real server error, not "offline"
    conversations = readOffline(OFFLINE_CONVOS_KEY, []);
  }

  // Someone new in the list (a request just arrived or was accepted)?
  // Presence events only reach people who already share a chat, so fetch
  // who's online again — otherwise they'd show "last seen" while online.
  const hadNew = conversations.some((c) => !state.conversations.has(c.id));

  state.conversations.clear();
  for (const c of conversations) state.conversations.set(c.id, c);
  if (hadNew && state.me) refreshPresence().then(() => { renderChatList(); updatePeerStatus(); });

  // Decrypt each sidebar preview so the list shows real text, not ciphertext.
  await Promise.all(conversations.map(async (c) => {
    if (!c.lastMessage) return;
    try {
      const key = await keyFor(c);
      state.plaintext.set(c.lastMessage.id, await decryptBody(key, c.lastMessage));
    } catch {
      state.plaintext.set(c.lastMessage.id, null); // renders as "can't decrypt"
    }
  }));

  renderChatList();
}

/** The AES key for this conversation — pairwise-derived for direct chats,
 *  unwrapped from group_keys for groups — derived/fetched once and cached. */
async function keyFor(conversation) {
  if (state.keys.has(conversation.id)) return state.keys.get(conversation.id);

  if (conversation.kind === 'group') {
    let wrapped;
    try {
      const { wrappedKey, wrappedIv, wrappedBy } = await api(`/api/conversations/${conversation.id}/key`);
      const { user: wrapper } = await api(`/api/users/${wrappedBy}`);
      wrapped = { wrappedKey, wrappedIv, wrapperPublicKey: wrapper.publicKey };
      writeOffline(OFFLINE_GROUPKEYS_KEY, { ...readOffline(OFFLINE_GROUPKEYS_KEY, {}), [conversation.id]: wrapped });
    } catch (err) {
      wrapped = readOffline(OFFLINE_GROUPKEYS_KEY, {})[conversation.id];
      if (err.status || !wrapped) throw err;   // offline AND never opened here before
    }
    if (!wrapped.wrapperPublicKey) throw new Error('Could not resolve this group\'s encryption key.');

    const wrapKey = await deriveWrapKey(state.privateKey, wrapped.wrapperPublicKey);
    const key = await unwrapContentKey(wrapKey, wrapped.wrappedKey, wrapped.wrappedIv);
    state.keys.set(conversation.id, key);
    return key;
  }

  if (!conversation.peer.publicKey) {
    throw new Error('That user has no encryption key yet.');
  }

  const key = await deriveSharedKey(state.privateKey, conversation.peer.publicKey);
  state.keys.set(conversation.id, key);
  return key;
}

async function openConversation(id) {
  const convo = state.conversations.get(id);
  if (!convo) return;
  if (!(await F.canOpenChat(convo))) return;   // locked chat: PIN first

  state.activeId = id;

  $('no-chat').classList.add('hidden');
  $('chat-pane').classList.remove('hidden');
  $('app-screen').classList.add('viewing-chat');

  const isGroup = convo.kind === 'group';

  // Groups have no photo/presence-dot concept — just colored initials from
  // the group's own title/color. Direct chats show the peer's real photo
  // (if they have one) plus the presence dot.
  setAvatar(
    $('peer-avatar'),
    isGroup ? { displayName: convo.title, avatarColor: convo.avatarColor } : convo.peer,
    { dot: !isGroup }
  );
  $('peer-name').textContent = isGroup ? convo.title : convo.peer.displayName;

  // safetyNumber is inherently pairwise — there's no single peer to compare
  // against in a group, so that button is replaced by group info instead.
  $('safety-btn').classList.toggle('hidden', isGroup);
  $('group-info-btn').classList.toggle('hidden', !isGroup);
  updateCallButtons(convo);
  applyWallpaper(convo);
  closeChatSearch();

  // Room membership for group calls is WS-only, in-memory state (see
  // hub.js) — a fresh query is how a user who opens this conversation after
  // a call already started learns about it, not just via live pushes.
  if (isGroup && callingSupported()) sendSocket({ type: 'group-call-query', conversationId: id });
  renderGroupCallBanner();

  updatePeerStatus();
  updateRequestBar(convo);
  F.renderDisappearingChip();
  F.renderPinnedBar();
  F.onChatOpened();       // admin-only composer, private-reply strip

  // Clear the unread badge immediately — waiting for the server round-trip
  // makes the UI feel laggy.
  convo.unread = 0;
  renderChatList();

  $('messages').innerHTML = '<div class="empty-hint">Loading…</div>';
  cancelReply();
  cancelEdit();
  F.hideQuickReplies();
  // This chat's half-typed draft (if any) goes back into the composer.
  input.value = F.getDraft(id);
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 132) + 'px';
  $('send-btn').disabled = input.value.trim().length === 0;

  // Instant paint from what's already on this device — before any network,
  // so an already-opened chat shows immediately (and offline).
  let paintedFromCache = false;
  if (!state.messages.has(id)) {
    try {
      const cached = await localStore.getConversationMessages(id);
      if (cached.length) {
        for (const c of cached) {
          if ('_body' in c) state.plaintext.set(c.id, c._body);
        }
        state.messages.set(id, cached.map(({ _body, ...m }) => m));
        renderMessages();
        paintedFromCache = true;
      }
    } catch { /* no cache — the server fetch below fills it in */ }
  } else {
    paintedFromCache = true;
  }

  try {
    // Sender-name labels in group bubbles need this loaded before renderMessages runs.
    if (isGroup) {
      const { members } = await api(`/api/conversations/${id}/members`);
      state.groupMembers.set(id, members);
    }

    const { messages } = await api(`/api/conversations/${id}/messages`);
    const key = await keyFor(convo);

    for (const m of messages) {
      if (state.plaintext.has(m.id) && !m.editedAt) continue;
      try {
        state.plaintext.set(m.id, await decryptBodyCached(key, m));
      } catch {
        state.plaintext.set(m.id, null);
      }
    }
    await decryptReactionsFor(key, messages);

    // Keep any still-unsent (offline) messages visible after the server list
    // replaces the in-memory one.
    for (const pending of outboxMessagesFor(id)) {
      if (!messages.some((m) => m.id === pending.id)) messages.push(pending);
    }

    state.messages.set(id, messages);
    localStore.putMessages(
      messages.filter((m) => !m.pending).map((m) => ({ m, body: state.plaintext.get(m.id) }))
    );
    F.pruneExpired();
    renderMessages();
    sendSocket({ type: 'read', conversationId: id });
    refreshComposerSuggestions();
  } catch (err) {
    // If we already painted from the on-device copy, keep showing it —
    // being offline shouldn't blank a chat you can perfectly well read.
    if (paintedFromCache) {
      toast('Offline — showing your saved copy of this chat.');
    } else {
      // The browser reports an unreachable server as "Failed to fetch".
      const why = err instanceof TypeError
        ? 'Can’t reach the server right now — check your connection, then open the chat again.'
        : err.message;
      $('messages').innerHTML =
        `<div class="empty-hint">Could not load this conversation.<br>${escapeHtml(why)}</div>`;
    }
  }

  $('composer-input').focus();
}

/**
 * Shows/hides the Accept/Decline bar for a pending direct conversation and
 * toggles the normal composer accordingly. The requester sees a "waiting"
 * notice with a normal composer underneath (they can keep messaging); the
 * non-requester sees Accept/Decline INSTEAD of a composer.
 */
function updateRequestBar(convo) {
  const isPendingForMe = convo.kind === 'direct' && convo.status === 'pending'
    && convo.requestedBy !== state.me.id;
  const isPendingForThem = convo.kind === 'direct' && convo.status === 'pending'
    && convo.requestedBy === state.me.id;
  const iBlockedThem = convo.kind === 'direct' && state.blockedIds.has(convo.peer?.id);

  $('request-bar').classList.toggle('hidden', !isPendingForMe);
  $('waiting-notice').classList.toggle('hidden', !isPendingForThem);
  $('blocked-notice').classList.toggle('hidden', !iBlockedThem);
  $('composer').classList.toggle('hidden', isPendingForMe || iBlockedThem);
}

$('request-accept-btn').addEventListener('click', async () => {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;
  try {
    await api(`/api/conversations/${convo.id}/accept`, { method: 'POST' });
    convo.status = 'accepted';
    updateRequestBar(convo);
    updateCallButtons(convo);   // calling opens up once the request is accepted
    toast('Request accepted.');
  } catch (err) {
    toast(err.message, true);
  }
});

$('request-decline-btn').addEventListener('click', async () => {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;
  if (!confirm(`Decline this request from ${convo.peer.displayName}?`)) return;
  try {
    await api(`/api/conversations/${convo.id}/decline`, { method: 'POST' });
    state.conversations.delete(convo.id);
    state.messages.delete(convo.id);
    state.keys.delete(convo.id);
    state.activeId = null;
    $('chat-pane').classList.add('hidden');
    $('no-chat').classList.remove('hidden');
    renderChatList();
  } catch (err) {
    toast(err.message, true);
  }
});

/** Decrypts any reactions on the given messages that haven't been decrypted
 *  yet, caching by "messageId:userId" so re-renders don't re-decrypt. */
async function decryptReactionsFor(key, messages) {
  for (const m of messages) {
    for (const r of m.reactions || []) {
      const cacheKey = `${m.id}:${r.userId}`;
      if (state.reactionPlaintext.has(cacheKey)) continue;
      try {
        state.reactionPlaintext.set(cacheKey, await decryptText(key, r.ciphertext, r.iv));
      } catch {
        state.reactionPlaintext.set(cacheKey, null);
      }
    }
  }
}

async function startChatWith(userId) {
  try {
    const { conversation } = await api('/api/conversations/direct', {
      method: 'POST',
      body: JSON.stringify({ userId }),
    });

    // Merge rather than overwrite — an existing chat already holds its history.
    if (!state.conversations.has(conversation.id)) {
      state.conversations.set(conversation.id, conversation);
      await refreshPresence();   // a brand-new contact: learn if they're online
    }

    $('search-input').value = '';
    state.searching = false;
    renderChatList();
    await openConversation(conversation.id);
  } catch (err) {
    toast(err.message, true);
  }
}

// ═══════════════════════════════════════════════════════════
// Rendering — sidebar
// ═══════════════════════════════════════════════════════════

function applyChatFilter(convos) {
  if (state.chatFilter.startsWith('label:')) {
    const label = state.labels.find((l) => l.id === state.chatFilter.slice(6));
    return label ? convos.filter((c) => label.conversationIds.includes(c.id)) : convos;
  }
  switch (state.chatFilter) {
    case 'unread':    return convos.filter((c) => c.unread > 0);
    case 'favorites': return convos.filter((c) => c.favorite);
    case 'groups':    return convos.filter((c) => c.kind === 'group');
    case 'private':   return convos.filter((c) => c.kind === 'direct');
    default:          return convos;
  }
}

/** Rebuilds the filter-tab row to include one tab per custom label, after
 *  the 5 built-in ones. The click handler on #chat-filter-tabs is
 *  delegated (registered once, below), so newly-added label tabs work
 *  with it automatically — nothing to rewire here. */
function renderChatFilterTabs() {
  const activeFilter = state.chatFilter;
  const builtIn = [
    ['all', 'All'], ['unread', 'Unread'], ['favorites', 'Favourites'],
    ['groups', 'Groups'], ['private', 'Private'],
  ].map(([key, label]) => `
    <button type="button" class="chat-filter-tab ${activeFilter === key ? 'active' : ''}" data-filter="${key}">${label}</button>
  `).join('');

  const labelTabs = state.labels.map((l) => `
    <button type="button" class="chat-filter-tab ${activeFilter === 'label:' + l.id ? 'active' : ''}"
            data-filter="label:${l.id}">${escapeHtml(l.name)}</button>
  `).join('');

  $('chat-filter-tabs').innerHTML = builtIn + labelTabs;
  updateFilterTabCounts();
}

const FILTER_EMPTY_HINT = {
  all: 'No conversations yet.<br>Search above to find someone.',
  unread: 'No unread chats.',
  favorites: 'No favourites yet.<br>Tap the star on a chat to add one.',
  groups: 'No group chats yet.',
  private: 'No private chats yet.<br>Search above to find someone.',
};

function updateFilterTabCounts() {
  const all = [...state.conversations.values()];
  const counts = {
    all: all.length,
    unread: all.filter((c) => c.unread > 0).length,
    favorites: all.filter((c) => c.favorite).length,
    groups: all.filter((c) => c.kind === 'group').length,
    private: all.filter((c) => c.kind === 'direct').length,
  };
  const labels = { all: 'All', unread: 'Unread', favorites: 'Favourites', groups: 'Groups', private: 'Private' };
  $('chat-filter-tabs').querySelectorAll('.chat-filter-tab').forEach((tab) => {
    const key = tab.dataset.filter;
    if (key.startsWith('label:')) {
      const label = state.labels.find((l) => 'label:' + l.id === key);
      if (!label) return;
      const n = all.filter((c) => label.conversationIds.includes(c.id)).length;
      tab.textContent = n > 0 ? `${label.name} ${n}` : label.name;
      return;
    }
    const n = counts[key];
    tab.textContent = n > 0 && key !== 'all' ? `${labels[key]} ${n}` : labels[key];
  });
}

function renderChatList() {
  updateFilterTabCounts();
  if (state.searching) return;

  const list = $('chat-list');
  const all = [...state.conversations.values()].sort((a, b) => {
    const at = a.lastMessage?.createdAt ?? 0;
    const bt = b.lastMessage?.createdAt ?? 0;
    return new Date(bt) - new Date(at);
  });
  const convos = F.archiveFilter(F.hideLocked(applyChatFilter(all)));   // locked chats behind the PIN; archived apart

  if (convos.length === 0) {
    list.innerHTML = F.archivedRowHtml() + (F.viewingArchived() ? '<div class="empty-hint">No archived chats.</div>'
      : F.lockedRowHtml() + `<div class="empty-hint">${FILTER_EMPTY_HINT[state.chatFilter]}</div>`);
    F.wireLockedRow(list);
    F.wireArchivedRow(list);
    return;
  }

  list.innerHTML = F.archivedRowHtml() + (F.viewingArchived() ? '' : F.lockedRowHtml()) + convos.map((c) => {
    const isGroup = c.kind === 'group';
    const entity = isGroup ? { displayName: c.title, avatarColor: c.avatarColor } : c.peer;
    const name = isGroup ? c.title : c.peer.displayName;
    const isOnline = !isGroup && state.online.has(c.peer.id);
    const mine = c.lastMessage?.senderId === state.me.id;

    const pendingForMe = !isGroup && c.status === 'pending' && c.requestedBy !== state.me.id;
    const pendingForThem = !isGroup && c.status === 'pending' && c.requestedBy === state.me.id;
    const preview = pendingForMe ? 'Message request'
      : pendingForThem ? 'Waiting for them to accept'
      : c.lastMessage ? previewText(c) : (isGroup ? 'No messages yet' : 'Say hello');
    const draftHtml = !pendingForMe ? F.draftPreviewHtml(c) : null;

    const chatLabels = state.labels.filter((l) => l.conversationIds.includes(c.id));
    const labelChips = chatLabels.length
      ? `<div class="chat-item-labels">${chatLabels.map((l) =>
          `<span class="chat-label-chip" style="background:${escapeAttr(l.color)}">${escapeHtml(l.name)}</span>`).join('')}</div>`
      : '';

    return `
      <div class="chat-item ${c.id === state.activeId ? 'active' : ''} ${pendingForMe ? 'is-request' : ''} ${state.selectedChatIds.has(c.id) ? 'selected' : ''}"
           data-id="${c.id}">
        ${state.chatSelectMode ? `<input type="checkbox" class="chat-item-checkbox" ${state.selectedChatIds.has(c.id) ? 'checked' : ''} data-select-id="${c.id}">` : ''}
        <div class="avatar" style="background:${escapeAttr(entity.avatarColor)}">
          ${avatarInner(entity, { dot: !isGroup, online: isOnline })}
        </div>
        <div class="body">
          <div class="row-1">
            <span class="name">${c.isAnnouncement ? '📢 ' : ''}${escapeHtml(name)}</span>
            <div class="row-1-right">
              <button type="button" class="fav-star ${c.favorite ? 'active' : ''}" data-fav-id="${c.id}"
                      title="${c.favorite ? 'Remove from Favourites' : 'Add to Favourites'}"
                      aria-label="Toggle favourite">
                <svg viewBox="0 0 24 24" fill="${c.favorite ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="2"
                     stroke-linecap="round" stroke-linejoin="round">
                  <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>
                </svg>
              </button>
              <span class="time">${c.lastMessage ? shortTime(c.lastMessage.createdAt) : ''}</span>
            </div>
          </div>
          <div class="row-2">
            <span class="preview">${draftHtml || `${c.muted ? '🔕 ' : ''}${c.disappearSeconds ? '<span class="preview-timer" title="Disappearing messages on">⏱</span>' : ''}${mine ? tickIcon(c.lastMessage, true) : ''}${escapeHtml(preview)}`}</span>
            ${c.joinRequests > 0 ? `<span class="badge join-badge" title="Asking to join">+${c.joinRequests}</span>` : ''}
            ${c.unread > 0 ? `<span class="badge">${c.unread > 99 ? '99+' : c.unread}</span>` : ''}
          </div>
          ${labelChips}
        </div>
      </div>`;
  }).join('');

  F.wireLockedRow(list);
  F.wireArchivedRow(list);
  list.querySelectorAll('.chat-item').forEach((el) => {
    el.addEventListener('click', () => {
      if (state.chatSelectMode) toggleChatSelected(el.dataset.id);
      else openConversation(el.dataset.id);
    });
  });
  list.querySelectorAll('.chat-item-checkbox').forEach((el) => {
    el.addEventListener('click', (e) => e.stopPropagation());
    el.addEventListener('change', () => toggleChatSelected(el.dataset.selectId));
  });
  list.querySelectorAll('.fav-star').forEach((el) => {
    el.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleFavorite(el.dataset.favId);
    });
  });
}

async function toggleFavorite(id) {
  const convo = state.conversations.get(id);
  if (!convo) return;

  const next = !convo.favorite;
  convo.favorite = next; // optimistic — starring is low-stakes, not worth a loading state
  renderChatList();

  try {
    await api(`/api/conversations/${id}/favorite`, {
      method: 'PATCH',
      body: JSON.stringify({ favorite: next }),
    });
  } catch (err) {
    convo.favorite = !next; // revert
    renderChatList();
    toast(err.message, true);
  }
}

$('chat-filter-tabs').addEventListener('click', (e) => {
  const tab = e.target.closest('.chat-filter-tab');
  if (!tab) return;
  $('chat-filter-tabs').querySelectorAll('.chat-filter-tab').forEach((t) => t.classList.remove('active'));
  tab.classList.add('active');
  state.chatFilter = tab.dataset.filter;
  renderChatList();
});

function previewText(c) {
  return previewFor(c.lastMessage);
}

function senderInfo(convo, senderId) {
  const members = state.groupMembers.get(convo.id) || [];
  return members.find((m) => m.id === senderId)
    || { displayName: 'Unknown', avatarColor: '#7A7C99' };
}

function renderSearchResults(users) {
  const list = $('chat-list');

  if (users.length === 0) {
    list.innerHTML = '<div class="empty-hint">Nobody matches that.</div>';
    return;
  }

  list.innerHTML = '<div class="list-label">People</div>' + users.map((u) => `
    <div class="chat-item" data-user="${escapeAttr(u.id)}">
      <div class="avatar" style="background:${escapeAttr(u.avatarColor)}">
        ${avatarInner(u, { dot: true, online: state.online.has(u.id) })}
      </div>
      <div class="body">
        <div class="row-1"><span class="name">${escapeHtml(u.displayName)}</span></div>
        <div class="row-2"><span class="preview">@${escapeHtml(u.username)} · ${escapeHtml(u.about)}</span></div>
      </div>
    </div>`).join('');

  list.querySelectorAll('.chat-item').forEach((el) => {
    el.addEventListener('click', () => startChatWith(el.dataset.user));
  });
}

// ═══════════════════════════════════════════════════════════
// Rendering — messages
// ═══════════════════════════════════════════════════════════

let renderedFor = { conversationId: null, ids: new Set() };

function renderMessages() {
  const box = $('messages');
  const list = state.messages.get(state.activeId) || [];
  const convo = state.conversations.get(state.activeId);
  const isGroup = convo?.kind === 'group';

  if (list.length === 0) {
    box.innerHTML = F.disappearingNoteHtml(convo) + '<div class="empty-hint">No messages yet — say something.</div>';
    return;
  }

  let html = F.disappearingNoteHtml(convo);
  let lastDay = null;

  // Only messages that weren't on screen before get the pop-in animation —
  // a vote, a tick or a reaction re-renders the list and must not make
  // every bubble fade in again (the whole chat would flicker).
  const firstPaint = renderedFor.conversationId !== state.activeId;
  if (firstPaint) renderedFor = { conversationId: state.activeId, ids: new Set() };
  const seenBefore = renderedFor.ids;

  list.forEach((m, i) => {
    const day = dayKey(m.createdAt);
    if (day !== lastDay) {
      html += `<div class="day-sep">${escapeHtml(dayLabel(m.createdAt))}</div>`;
      lastDay = day;
    }

    const mine = m.senderId === state.me.id;
    const prev = list[i - 1];
    const next = list[i + 1];

    // A "run" is consecutive messages from the same person within 5 minutes.
    // Only the last bubble of a run gets a tail and a timestamp.
    const firstOfRun = !prev || prev.senderId !== m.senderId ||
                       dayKey(prev.createdAt) !== day ||
                       (new Date(m.createdAt) - new Date(prev.createdAt)) > 300_000;
    const lastOfRun = !next || next.senderId !== m.senderId ||
                      dayKey(next.createdAt) !== day ||
                      (new Date(next.createdAt) - new Date(m.createdAt)) > 300_000;

    // In a group, "them" isn't one person — label the first bubble of each
    // incoming run with who sent it, WhatsApp-style.
    let senderLabel = '';
    if (isGroup && !mine && firstOfRun) {
      const sender = senderInfo(convo, m.senderId);
      senderLabel = `<div class="sender-label" style="color:${escapeAttr(sender.avatarColor)}">
                       ${escapeHtml(sender.displayName)}
                     </div>`;
    }

    html += `
      <div class="bubble-row ${mine ? 'me' : 'them'}
                  ${firstOfRun ? 'first-of-run' : ''} ${lastOfRun ? 'last-of-run' : ''}
                  ${state.msgSelectMode ? 'select-mode' : ''}" ${state.msgSelectMode ? `data-select-msg="${escapeAttr(m.id)}"` : ''}>
        ${senderLabel}
        <div class="bubble-select-row">
          ${state.msgSelectMode && !m.pending && !m.deleted
            ? `<input type="checkbox" class="bubble-select-check" ${state.selectedMessageIds.has(m.id) ? 'checked' : ''} data-select-check="${escapeAttr(m.id)}">`
            : ''}
          <div class="bubble ${mine ? 'me' : 'them'} ${m.pending ? 'pending' : ''} ${m.kind === 'poll' ? 'is-poll' : ''} ${F.isPinned(convo, m.id) ? 'is-pinned' : ''} ${firstPaint || seenBefore.has(m.id) ? 'seen' : ''}"
               data-id="${escapeAttr(m.id)}">
            ${bubbleActionsHtml(m, mine)}
            ${replyQuoteHtml(m)}
            ${bubbleBody(m)}
            ${reactionsHtml(m)}
            <div class="meta">
              ${F.isPinned(convo, m.id) ? '<span class="pinned-mark" title="Pinned">📌</span>' : ''}
              ${F.expiryMark(m)}
              ${m.editedAt ? `<button type="button" class="edited-tag" data-msg="${escapeAttr(m.id)}" title="See edit history">edited</button>` : ''}
              <span>${shortTime(m.createdAt)}</span>
              ${mine ? tickIcon(m) : ''}
            </div>
          </div>
        </div>
      </div>`;
  });

  // Keep the reader where they are (voting on an old poll, translating an
  // old message) — only follow to the bottom when they were already there
  // or a new message just arrived.
  const prevTop = box.scrollTop;
  const wasAtBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 120;
  const lastId = list[list.length - 1]?.id;
  const newArrival = lastId && !seenBefore.has(lastId);

  box.innerHTML = html;
  for (const m of list) renderedFor.ids.add(m.id);
  if (state.msgSelectMode) {
    box.querySelectorAll('.bubble-row.select-mode').forEach((row) => {
      row.addEventListener('click', () => toggleMessageSelected(row.dataset.selectMsg));
    });
    box.querySelectorAll('.bubble-select-check').forEach((cb) => {
      cb.addEventListener('click', (e) => e.stopPropagation());
      cb.addEventListener('change', () => toggleMessageSelected(cb.dataset.selectCheck));
    });
  } else {
    wireAttachments();
    wireInlineMedia();
    wireVoicePlayers();
    wireVoiceTranscribeButtons();
    wireContactCards();
    wireBubbleActions();
    wireReactionPills();
    wireReplyQuotes();
    F.wirePolls(box);
    F.wirePinButtons(box);
    F.wireViewOnce(box);
    F.wireTranslations(box);
  }
  box.scrollTop = (firstPaint || wasAtBottom || newArrival) ? box.scrollHeight : prevTop;
}

/** A short preview string for any message kind — used both for the reply
 *  quote strip and while composing a reply. */
function previewFor(m) {
  const plain = state.plaintext.get(m.id);
  if (plain === null || plain === undefined) return 'Encrypted message';
  switch (m.kind) {
    case 'poll':     return F.pollPreview(plain);
    case 'product':  return F.productPreview(plain);
    case 'file':
      if (typeof plain !== 'object') return 'Attachment';
      if (m.viewOnce || plain.viewOnce) return F.viewOncePreview(plain);
      if (plain.gif) return 'GIF';
      if (plain.sticker) return 'Sticker';
      return plain.name;
    case 'voice':    return '🎤 Voice message';
    case 'location': return '📍 Location';
    case 'contact':  return `👤 ${typeof plain === 'object' ? plain.name : 'Contact'}`;
    default:         return typeof plain === 'string' ? F.textOf(plain) : 'Message';
  }
}

function replyQuoteHtml(m) {
  if (!m.replyToId) return '';

  const list = state.messages.get(state.activeId) || [];
  const original = list.find((x) => x.id === m.replyToId);
  if (!original) {
    return `<div class="reply-quote"><div class="reply-quote-text">Original message</div></div>`;
  }

  const convo = state.conversations.get(state.activeId);
  const senderName = original.senderId === state.me.id ? 'You'
    : convo?.kind === 'group' ? senderInfo(convo, original.senderId).displayName
    : convo?.peer?.displayName || '';

  return `
    <div class="reply-quote" data-target="${escapeAttr(original.id)}">
      <div class="reply-quote-name">${escapeHtml(senderName)}</div>
      <div class="reply-quote-text">${escapeHtml(original.deleted ? 'This message was deleted' : previewFor(original))}</div>
    </div>`;
}

/** Hover toolbar — react/reply always, edit (text, own messages) and delete
 *  (own messages) conditionally. Hidden entirely for pending/deleted bubbles. */
function bubbleActionsHtml(m, mine) {
  if (m.pending || m.deleted) return '';

  const starred = state.starredIds.has(m.id);
  const viewOnce = m.viewOnce || state.plaintext.get(m.id)?.viewOnce;
  return `
    <div class="bubble-actions">
      <button type="button" class="bubble-action-btn star-btn${starred ? ' active' : ''}" data-msg="${escapeAttr(m.id)}" title="${starred ? 'Unstar' : 'Star'}">${iconStar()}</button>
      <button type="button" class="bubble-action-btn react-btn" data-msg="${escapeAttr(m.id)}" title="React">${iconSmile()}</button>
      <button type="button" class="bubble-action-btn reply-btn" data-msg="${escapeAttr(m.id)}" title="Reply">${iconReply()}</button>
      ${F.privateReplyButtonHtml(m, state.conversations.get(state.activeId), mine)}
      ${F.pinButtonHtml(m)}
      ${F.translateButtonHtml(m)}
      ${viewOnce ? '' : `<button type="button" class="bubble-action-btn forward-btn" data-msg="${escapeAttr(m.id)}" title="Forward">${iconForward()}</button>`}
      ${mine && m.kind === 'text'
        ? `<button type="button" class="bubble-action-btn edit-btn" data-msg="${escapeAttr(m.id)}" title="Edit">${iconEdit()}</button>`
        : ''}
      <button type="button" class="bubble-action-btn delete-btn" data-msg="${escapeAttr(m.id)}" title="Delete">${iconTrash()}</button>
    </div>`;
}

function reactionsHtml(m) {
  if (!m.reactions || m.reactions.length === 0) return '';

  const counts = new Map(); // emoji -> { count, mine }
  for (const r of m.reactions) {
    const emoji = state.reactionPlaintext.get(`${m.id}:${r.userId}`);
    if (!emoji) continue;
    if (!counts.has(emoji)) counts.set(emoji, { count: 0, mine: false });
    const entry = counts.get(emoji);
    entry.count++;
    if (r.userId === state.me.id) entry.mine = true;
  }
  if (counts.size === 0) return '';

  return `<div class="reaction-row">${[...counts.entries()].map(([emoji, { count, mine }]) => `
    <button type="button" class="reaction-pill ${mine ? 'mine' : ''}"
            data-msg="${escapeAttr(m.id)}" data-emoji="${emoji}">${emoji} ${count}</button>
  `).join('')}</div>`;
}

function bubbleBody(m) {
  if (m.deleted) {
    return `<div class="text deleted-text">This message was deleted</div>`;
  }

  const plain = state.plaintext.get(m.id);

  if (plain === null || plain === undefined) {
    return `<div class="text" style="opacity:.6;font-style:italic">
              Can't decrypt this message
            </div>`;
  }

  if (m.kind === 'poll') return F.pollBody(m, plain);
  if (m.kind === 'product') return F.productBody(m, plain);
  if (m.kind === 'auto') return F.autoBody(m);

  if (m.kind === 'file') {
    if (m.viewOnce || plain.viewOnce) return F.viewOnceBody(m, plain);
    // Stickers and GIFs render inline (small, worth eager-decrypting) with no
    // bubble chrome — see wireInlineMedia().
    if (plain.sticker || plain.gif) {
      return `
        <div class="inline-media ${plain.gif ? 'is-gif' : 'is-sticker'}"
             data-file="${escapeAttr(m.filePath)}" data-msg="${escapeAttr(m.id)}">
          <span class="inline-media-ph">${plain.gif ? 'GIF' : '🖼'}</span>
        </div>`;
    }
    const isImage = (plain.mime || '').startsWith('image/');
    return `
      <div class="attach" data-file="${escapeAttr(m.filePath)}" data-msg="${escapeAttr(m.id)}">
        <div class="attach-icon">
          ${isImage ? iconImage() : iconFile()}
        </div>
        <div class="attach-info">
          <div class="attach-name">${escapeHtml(plain.name)}</div>
          <div class="attach-size">${formatBytes(plain.size)} · tap to open</div>
        </div>
      </div>`;
  }

  if (m.kind === 'voice') {
    return `
      <div class="voice-block">
        <div class="voice-player" data-file="${escapeAttr(m.filePath)}" data-msg="${escapeAttr(m.id)}">
          <button class="voice-play-btn" aria-label="Play voice note">${iconPlay()}</button>
          <canvas class="voice-wave" width="180" height="34"></canvas>
          <span class="voice-time">${formatBytes(plain.size)}</span>
          <button class="voice-speed-btn" type="button" title="Playback speed">${F.voiceSpeedLabel()}</button>
          <button class="voice-transcribe-btn" aria-label="Convert to text" title="Convert to text">${iconTextConvert()}</button>
        </div>
        <div class="voice-transcript hidden"></div>
      </div>`;
  }

  if (m.kind === 'location') {
    const url = `https://www.openstreetmap.org/?mlat=${plain.lat}&mlon=${plain.lng}#map=16/${plain.lat}/${plain.lng}`;
    return `
      <a class="location-card" href="${escapeAttr(url)}" target="_blank" rel="noopener noreferrer">
        <div class="attach-icon">${iconPin()}</div>
        <div class="attach-info">
          <div class="attach-name">Location</div>
          <div class="attach-size">${plain.lat.toFixed(5)}, ${plain.lng.toFixed(5)} · open map</div>
        </div>
      </a>`;
  }

  if (m.kind === 'contact') {
    return `
      <div class="contact-card" data-phone="${escapeAttr(plain.phone)}">
        <div class="attach-icon">${iconContact()}</div>
        <div class="attach-info">
          <div class="attach-name">${escapeHtml(plain.name)}</div>
          <div class="attach-size">${escapeHtml(plain.phone)}</div>
        </div>
        <button class="copy-contact-btn" aria-label="Copy number">${iconCopy()}</button>
      </div>`;
  }

  const pr = F.splitPrivateReply(plain);
  if (pr) {
    return `${F.privateQuoteHtml(pr.quote)}<div class="text">${linkify(escapeHtml(pr.text))}</div>${F.translationHtml(m)}`;
  }
  if (typeof plain === 'string' && isJumboEmoji(plain)) {
    return `<div class="text jumbo">${escapeHtml(plain)}</div>`;
  }
  return `<div class="text">${F.highlightEveryone(linkify(escapeHtml(plain)), m)}</div>${F.translationHtml(m)}`;
}

/** True for a message that's nothing but a handful of emoji — rendered big
 *  and bubble-less, WhatsApp-style. Allows emoji, skin-tone modifiers, the
 *  variation selector, ZWJ, keycap combiner, regional-indicator flags. */
function isJumboEmoji(s) {
  const t = s.replace(/\s+/g, '');
  if (!t || [...t].length > 8) return false;
  const leftover = t
    .replace(/\p{Extended_Pictographic}/gu, '')
    .replace(/[️‍⃣\u{1F3FB}-\u{1F3FF}\u{1F1E6}-\u{1F1FF}]/gu, '');
  return leftover.length === 0;
}

/** Stickers and GIFs decrypt eagerly on render (they're small) and swap their
 *  placeholder for the image. Object URLs are cached per message id. */
const inlineMediaUrls = new Map();
function wireInlineMedia() {
  document.querySelectorAll('.inline-media').forEach(async (el) => {
    if (el.dataset.done) return;
    el.dataset.done = '1';
    const msgId = el.dataset.msg;
    const meta = state.plaintext.get(msgId);
    if (!meta) return;

    const swap = (url) => {
      const img = document.createElement('img');
      img.src = url;
      img.alt = meta.gif ? 'GIF' : 'Sticker';
      img.addEventListener('click', () => showLightbox(url));
      el.replaceChildren(img);
    };

    if (inlineMediaUrls.has(msgId)) { swap(inlineMediaUrls.get(msgId)); return; }

    try {
      const key = state.keys.get(state.activeId);
      const blob = await getDecryptedMediaBlob(el.dataset.file, key, meta.blobIv, meta.mime || 'image/png');
      const url = URL.createObjectURL(blob);
      inlineMediaUrls.set(msgId, url);
      swap(url);
    } catch {
      el.querySelector('.inline-media-ph')?.replaceChildren(document.createTextNode('⚠'));
    }
  });
}

/**
 * Attachments are fetched and decrypted on demand rather than eagerly — a thread
 * with fifty images shouldn't pull fifty blobs on open.
 */
function wireAttachments() {
  document.querySelectorAll('.attach').forEach((el) => {
    el.addEventListener('click', async () => {
      const msgId = el.dataset.msg;
      const meta = state.plaintext.get(msgId);
      if (!meta) return;

      const info = el.querySelector('.attach-size');
      const restore = info.textContent;
      info.textContent = 'Decrypting…';

      try {
        const key = state.keys.get(state.activeId);
        const blob = await getDecryptedMediaBlob(el.dataset.file, key, meta.blobIv, meta.mime);
        const url = URL.createObjectURL(blob);

        if ((meta.mime || '').startsWith('image/')) {
          showLightbox(url);
        } else {
          const a = document.createElement('a');
          a.href = url;
          a.download = meta.name;
          a.click();
          setTimeout(() => URL.revokeObjectURL(url), 30_000);
        }
        info.textContent = restore;
      } catch (err) {
        info.textContent = restore;
        toast(err.message, true);
      }
    });
  });
}

function tickIcon(m, small = false) {
  if (!m) return '';
  if (m.pending) {
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
                 stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>`;
  }

  const read = Boolean(m.readAt);
  const delivered = Boolean(m.deliveredAt) || read;

  if (!delivered) {
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"
                 stroke-linecap="round" stroke-linejoin="round"><path d="m4 13 4.5 4.5L20 6"/></svg>`;
  }

  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"
               stroke-linecap="round" stroke-linejoin="round"
               class="${read ? 'read' : ''}">
            <path d="m1 13 4.5 4.5L17 6"/><path d="m8 15.6 1.9 1.9L21.4 6"/>
          </svg>`;
}

function iconImage() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="3" y="3" width="18" height="18" rx="2"/>
            <circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg>`;
}

function iconFile() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/>
            <path d="M14 2v6h6"/></svg>`;
}

function iconPlay() {
  return `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>`;
}

function iconPause() {
  return `<svg viewBox="0 0 24 24" fill="currentColor">
            <rect x="6" y="5" width="4" height="14"/><rect x="14" y="5" width="4" height="14"/></svg>`;
}

function iconDownload() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 20h16"/></svg>`;
}

function iconTextConvert() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 7V5a1 1 0 0 1 1-1h14a1 1 0 0 1 1 1v2"/>
            <line x1="9" y1="20" x2="15" y2="20"/><line x1="12" y1="4" x2="12" y2="20"/></svg>`;
}

function iconPin() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z"/><circle cx="12" cy="10" r="3"/></svg>`;
}

function iconContact() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>`;
}

function iconCopy() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="9" y="9" width="12" height="12" rx="2"/>
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>`;
}

function iconStar() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
               stroke-linecap="round" stroke-linejoin="round">
            <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>`;
}

function iconSmile() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10"/><path d="M8 14s1.5 2 4 2 4-2 4-2"/>
            <line x1="9" y1="9" x2="9.01" y2="9"/><line x1="15" y1="9" x2="15.01" y2="9"/></svg>`;
}

function iconReply() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <polyline points="9 17 4 12 9 7"/><path d="M20 18v-2a4 4 0 0 0-4-4H4"/></svg>`;
}

function iconEdit() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/>
            <path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>`;
}

function iconTrash() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"/>
            <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            <path d="M10 11v6"/><path d="M14 11v6"/></svg>`;
}

function iconForward() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <polyline points="15 4 20 9 15 14"/>
            <path d="M4 20v-4a4 4 0 0 1 4-4h12"/></svg>`;
}

/**
 * Voice bubbles decrypt and decode lazily on first play, same pattern as
 * wireAttachments() — a thread full of voice notes shouldn't pull every
 * blob on open.
 */
function wireVoicePlayers() {
  document.querySelectorAll('.voice-player').forEach((el) => {
    const btn = el.querySelector('.voice-play-btn');
    const canvas = el.querySelector('.voice-wave');
    const timeLabel = el.querySelector('.voice-time');
    void timeLabel;
    el.querySelector('.voice-speed-btn')?.addEventListener('click', (e) => { e.stopPropagation(); F.cycleSpeed(); });

    // One player for the whole app (see features/chat3.js): speed control,
    // a mini-player, and it keeps playing while you scroll or switch chats.
    btn.addEventListener('click', async () => {
      const msgId = el.dataset.msg;
      const conversationId = state.activeId;
      const convo = state.conversations.get(conversationId);
      const m = (state.messages.get(conversationId) || []).find((x) => x.id === msgId);
      const who = m?.senderId === state.me.id ? 'You'
        : convo?.kind === 'group' ? senderInfo(convo, m?.senderId).displayName : convo?.peer?.displayName || '';
      btn.disabled = true;
      try {
        await F.toggleVoice({
          msgId, conversationId,
          title: `🎤 ${who}${convo?.kind === 'group' ? ` · ${convo.title}` : ''}`,
          getUrl: async () => {
            const meta = state.plaintext.get(msgId);
            const key = state.keys.get(conversationId);
            const blob = await getDecryptedMediaBlob(el.dataset.file, key, meta.blobIv, meta.mime);
            await drawWaveform(canvas, new Uint8Array(await blob.arrayBuffer()));
            return URL.createObjectURL(blob);
          },
        });
      } catch (err) {
        toast(err.message, true);
      } finally {
        btn.disabled = false;
      }
    });
  });
  F.repaintVoice();
}

/**
 * "Convert to text" on a voice note — decrypts the same bytes the player
 * uses, then POSTs them to /api/voice/transcribe (a local Whisper service,
 * proxied through the Node server; see src/routes/voice.js). Separate from
 * the live-recording transcription — this works on a note already sent or
 * received, which the browser's own SpeechRecognition can't do after the
 * fact.
 */
// messageId -> transcript text (or a Promise while it's being made), so a
// transcript survives re-renders and is never requested twice.
const voiceTranscripts = new Map();

function wireVoiceTranscribeButtons() {
  document.querySelectorAll('.voice-transcribe-btn').forEach((btn) => {
    const block = btn.closest('.voice-block');
    const player = block.querySelector('.voice-player');
    const transcriptEl = block.querySelector('.voice-transcript');
    const msgId = player.dataset.msg;

    const show = (text) => {
      transcriptEl.classList.remove('hidden');
      transcriptEl.textContent = text;
    };

    const run = async () => {
      const meta = state.plaintext.get(msgId);
      if (!meta || msgId.startsWith('temp-')) return;
      const cached = voiceTranscripts.get(msgId);
      if (typeof cached === 'string') { show(cached); return; }

      btn.disabled = true;
      show('Transcribing…');
      const job = cached || (async () => {
        const key = state.keys.get(state.activeId);
        const blob = await getDecryptedMediaBlob(player.dataset.file, key, meta.blobIv, meta.mime);
        const form = new FormData();
        form.append('audio', blob, 'voice-note.webm');
        const { text } = await api('/api/voice/transcribe', { method: 'POST', body: form });
        return text?.trim() ? text.trim() : '(No speech detected.)';
      })();
      voiceTranscripts.set(msgId, job);
      try {
        const text = await job;
        voiceTranscripts.set(msgId, text);
        if (transcriptEl.isConnected) show(text);
        else if (state.activeId) renderMessages();   // re-rendered meanwhile — paint into the new bubble
      } catch (err) {
        voiceTranscripts.delete(msgId);
        if (transcriptEl.isConnected) show(`Could not transcribe: ${err.message}`);
      } finally {
        btn.disabled = false;
      }
    };

    btn.addEventListener('click', run);
    const cached = voiceTranscripts.get(msgId);
    if (typeof cached === 'string') show(cached);
    else if (F.prefs.get('autoTranscribe') && !cached) run();   // "Auto voice-to-text" setting
  });
}

/** Draws a static peaks waveform from decoded PCM. Falls back to a flat line
 *  if decoding fails (codec support varies slightly across browsers). */
async function drawWaveform(canvas, arrayBuffer) {
  const ctx = canvas.getContext('2d');
  const w = canvas.width, h = canvas.height;
  ctx.clearRect(0, 0, w, h);

  try {
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    const audioCtx = new AudioCtx();
    const audioBuffer = await audioCtx.decodeAudioData(arrayBuffer);
    const raw = audioBuffer.getChannelData(0);
    const barCount = 40;
    const step = Math.floor(raw.length / barCount) || 1;

    ctx.fillStyle = 'rgba(255,255,255,0.55)';
    for (let i = 0; i < barCount; i++) {
      let peak = 0;
      for (let j = 0; j < step; j++) {
        const v = Math.abs(raw[i * step + j] || 0);
        if (v > peak) peak = v;
      }
      const barH = Math.max(2, peak * h);
      ctx.fillRect(i * (w / barCount), (h - barH) / 2, w / barCount - 2, barH);
    }
    audioCtx.close();
  } catch {
    ctx.fillStyle = 'rgba(255,255,255,0.3)';
    ctx.fillRect(0, h / 2 - 1, w, 2);
  }
}

function wireContactCards() {
  document.querySelectorAll('.copy-contact-btn').forEach((btn) => {
    btn.addEventListener('click', async (e) => {
      e.stopPropagation();
      const phone = btn.closest('.contact-card').dataset.phone;
      try {
        await navigator.clipboard.writeText(phone);
        toast('Number copied.');
      } catch {
        toast('Could not copy — copy it manually.', true);
      }
    });
  });
}

// ── Bubble actions: react / reply / edit / delete ────────────

function wireBubbleActions() {
  document.querySelectorAll('.star-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); toggleStarMessage(btn.dataset.msg); });
  });
  document.querySelectorAll('.react-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); openReactionPicker(btn, btn.dataset.msg); });
  });
  document.querySelectorAll('.reply-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); startReply(btn.dataset.msg); });
  });
  document.querySelectorAll('button.edited-tag').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); F.openEditHistory(btn.dataset.msg); });
  });
  document.querySelectorAll('.private-reply-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); F.replyPrivately(btn.dataset.msg); });
  });
  document.querySelectorAll('.edit-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); startEdit(btn.dataset.msg); });
  });
  document.querySelectorAll('.forward-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); openForwardPicker(btn.dataset.msg); });
  });
  document.querySelectorAll('.delete-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); deleteMessage(btn.dataset.msg); });
  });
}

function wireReactionPills() {
  document.querySelectorAll('.reaction-pill').forEach((btn) => {
    btn.addEventListener('click', () => sendReaction(btn.dataset.msg, btn.dataset.emoji));
  });
}

function wireReplyQuotes() {
  document.querySelectorAll('.reply-quote[data-target]').forEach((el) => {
    el.addEventListener('click', () => jumpToMessage(el.dataset.target));
  });
}

/** Scrolls a message bubble into view and briefly flashes it — shared by
 *  reply-quote taps and search-result navigation. */
function jumpToMessage(id) {
  const target = document.querySelector(`.bubble[data-id="${id}"]`);
  if (!target) return false;
  target.scrollIntoView({ behavior: 'smooth', block: 'center' });
  target.classList.add('flash');
  setTimeout(() => target.classList.remove('flash'), 1200);
  return true;
}

const REACTION_EMOJI = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

function openReactionPicker(anchorEl, messageId) {
  closeReactionPicker();

  const popover = document.createElement('div');
  popover.className = 'reaction-picker';
  popover.id = 'reaction-picker';
  popover.innerHTML = REACTION_EMOJI.map((e) => `<button type="button" data-emoji="${e}">${e}</button>`).join('');
  document.body.appendChild(popover);

  const rect = anchorEl.getBoundingClientRect();
  const popRect = popover.getBoundingClientRect();
  popover.style.left = `${Math.max(8, rect.left - popRect.width / 2)}px`;
  popover.style.top = `${Math.max(8, rect.top - popRect.height - 8)}px`;

  popover.addEventListener('click', (e) => {
    e.stopPropagation();
    const emoji = e.target.closest('button')?.dataset.emoji;
    if (!emoji) return;
    sendReaction(messageId, emoji);
    closeReactionPicker();
  });

  setTimeout(() => document.addEventListener('click', closeReactionPicker, { once: true }), 0);
}

function closeReactionPicker() {
  document.getElementById('reaction-picker')?.remove();
}

async function sendReaction(messageId, emoji) {
  const convo = state.conversations.get(state.activeId);
  if (!convo || !canSendTo(convo)) return;

  const list = state.messages.get(state.activeId) || [];
  const msg = list.find((m) => m.id === messageId);
  if (!msg) return;

  const myExisting = (msg.reactions || []).find((r) => r.userId === state.me.id);
  const myEmoji = myExisting ? state.reactionPlaintext.get(`${messageId}:${state.me.id}`) : null;

  if (myEmoji === emoji) {
    sendSocket({ type: 'react', conversationId: state.activeId, messageId, remove: true });
    return;
  }

  try {
    const key = await keyFor(convo);
    const { ciphertext, iv } = await encryptText(key, emoji);
    sendSocket({ type: 'react', conversationId: state.activeId, messageId, ciphertext, iv });
  } catch (err) {
    toast(err.message, true);
  }
}

async function toggleStarMessage(messageId) {
  const wasStarred = state.starredIds.has(messageId);
  // Optimistic — starring is low-stakes, not worth a loading state.
  if (wasStarred) state.starredIds.delete(messageId); else state.starredIds.add(messageId);
  renderMessages();

  try {
    if (wasStarred) await api(`/api/messages/${messageId}/star`, { method: 'DELETE' });
    else await api(`/api/messages/${messageId}/star`, { method: 'POST' });
  } catch (err) {
    if (wasStarred) state.starredIds.add(messageId); else state.starredIds.delete(messageId);
    renderMessages();
    toast(err.message, true);
  }
}

async function openStarredMessagesPanel() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>⭐ Starred messages</h3>
      <div class="reminder-list" id="starred-list" style="margin-top:0; padding-top:0; border-top:none;"></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="starred-close">Close</button>
      </div>
    </div>`;
  document.body.appendChild(box);
  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#starred-close').addEventListener('click', close);

  async function load() {
    const list = box.querySelector('#starred-list');
    list.innerHTML = '<div class="empty-hint">Loading…</div>';
    try {
      const { starred } = await api('/api/messages/starred');
      if (starred.length === 0) {
        list.innerHTML = '<div class="empty-hint">No starred messages yet.</div>';
        return;
      }

      const items = await Promise.all(starred.map(async (m) => {
        const convo = state.conversations.get(m.conversationId);
        let text = '(unavailable)';
        const convoName = convo ? (convo.kind === 'group' ? convo.title : convo.peer?.displayName || 'Unknown') : 'Unknown chat';
        if (convo) {
          try {
            const key = await keyFor(convo);
            state.plaintext.set(m.id, await decryptBody(key, m));
            text = previewFor(m);
          } catch { text = '(could not decrypt)'; }
        }
        return { ...m, text, convoName };
      }));

      list.innerHTML = items.map((m) => `
        <div class="reminder-item starred-item" data-convo="${escapeAttr(m.conversationId)}" data-msg="${escapeAttr(m.id)}">
          <div class="reminder-item-emoji">⭐</div>
          <div class="reminder-item-body">
            <div class="reminder-item-content">${escapeHtml(m.text)}</div>
            <div class="reminder-item-when">${escapeHtml(m.convoName)} · ${dayLabel(m.createdAt)} at ${shortTime(m.createdAt)}</div>
          </div>
          <button type="button" class="icon-btn star-unstar-btn" data-msg="${escapeAttr(m.id)}" title="Unstar">${iconStar()}</button>
        </div>`).join('');

      list.querySelectorAll('.starred-item').forEach((el) => {
        el.addEventListener('click', async (e) => {
          if (e.target.closest('.star-unstar-btn')) return;
          const convoId = el.dataset.convo, msgId = el.dataset.msg;
          close();
          await openConversation(convoId);
          jumpToMessage(msgId);
        });
      });
      list.querySelectorAll('.star-unstar-btn').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          await toggleStarMessage(btn.dataset.msg);
          load();
        });
      });
    } catch (err) {
      list.innerHTML = `<div class="empty-hint">${escapeHtml(err.message)}</div>`;
    }
  }

  load();
}

function startReply(messageId) {
  const list = state.messages.get(state.activeId) || [];
  const msg = list.find((m) => m.id === messageId);
  if (!msg) return;

  const convo = state.conversations.get(state.activeId);
  const senderName = msg.senderId === state.me.id ? 'You'
    : convo?.kind === 'group' ? senderInfo(convo, msg.senderId).displayName
    : convo?.peer?.displayName || '';

  cancelEdit(); // editing and replying at once would be confusing — one at a time
  state.replyingTo = { id: messageId, senderId: msg.senderId, previewText: previewFor(msg), senderName };
  showReplyBar();
}

function showReplyBar() {
  if (!state.replyingTo) return;
  $('reply-bar-name').textContent = state.replyingTo.senderName;
  $('reply-bar-text').textContent = state.replyingTo.previewText;
  $('reply-bar').classList.remove('hidden');
  $('composer-input').focus();
}

function cancelReply() {
  state.replyingTo = null;
  $('reply-bar').classList.add('hidden');
}

$('reply-bar-cancel').addEventListener('click', cancelReply);

function startEdit(messageId) {
  const list = state.messages.get(state.activeId) || [];
  const msg = list.find((m) => m.id === messageId);
  if (!msg || msg.kind !== 'text' || msg.senderId !== state.me.id) return;

  const plain = state.plaintext.get(messageId);
  if (typeof plain !== 'string') return;

  cancelReply();
  state.editingId = messageId;
  input.value = plain;
  input.dispatchEvent(new Event('input'));
  input.focus();
  $('edit-bar').classList.remove('hidden');
}

function cancelEdit() {
  state.editingId = null;
  $('edit-bar').classList.add('hidden');
}

$('edit-bar-cancel').addEventListener('click', () => {
  cancelEdit();
  input.value = '';
  input.dispatchEvent(new Event('input'));
});

async function submitEdit() {
  const text = input.value.trim();
  const messageId = state.editingId;
  const conversationId = state.activeId;
  if (!text || !messageId || !conversationId) return cancelEdit();

  const convo = state.conversations.get(conversationId);

  input.value = '';
  input.style.height = 'auto';
  $('send-btn').disabled = true;
  cancelEdit();

  try {
    const key = await keyFor(convo);
    const { ciphertext, iv } = await encryptText(key, text);
    sendSocket({ type: 'edit-message', conversationId, messageId, ciphertext, iv });

    // Update local state optimistically — the 'message-edited' echo confirms
    // it, but there's no reason to wait on the round trip visually.
    state.plaintext.set(messageId, text);
    const list = state.messages.get(conversationId);
    const m = list?.find((x) => x.id === messageId);
    if (m) m.editedAt = new Date().toISOString();
    renderMessages();
  } catch (err) {
    toast(err.message, true);
  }
}

/** Opens the "Delete for me" / "Delete for everyone" choice — the latter
 *  only offered on your own messages, same rule WhatsApp uses (you can hide
 *  anyone's message from your own view, but only pull back one you sent). */
function deleteMessage(messageId) {
  if (!state.activeId) return;
  const list = state.messages.get(state.activeId) || [];
  const m = list.find((msg) => msg.id === messageId);
  if (!m) return;
  const mine = m.senderId === state.me.id;

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Delete message</h3>
      <div class="modal-choice-stack">
        <button type="button" class="btn-secondary" id="del-for-me">Delete for me</button>
        ${mine ? `<button type="button" class="btn-danger" id="del-for-everyone">Delete for everyone</button>` : ''}
        <button type="button" class="btn-secondary" id="del-cancel">Cancel</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#del-cancel').addEventListener('click', close);
  box.querySelector('#del-for-me').addEventListener('click', () => { close(); hideMessageForMe(messageId); });
  box.querySelector('#del-for-everyone')?.addEventListener('click', () => {
    close();
    sendSocket({ type: 'delete-message', conversationId: state.activeId, messageId });
  });
}

/** "Delete for me" — purely local: hides this message from just my own
 *  view (see message_hides in the schema). No WS frame — the other
 *  participant's copy is completely untouched, so there's nothing to
 *  broadcast. */
async function hideMessageForMe(messageId) {
  const conversationId = state.activeId;
  if (!conversationId) return;
  try {
    await api(`/api/messages/${messageId}/hide`, { method: 'POST' });
    removeMessage(conversationId, messageId);
    renderMessages();
    // The hidden message might have been this chat's last-message preview
    // in the sidebar — that's cached from the last conversation-list fetch,
    // not derived live from state.messages, so it needs a real refetch
    // (matching the server's own message_hides-aware preview query) rather
    // than just a local re-render to stop showing stale hidden text there.
    await loadConversations();
  } catch (err) {
    toast(err.message, true);
  }
}

/**
 * Forward — decrypt with the SOURCE conversation's key, re-encrypt with the
 * TARGET conversation's key, send as a normal new message. Text/location/
 * contact are just re-encrypted JSON/text; file/voice additionally have to
 * download+decrypt the original blob and re-upload it re-encrypted, since
 * the blob on disk is only ever readable under the conversation it was
 * originally sent to.
 */
function openForwardPicker(messageId) {
  if (!state.activeId) return;
  const sourceConvoId = state.activeId;
  const list = state.messages.get(sourceConvoId) || [];
  const m = list.find((msg) => msg.id === messageId);
  if (!m) return;

  // Not canSendTo() here — it toasts an error as a side effect, meant for
  // "you just tried to send," not for silently filtering a list before the
  // user has picked anything.
  const targets = [...state.conversations.values()]
    .filter((c) => c.id !== sourceConvoId
      && (c.kind === 'group' || c.status !== 'pending' || c.requestedBy === state.me.id));
  if (targets.length === 0) {
    toast('No other chat to forward this to yet.', true);
    return;
  }

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Forward message</h3>
      <div class="picker-list" id="forward-picker-list">
        ${targets.map((c) => {
          const label = c.kind === 'group' ? c.title : c.peer.displayName;
          const color = c.kind === 'group' ? c.avatarColor : c.peer.avatarColor;
          const entity = c.kind === 'group' ? { displayName: c.title, photoUrl: null } : c.peer;
          return `
            <label class="picker-row">
              <input type="checkbox" value="${escapeAttr(c.id)}">
              <div class="avatar sm" style="background:${escapeAttr(color)}">${avatarInner(entity)}</div>
              <span class="name">${escapeHtml(label)}</span>
            </label>`;
        }).join('')}
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="forward-cancel">Cancel</button>
        <button type="button" class="btn-primary" id="forward-send">Forward</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#forward-cancel').addEventListener('click', close);

  box.querySelector('#forward-send').addEventListener('click', async () => {
    const targetIds = [...box.querySelectorAll('#forward-picker-list input:checked')].map((el) => el.value);
    if (targetIds.length === 0) { toast('Pick at least one chat to forward to.', true); return; }

    const btn = box.querySelector('#forward-send');
    btn.disabled = true;
    btn.textContent = 'Forwarding…';
    // Each target forwards independently — one failing (e.g. a group whose
    // key can't be resolved) shouldn't stop the message reaching the rest.
    const outcomes = await Promise.allSettled(targetIds.map((id) => forwardMessageTo(m, sourceConvoId, id)));
    const failed = outcomes.filter((o) => o.status === 'rejected').length;

    if (failed === 0) {
      close();
      toast(targetIds.length === 1 ? 'Message forwarded.' : `Forwarded to ${targetIds.length} chats.`);
    } else if (failed < targetIds.length) {
      close();
      toast(`Forwarded to ${targetIds.length - failed} of ${targetIds.length} chats — some failed.`, true);
    } else {
      toast('Could not forward the message.', true);
      btn.disabled = false;
      btn.textContent = 'Forward';
    }
  });
}

async function forwardMessageTo(sourceMsg, sourceConvoId, targetConvoId) {
  const sourceConvo = state.conversations.get(sourceConvoId);
  const targetConvo = state.conversations.get(targetConvoId);
  if (!sourceConvo || !targetConvo) throw new Error('Conversation not found.');

  const sourceKey = await keyFor(sourceConvo);
  const targetKey = await keyFor(targetConvo);
  const kind = sourceMsg.kind;
  const decoded = await decryptBody(sourceKey, sourceMsg);

  const tempId = 'temp-' + crypto.randomUUID();
  const optimistic = { id: tempId, senderId: state.me.id, kind, createdAt: new Date().toISOString(), pending: true };
  state.plaintext.set(tempId, decoded);
  pushMessage(targetConvoId, optimistic);
  if (targetConvoId === state.activeId) renderMessages();

  try {
    if (kind === 'file' || kind === 'voice') {
      const res = await fetch(apiUrl(`/api/upload/${sourceMsg.filePath}`), { credentials: 'include' });
      if (!res.ok) throw new Error('Could not fetch the original file.');
      const bytes = await decryptFileBytes(sourceKey, await res.arrayBuffer(), decoded.blobIv);
      const file = new File([bytes], decoded.name || 'file', { type: decoded.mime || 'application/octet-stream' });

      // Forward everything the original meta carried (waveform, caption,
      // duration, whatever) except the fields encryptFile regenerates
      // itself from the File object or a fresh IV.
      const extra = { ...decoded };
      delete extra.name; delete extra.mime; delete extra.size; delete extra.blobIv;

      const encoded = await encryptFile(targetKey, file, extra);
      const form = new FormData();
      form.append('blob', encoded.blob, 'blob');
      const { filePath, fileSize } = await api('/api/upload', { method: 'POST', body: form });

      sendSocket({
        type: 'send', conversationId: targetConvoId, ciphertext: encoded.ciphertext, iv: encoded.iv,
        kind, filePath, fileSize, tempId,
      });
    } else if (kind === 'text') {
      const { ciphertext, iv } = await encryptText(targetKey, decoded);
      sendSocket({ type: 'send', conversationId: targetConvoId, ciphertext, iv, kind, tempId });
    } else {
      // location / contact — plain JSON payload, no blob involved.
      const { ciphertext, iv } = await encryptText(targetKey, JSON.stringify(decoded));
      sendSocket({ type: 'send', conversationId: targetConvoId, ciphertext, iv, kind, tempId });
    }
  } catch (err) {
    removeMessage(targetConvoId, tempId);
    if (targetConvoId === state.activeId) renderMessages();
    throw err;
  }
}

// ═══════════════════════════════════════════════════════════
// Sending
// ═══════════════════════════════════════════════════════════

const input = $('composer-input');

input.addEventListener('input', () => {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 132) + 'px';
  $('send-btn').disabled = input.value.trim().length === 0;
  signalTyping();
  refreshComposerSuggestions();
  if (!state.editingId) F.setDraft(state.activeId, input.value);   // keep a draft per chat
  F.quickReplyInput(input);                                         // "/shortcut" popup
  F.onComposerMention(input);                                       // "@everyone" for group admins
});

input.addEventListener('keydown', (e) => {
  if (F.quickReplyKeydown(e, input)) return;   // the "/" popup took the key
  // Enter sends (or submits an edit); Shift+Enter makes a new line. Escape
  // backs out of an in-progress edit without sending anything.
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    submitComposer();
  } else if (e.key === 'Escape' && state.editingId) {
    cancelEdit();
    input.value = '';
    input.dispatchEvent(new Event('input'));
  } else if ((e.key === 'Tab' || (e.key === 'ArrowRight' && atInputEnd()))
             && composerCompletion) {
    // Tab / → at the end of the line accepts the grey suggestion.
    e.preventDefault();
    acceptComposerCompletion();
  }
});

function atInputEnd() {
  return input.selectionStart === input.value.length && input.selectionStart === input.selectionEnd;
}

// ═══════════════════════════════════════════════════════════
// Smart compose — on-device suggestions + completion
// ═══════════════════════════════════════════════════════════
// A tiny personal model built from YOUR past messages (already cached on this
// device — see localstore.js), plus a small set of context-aware quick
// replies. Nothing is sent anywhere; it just learns how you actually write.

const smartModel = { bigram: new Map(), phrases: new Map(), starters: new Map(), built: false, seeded: false };
let composerCompletion = '';   // the grey continuation currently offered

function tokenize(s) {
  return (s.toLowerCase().match(/[\p{L}\p{N}']+|[.!?,]/gu) || []);
}

// Common everyday phrases so completion works from the very first message,
// before there's any personal history. Personal usage stacks on top and
// quickly outweighs these.
const SEED_PHRASES = [
  'how are you', 'how are you doing', "how's it going", 'how was your day',
  'what are you doing', 'what happened', 'what time', 'what about you',
  'where are you', 'where are you now', 'are you there', 'are you free',
  'are you coming', 'are you okay', 'are you busy', 'are you home',
  'see you tomorrow', 'see you soon', 'see you later', 'talk to you later',
  'talk soon', 'call you later', "i'll call you", "i'll be there",
  "i'll let you know", "i'll check and let you know", 'let me know',
  'let me check', 'let me know when you are free', 'on my way',
  'almost there', 'be there in 5 minutes', 'give me a minute',
  'good morning', 'good afternoon', 'good evening', 'good night',
  'have a good day', 'have a nice day', 'take care',
  'thank you', 'thank you so much', 'thanks a lot', 'no problem',
  'no worries', 'sounds good', 'that works for me', 'works for me',
  "i don't know", "i'm not sure", "i don't think so", 'i think so',
  "i'm on it", "i'm coming", "i'm here", "i'm busy right now",
  'can you send me', 'can you please', 'can you call me', 'could you please',
  'please call me', 'please let me know', 'did you get my message',
  'did you see', 'did you eat', 'have you eaten',
  'happy birthday', 'congratulations', 'well done', 'good luck',
  'love you', 'love you too', 'miss you', 'i miss you',
  'nice to meet you', 'it was nice talking to you',
];
// Frequent next-words for standalone leading words.
const NEXT_WORD = {
  how: ['are', 'is', 'was', 'about', 'much', 'many', 'long', 'come', 'do'],
  what: ['are', 'is', 'time', 'happened', 'about', 'do', 'did', 'can'],
  where: ['are', 'is', 'do', 'did', 'can', 'have'],
  when: ['are', 'is', 'will', 'do', 'can', 'did'],
  why: ['are', 'is', 'did', 'do', "don't", 'not'],
  are: ['you', 'we', 'they', "n't"],
  is: ['it', 'that', 'this', 'everything', 'she', 'he'],
  can: ['you', 'i', 'we', 'they'],
  could: ['you', 'we', 'i'],
  would: ['you', 'love', 'like'],
  will: ['you', 'be', 'call', 'do', 'let'],
  you: ['are', 'doing', 'there', 'free', 'okay', 'coming', 'home', 'busy', 'want'],
  i: ['am', 'will', "don't", 'think', 'have', 'can', 'was', 'need', "'m", "'ll"],
  we: ['are', 'can', 'will', 'should', 'need'],
  let: ['me', 'us'],
  me: ['know', 'a', 'the', 'when', 'if'],
  see: ['you'],
  talk: ['to', 'later', 'soon'],
  thank: ['you'],
  good: ['morning', 'night', 'afternoon', 'evening', 'idea', 'luck', 'to'],
  please: ['call', 'let', 'send', 'help', 'come'],
  did: ['you', 'it', 'he', 'she', 'they'],
  have: ['you', 'a', 'to', 'been'],
  on: ['my', 'the', 'it'],
  in: ['a', 'the', '5', '10', 'few'],
  call: ['you', 'me', 'him', 'her', 'back'],
  going: ['to', 'home', 'out', 'now'],
  want: ['to', 'a', 'some', 'me'],
  need: ['to', 'a', 'some', 'help', 'you'],
};

function seedSmartModel() {
  if (smartModel.seeded) return;
  smartModel.seeded = true;
  for (const phrase of SEED_PHRASES) {
    const k = phrase.toLowerCase();
    smartModel.phrases.set(k, { count: 3, value: phrase });
    const words = tokenize(phrase);
    for (let i = 0; i < words.length - 1; i++) {
      if (!smartModel.bigram.has(words[i])) smartModel.bigram.set(words[i], new Map());
      const nxt = smartModel.bigram.get(words[i]);
      nxt.set(words[i + 1], (nxt.get(words[i + 1]) || 0) + 3);
    }
  }
  for (const [w, nexts] of Object.entries(NEXT_WORD)) {
    if (!smartModel.bigram.has(w)) smartModel.bigram.set(w, new Map());
    const m = smartModel.bigram.get(w);
    nexts.forEach((n, i) => m.set(n, (m.get(n) || 0) + (nexts.length - i) + 2));
  }
}

async function buildSmartModel() {
  seedSmartModel();
  if (smartModel.built) return;
  smartModel.built = true;
  try {
    const mine = [];
    for (const convo of state.conversations.values()) {
      const rows = await localStore.getConversationMessages(convo.id);
      for (const m of rows) {
        if (m.senderId === state.me.id && m.kind === 'text' && typeof m._body === 'string') {
          mine.push(m._body);
        }
      }
    }
    for (const text of mine) {
      const trimmed = text.trim();
      if (trimmed && trimmed.length <= 80) bump(smartModel.phrases, trimmed.toLowerCase(), trimmed);
      const words = tokenize(trimmed);
      if (words.length >= 1) bump(smartModel.starters, words.slice(0, 2).join(' '));
      for (let i = 0; i < words.length - 1; i++) {
        const key = words[i];
        if (!smartModel.bigram.has(key)) smartModel.bigram.set(key, new Map());
        const nxt = smartModel.bigram.get(key);
        nxt.set(words[i + 1], (nxt.get(words[i + 1]) || 0) + 1);
      }
    }
  } catch { /* no history yet — suggestions just stay quiet */ }
}

function bump(map, key, value) {
  const cur = map.get(key);
  if (cur) cur.count++;
  else map.set(key, { count: 1, value: value ?? key });
}

/** Learn from a message the moment you send it, so it adapts live. */
function learnFromSent(text) {
  const trimmed = (text || '').trim();
  if (!trimmed || trimmed.length > 200) return;
  if (trimmed.length <= 80) bump(smartModel.phrases, trimmed.toLowerCase(), trimmed);
  const words = tokenize(trimmed);
  for (let i = 0; i < words.length - 1; i++) {
    if (!smartModel.bigram.has(words[i])) smartModel.bigram.set(words[i], new Map());
    const nxt = smartModel.bigram.get(words[i]);
    nxt.set(words[i + 1], (nxt.get(words[i + 1]) || 0) + 1);
  }
}

/** Predict a continuation for the half-typed message, or '' if unsure.
 *  Returns the exact text to append to the input. */
function predictCompletion(raw) {
  const t = raw.trimEnd();
  if (!t || t.length < 2 || /[.!?]$/.test(t)) return '';
  const low = t.toLowerCase();
  const endsWithSpace = /\s$/.test(raw);

  // 1. A phrase you (or the seed set) use — you're re-typing its start.
  let best = null;
  for (const p of smartModel.phrases.values()) {
    if (p.count >= 2 && p.value.length > t.length && p.value.toLowerCase().startsWith(low)) {
      if (!best || p.count > best.count) best = p;
    }
  }
  if (best) {
    const rest = best.value.slice(t.length);
    return endsWithSpace ? rest.replace(/^\s+/, '') : rest;   // input already has the space
  }

  // 2. Word-by-word via the bigram model.
  const words = low.match(/[\p{L}\p{N}']+/gu) || [];
  if (!words.length) return '';

  let head = '';                       // the partial word being finished
  let cursor;                          // predict the word AFTER this one
  if (endsWithSpace) {
    cursor = words[words.length - 1];
  } else {
    head = words[words.length - 1];
    cursor = words[words.length - 2];
    if (smartModel.bigram.has(head)) { cursor = head; head = ''; }  // head is a full word
  }
  if (!cursor) return '';

  const pieces = [];

  // Finish the current partial word first, if there is one.
  if (head) {
    const nxt = smartModel.bigram.get(cursor);
    if (!nxt) return '';
    let w = '', wn = 0;
    for (const [cand, n] of nxt) {
      if (cand.length > head.length && cand.startsWith(head) && n > wn && !/[.!?,]/.test(cand)) { w = cand; wn = n; }
    }
    if (!w || wn < 3) return '';
    pieces.push(w.slice(head.length));
    cursor = w;
  }

  // Then chain forward a couple more words.
  for (let step = 0; step < 3; step++) {
    const nxt = smartModel.bigram.get(cursor);
    if (!nxt) break;
    let w = '', wn = 0;
    for (const [cand, n] of nxt) if (n > wn && !/[.!?,]/.test(cand)) { w = cand; wn = n; }
    if (!w || wn < 3) break;
    pieces.push((pieces.length === 0 && endsWithSpace) ? w : ' ' + w);
    cursor = w;
  }

  return pieces.join('');
}

const QUICK_REPLIES = [
  { re: /\?\s*$/,                      say: ['Yes', 'No', 'Maybe'] },
  { re: /\b(thanks|thank you|thx|ty)\b/i, say: ['You’re welcome 🙂', 'Anytime', '👍'] },
  { re: /\b(ok|okay|k|fine|got it)\b/i,   say: ['👍', 'Great', 'Cool'] },
  { re: /\b(where are you|coming|reached|on the way)\b/i, say: ['On my way', 'Almost there', '5 mins'] },
  { re: /\b(hi|hello|hey|good morning|gm)\b/i, say: ['Hey! 👋', 'Hi', 'Hello'] },
  { re: /\b(call|calling|phone)\b/i,   say: ['Calling now', 'Call you in a bit', 'Can’t talk right now'] },
  { re: /\b(sorry|my bad|apolog)\b/i,  say: ['It’s okay', 'No worries', 'All good'] },
  { re: /\b(love you|miss you)\b/i,    say: ['❤️', 'Love you too', 'Miss you more'] },
  { re: /\b(congrat|well done|great job)\b/i, say: ['Thank you! 🙏', 'Thanks so much'] },
];

function quickRepliesFor(lastIncoming) {
  const t = (lastIncoming || '').trim();
  if (!t) return [];
  const out = [];
  for (const { re, say } of QUICK_REPLIES) if (re.test(t)) out.push(...say);
  // Fill up from your own most-used short messages.
  if (out.length < 3) {
    const top = [...smartModel.phrases.values()]
      .filter((p) => p.count >= 3 && p.value.length <= 30)
      .sort((a, b) => b.count - a.count)
      .map((p) => p.value);
    for (const p of top) { if (out.length >= 3) break; if (!out.includes(p)) out.push(p); }
  }
  return [...new Set(out)].slice(0, 3);
}

function lastIncomingText() {
  const list = state.messages.get(state.activeId) || [];
  for (let i = list.length - 1; i >= 0; i--) {
    const m = list[i];
    if (m.senderId === state.me.id) return null;        // I spoke last — no quick replies
    if (m.kind === 'text' && !m.deleted) {
      const p = state.plaintext.get(m.id);
      return typeof p === 'string' ? p : null;
    }
    if (!m.deleted) return null;
  }
  return null;
}

let suggestDebounce = null;
function refreshComposerSuggestions() {
  seedSmartModel();   // idempotent — makes completion work before history loads
  clearTimeout(suggestDebounce);
  suggestDebounce = setTimeout(renderComposerSuggestions, 120);
}

function renderComposerSuggestions() {
  const bar = $('composer-suggest');
  if (!bar) return;
  composerCompletion = '';
  bar.innerHTML = '';

  if (state.editingId || !state.activeId) { bar.classList.add('hidden'); return; }
  const typed = input.value;

  if (typed.trim().length >= 3) {
    const rest = predictCompletion(typed);
    if (rest && rest.trim()) {
      composerCompletion = rest;
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'suggest-chip suggest-complete';
      chip.innerHTML = `<span class="sc-dim">${escapeHtml(typed.slice(-24))}</span>${escapeHtml(rest)}<kbd>Tab</kbd>`;
      chip.addEventListener('click', acceptComposerCompletion);
      bar.appendChild(chip);
      bar.classList.remove('hidden');
      return;
    }
    bar.classList.add('hidden');
    return;
  }

  // Empty composer → context-aware quick replies to the last message, plus
  // the AI "Smart replies" chip.
  const fill = (r) => {
    input.value = r;
    input.focus();
    input.dispatchEvent(new Event('input'));
  };
  const lastIn = lastIncomingText();
  const replies = quickRepliesFor(lastIn);
  for (const r of replies) {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'suggest-chip';
    chip.textContent = r;
    chip.addEventListener('click', () => fill(r));
    bar.appendChild(chip);
  }
  if (lastIn) F.smartReplyChips(bar, fill);
  bar.classList.toggle('hidden', !bar.children.length);
}

function acceptComposerCompletion() {
  if (!composerCompletion) return;
  input.value = input.value + composerCompletion;
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
  input.dispatchEvent(new Event('input'));
}

function submitComposer() {
  if (state.editingId) submitEdit();
  else sendMessage();
}

$('send-btn').addEventListener('click', submitComposer);

/** True if I'm actually allowed to send into this conversation right now —
 *  the composer is supposed to already be swapped for an Accept/Decline bar
 *  when this would be false (see openConversation), so hitting this is a
 *  defense-in-depth check, not the primary UX. */
function canSendTo(convo) {
  if (convo.kind === 'direct' && convo.status === 'pending' && convo.requestedBy !== state.me.id) {
    toast('Accept the request before you can reply.', true);
    return false;
  }
  return true;
}

async function sendMessage(explicitText) {
  const fromComposer = explicitText == null;
  const text = (fromComposer ? input.value : explicitText).trim();
  if (!text || !state.activeId) return;

  const convo = state.conversations.get(state.activeId);
  if (!canSendTo(convo)) return;
  const conversationId = state.activeId;
  const replyToId = state.replyingTo?.id ?? null;

  if (fromComposer) {
    input.value = '';
    input.style.height = 'auto';
    $('send-btn').disabled = true;
    F.clearDraft(conversationId);
    F.hideQuickReplies();
    renderChatList();
  }
  F.maybePlayEffect(text);
  learnFromSent(text);
  refreshComposerSuggestions();
  stopTyping();
  cancelReply();

  // Optimistic bubble — it appears instantly and is swapped for the server's
  // copy when the 'sent' frame comes back.
  const tempId = 'temp-' + crypto.randomUUID();
  const mentionAll = F.iAmGroupAdmin(convo) && F.mentionsEveryone(text);
  const optimistic = {
    id: tempId, senderId: state.me.id, kind: 'text', replyToId, mentionAll,
    createdAt: new Date().toISOString(), pending: true,
  };
  const body = F.packPrivateReply(conversationId, text);   // "reply privately" quote, encrypted with it

  state.plaintext.set(tempId, body);
  pushMessage(conversationId, optimistic);
  renderMessages();

  try {
    const key = await keyFor(convo);
    const { ciphertext, iv } = await encryptText(key, body);
    sendSocket({ type: 'send', conversationId, ciphertext, iv, kind: 'text', tempId, replyToId, mentionAll });
  } catch (err) {
    removeMessage(conversationId, tempId);
    renderMessages();
    toast(err.message, true);
  }
}

// ── Attachment menu ─────────────────────────────────────────

$('attach-btn').addEventListener('click', (e) => {
  e.stopPropagation();
  $('attach-menu').querySelector('[data-action="product"]')?.classList.toggle('hidden', !state.me?.businessSettings?.enabled);
  $('attach-menu').classList.toggle('hidden');
});

document.addEventListener('click', () => $('attach-menu').classList.add('hidden'));

$('attach-menu').addEventListener('click', (e) => {
  const action = e.target.closest('button')?.dataset.action;
  if (!action) return;
  $('attach-menu').classList.add('hidden');
  if (action === 'file') $('file-input').click();
  else if (action === 'location') shareLocation();
  else if (action === 'contact') openContactForm();
  else if (action === 'poll') F.openPollComposer();
  else if (action === 'view-once') F.pickViewOnce();
  else if (action === 'product') F.openSendProduct();
});

$('file-input').addEventListener('change', (e) => {
  const file = e.target.files[0];
  e.target.value = '';   // so picking the same file twice still fires
  if (file) sendMediaFile(file);
});

/** Encrypts + uploads one File and sends it as a 'file' message. `extra` is
 *  merged into the encrypted metadata (e.g. { sticker: true }). Shared by the
 *  attach menu, the sticker/GIF picker, and drag-drop. */
async function sendMediaFile(file, extra = {}) {
  if (!state.activeId) return;
  const conversationId = state.activeId;
  const convo = state.conversations.get(conversationId);
  if (!canSendTo(convo)) return;

  const tempId = 'temp-' + crypto.randomUUID();
  state.plaintext.set(tempId, { name: file.name, mime: file.type, size: file.size, ...extra });
  pushMessage(conversationId, {
    id: tempId, senderId: state.me.id, kind: 'file',
    createdAt: new Date().toISOString(), pending: true,
  });
  renderMessages();

  const offline = () => !navigator.onLine || state.ws?.readyState !== WebSocket.OPEN;

  try {
    const key = await keyFor(convo);
    const { blob, ciphertext, iv } = await encryptFile(key, file, extra);
    const baseFrame = { type: 'send', conversationId, ciphertext, iv, kind: 'file', tempId,
                        ...(extra.viewOnce ? { viewOnce: true } : {}) };

    if (offline()) {
      // Hold the encrypted blob in the outbox — flushOutbox() uploads it and
      // sends the message once the connection is back.
      queueOutbound(baseFrame, { blob });
      toast('No connection — this will send when you’re back online.');
      return;
    }

    const form = new FormData();
    form.append('blob', blob, 'blob');
    const { filePath, fileSize } = await api('/api/upload', { method: 'POST', body: form });
    sendSocket({ ...baseFrame, filePath, fileSize });
  } catch (err) {
    if (offline()) {
      toast('No connection — send this again once you’re back online.', true);
      // leave the pending bubble; the user can retry
      return;
    }
    removeMessage(conversationId, tempId);
    renderMessages();
    toast(err.message, true);
  }
}

// ═══════════════════════════════════════════════════════════
// Emoji / GIF / sticker picker
// ═══════════════════════════════════════════════════════════

const EMOJI_GROUPS = {
  '😀': ['😀','😃','😄','😁','😆','😅','🤣','😂','🙂','🙃','😉','😊','😇','🥰','😍','🤩','😘','😗','😚','😙','😋','😛','😜','🤪','😝','🤑','🤗','🤭','🤫','🤔','🤐','🤨','😐','😑','😶','😏','😒','🙄','😬','🤥','😌','😔','😪','🤤','😴','😷','🤒','🤕','🤢','🤮','🥵','🥶','😵','🤯','🤠','🥳','😎','🤓','🧐','😕','😟','🙁','😮','😯','😲','😳','🥺','😦','😧','😨','😰','😥','😢','😭','😱','😖','😣','😞','😓','😩','😫','🥱','😤','😡','😠','🤬','😈','👿','💀','💩','🤡','👻','👽','🤖'],
  '👋': ['👋','🤚','🖐️','✋','🖖','👌','🤌','🤏','✌️','🤞','🤟','🤘','🤙','👈','👉','👆','🖕','👇','☝️','👍','👎','✊','👊','🤛','🤜','👏','🙌','👐','🤲','🤝','🙏','✍️','💅','🤳','💪','🦾','🦿','🦵','🦶','👂','👃','🧠','🫀','🫁','🦷','🦴','👀','👁️','👅','👄','💋','🩸'],
  '❤️': ['❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💔','❣️','💕','💞','💓','💗','💖','💘','💝','💟','☮️','✝️','☪️','🕉️','☸️','✡️','🔯','🕎','☯️','☦️','🛐','⛎','♈','♉','♊','♋','♌','♍','♎','♏','♐','♑','♒','♓','🆔','⚛️','🉑','☢️','☣️','📴','📳','💯','🔥','✨','🎉','🎊','⭐','🌟','💫','⚡','💥','🌈'],
  '🐶': ['🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐽','🐸','🐵','🙈','🙉','🙊','🐒','🐔','🐧','🐦','🐤','🦆','🦅','🦉','🦇','🐺','🐗','🐴','🦄','🐝','🐛','🦋','🐌','🐞','🐜','🦂','🐢','🐍','🦎','🐙','🦑','🦀','🐡','🐠','🐟','🐬','🐳','🐋','🦈','🐊','🐅','🐆','🦓','🦍','🐘','🦛','🦏','🐪','🐫','🦒','🦘','🐃','🐂','🐄','🐎','🐖','🐏','🐑','🐐','🦌','🐕','🐩','🐈','🐓','🦃','🕊️','🐇','🐁','🐀','🐿️','🦔'],
  '🍎': ['🍏','🍎','🍐','🍊','🍋','🍌','🍉','🍇','🍓','🫐','🍈','🍒','🍑','🥭','🍍','🥥','🥝','🍅','🍆','🥑','🥦','🥬','🥒','🌶️','🌽','🥕','🧄','🧅','🥔','🍠','🥐','🥯','🍞','🥖','🥨','🧀','🥚','🍳','🧈','🥞','🧇','🥓','🥩','🍗','🍖','🌭','🍔','🍟','🍕','🥪','🥙','🧆','🌮','🌯','🥗','🥘','🍝','🍜','🍲','🍛','🍣','🍱','🥟','🍤','🍚','🍘','🍥','🥮','🍢','🍡','🍧','🍨','🍦','🥧','🧁','🍰','🎂','🍮','🍭','🍬','🍫','🍿','🍩','🍪','☕','🍵','🧋','🥤','🍶','🍺','🍷','🥂','🥃','🍸','🍹','🍾'],
  '⚽': ['⚽','🏀','🏈','⚾','🥎','🎾','🏐','🏉','🥏','🎱','🪀','🏓','🏸','🏒','🏑','🥍','🏏','🥅','⛳','🪁','🏹','🎣','🤿','🥊','🥋','🎽','🛹','🛷','⛸️','🥌','🎿','⛷️','🏂','🏋️','🤼','🤸','⛹️','🤺','🤾','🏌️','🏇','🧘','🏄','🏊','🤽','🚣','🧗','🚵','🚴','🏆','🥇','🥈','🥉','🏅','🎖️','🎗️','🎫','🎟️','🎪','🎭','🩰','🎨','🎬','🎤','🎧','🎼','🎹','🥁','🎷','🎺','🎸','🪕','🎻','🎲','♟️','🎯','🎳','🎮','🎰','🧩'],
  '🚗': ['🚗','🚕','🚙','🚌','🚎','🏎️','🚓','🚑','🚒','🚐','🚚','🚛','🚜','🛴','🚲','🛵','🏍️','🛺','🚨','🚔','🚍','🚘','🚖','🚡','🚠','🚟','🚃','🚋','🚞','🚝','🚄','🚅','🚈','🚂','🚆','🚇','🚊','🚉','✈️','🛫','🛬','🛩️','💺','🛰️','🚀','🛸','🚁','🛶','⛵','🚤','🛥️','🛳️','⛴️','🚢','⚓','⛽','🚧','🚦','🚥','🗺️','🗿','🗽','🗼','🏰','🏯','🏟️','🎡','🎢','🎠','⛲','⛱️','🏖️','🏝️','🏜️','🌋','⛰️','🏔️','🗻','🏕️','⛺','🏠','🏡','🏘️','🏚️','🏗️','🏢','🏬','🏣','🏤','🏥','🏦','🏨','🏪','🏫','🏩','💒','🏛️','⛪','🕌','🕍','🛕','🕋','⛩️','🌁','🌃','🏙️','🌄','🌅','🌆','🌇','🌉'],
  '💡': ['⌚','📱','📲','💻','⌨️','🖥️','🖨️','🖱️','🖲️','🕹️','🗜️','💽','💾','💿','📀','📼','📷','📸','📹','🎥','📽️','🎞️','📞','☎️','📟','📠','📺','📻','🎙️','🎚️','🎛️','🧭','⏱️','⏲️','⏰','🕰️','⌛','⏳','📡','🔋','🔌','💡','🔦','🕯️','🪔','🧯','🛢️','💸','💵','💴','💶','💷','💰','💳','💎','⚖️','🧰','🔧','🔨','⚒️','🛠️','⛏️','🔩','⚙️','🧱','⛓️','🧲','🔫','💣','🧨','🪓','🔪','🗡️','⚔️','🛡️','🚬','⚰️','⚱️','🏺','🔮','📿','🧿','💈','⚗️','🔭','🔬','🕳️','🩹','🩺','💊','💉','🩸','🧬','🦠','🧫','🧪','🌡️','🧹','🧺','🧻','🚽','🚰','🚿','🛁','🛀','🧼','🪒','🧽','🧴','🛎️','🔑','🗝️','🚪','🪑','🛋️','🛏️','🛌','🧸','🖼️','🛍️','🛒','🎁','🎈','🎏','🎀','🎊','🎉','🎎','🏮','🎐','🧧','✉️','📩','📨','📧','💌','📥','📤','📦','🏷️','📪','📫','📬','📭','📮','📯','📜','📃','📄','📑','📊','📈','📉','🗒️','🗓️','📆','📅','📇','🗃️','🗳️','🗄️','📋','📁','📂','🗂️','🗞️','📰','📓','📔','📒','📕','📗','📘','📙','📚','📖','🔖','🧷','🔗','📎','🖇️','📐','📏','🧮','📌','📍','✂️','🖊️','🖋️','✒️','🖌️','🖍️','📝','✏️','🔍','🔎'],
};
const EMOJI_CATEGORIES = [
  { icon: '🕐', label: 'Recent', key: 'recent' },
  { icon: '😀', label: 'Smileys' },
  { icon: '👋', label: 'People' },
  { icon: '❤️', label: 'Symbols' },
  { icon: '🐶', label: 'Animals' },
  { icon: '🍎', label: 'Food' },
  { icon: '⚽', label: 'Activities' },
  { icon: '🚗', label: 'Travel' },
  { icon: '💡', label: 'Objects' },
];
// Big, fun single glyphs — sent as a message and rendered jumbo (no bubble).
const STICKER_SET = ['😂','🥹','😍','🥰','😎','🤩','🥳','😭','😅','🤔','😴','🤯','🫡','🫠','🙄','😤','🤗','🫶','👍','👎','👏','🙏','🔥','💯','🎉','✨','💖','💔','⭐','⚡','🌈','🍕','☕','🎂','🏆','⚽','🚀','💀','👻','🤖','👽','🐶','🐱','🦄','🐢','🦋','🌸','🌊','🌙','☀️','❄️'];

const emojiRecent = {
  get: () => { try { return JSON.parse(localStorage.getItem('vesper.emoji.recent') || '[]'); } catch { return []; } },
  push(e) {
    let r = emojiRecent.get().filter((x) => x !== e);
    r.unshift(e);
    r = r.slice(0, 40);
    try { localStorage.setItem('vesper.emoji.recent', JSON.stringify(r)); } catch { /* storage off */ }
  },
};

function insertAtCursor(el, text) {
  const start = el.selectionStart ?? el.value.length;
  const end = el.selectionEnd ?? el.value.length;
  el.value = el.value.slice(0, start) + text + el.value.slice(end);
  el.selectionStart = el.selectionEnd = start + text.length;
  el.focus();
  el.dispatchEvent(new Event('input'));
}

const mediaPicker = $('media-picker');
let mpTab = 'emoji';
let gifEnabled = null;   // null = unknown, true/false once /config is fetched
let gifSearchTimer = null;

// Guard the whole picker wire-up: if a stale cached index.html is ever paired
// with this script (flaky mobile network + the network-first service worker),
// a missing #media-picker must NOT take the rest of app.js down with it.
if (mediaPicker && $('emoji-btn')) {
  $('emoji-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    mediaPicker.classList.toggle('hidden');
    if (!mediaPicker.classList.contains('hidden')) renderMediaPicker();
  });
  document.addEventListener('click', (e) => {
    const btn = $('emoji-btn');
    if (!mediaPicker.contains(e.target) && !(btn && btn.contains(e.target))) {
      mediaPicker.classList.add('hidden');
    }
  });

  $('mp-tabs')?.addEventListener('click', (e) => {
    const t = e.target.closest('button')?.dataset.tab;
    if (!t) return;
    mpTab = t;
    $('mp-tabs').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.tab === t));
    renderMediaPicker();
  });

  $('mp-search')?.addEventListener('input', (e) => {
    clearTimeout(gifSearchTimer);
    const q = e.target.value;
    gifSearchTimer = setTimeout(() => loadGifs(q), 350);
  });
}

async function renderMediaPicker() {
  const body = $('mp-body');
  const searchWrap = $('mp-search-wrap');
  const cats = $('mp-cats');

  searchWrap.classList.toggle('hidden', mpTab !== 'gif');
  cats.classList.toggle('hidden', mpTab !== 'emoji');

  if (mpTab === 'emoji') {
    cats.innerHTML = EMOJI_CATEGORIES.map((c, i) =>
      `<button type="button" class="mp-cat${i === 1 ? ' active' : ''}" data-cat="${c.key || c.label}" title="${c.label}">${c.icon}</button>`
    ).join('');
    renderEmojiGrid('Smileys');
    cats.querySelectorAll('.mp-cat').forEach((b) => b.addEventListener('click', () => {
      cats.querySelectorAll('.mp-cat').forEach((x) => x.classList.remove('active'));
      b.classList.add('active');
      renderEmojiGrid(b.dataset.cat);
    }));
    return;
  }

  if (mpTab === 'sticker') {
    body.className = 'mp-body';
    body.innerHTML = F.myStickersHtml()
      + `<div class="mp-sticker-grid">${STICKER_SET.map((s) => `<button type="button" class="mp-sticker">${s}</button>`).join('')}</div>`;
    F.wireMyStickers(body, () => mediaPicker.classList.add('hidden'));
    body.querySelectorAll('.mp-sticker').forEach((b) => b.addEventListener('click', () => {
      sendMessage(b.textContent);
      emojiRecent.push(b.textContent);
      mediaPicker.classList.add('hidden');
    }));
    return;
  }

  // GIF
  body.className = 'mp-body mp-gif-grid';
  if (gifEnabled === null) {
    try { gifEnabled = (await api('/api/gif/config')).enabled; } catch { gifEnabled = false; }
  }
  if (!gifEnabled) {
    body.className = 'mp-body';
    body.innerHTML = `<div class="mp-empty">GIF search needs a free Tenor API key.<br>
      Add <code>TENOR_API_KEY=…</code> to <code>.env</code> and restart the server.</div>`;
    return;
  }
  loadGifs($('mp-search').value);
}

function renderEmojiGrid(cat) {
  const body = $('mp-body');
  body.className = 'mp-body mp-emoji-grid';
  let list;
  if (cat === 'recent') {
    list = emojiRecent.get();
    if (list.length === 0) { body.className = 'mp-body'; body.innerHTML = `<div class="mp-empty">No recent emoji yet.</div>`; return; }
  } else {
    const groupKey = { Smileys: '😀', People: '👋', Symbols: '❤️', Animals: '🐶', Food: '🍎', Activities: '⚽', Travel: '🚗', Objects: '💡' }[cat] || cat;
    list = EMOJI_GROUPS[groupKey] || [];
  }
  body.innerHTML = list.map((e) => `<button type="button" class="mp-emoji">${e}</button>`).join('');
  body.querySelectorAll('.mp-emoji').forEach((b) => b.addEventListener('click', () => {
    insertAtCursor(input, b.textContent);
    emojiRecent.push(b.textContent);
  }));
}

async function loadGifs(q) {
  const body = $('mp-body');
  body.className = 'mp-body mp-gif-grid';
  body.innerHTML = `<div class="mp-empty">Loading…</div>`;
  try {
    const { results } = await api('/api/gif/search?q=' + encodeURIComponent((q || '').trim()));
    if (!results.length) { body.innerHTML = `<div class="mp-empty">No GIFs found.</div>`; return; }
    body.innerHTML = results.map((g) =>
      `<button type="button" class="mp-gif" data-url="${escapeAttr(g.url)}" title="${escapeAttr(g.description)}">
        <img src="${escapeAttr(g.preview)}" alt="${escapeAttr(g.description)}" loading="lazy">
      </button>`
    ).join('');
    body.querySelectorAll('.mp-gif').forEach((b) => b.addEventListener('click', () => sendGif(b.dataset.url)));
  } catch (err) {
    body.innerHTML = `<div class="mp-empty">${escapeHtml(err.message)}</div>`;
  }
}

async function sendGif(url) {
  mediaPicker.classList.add('hidden');
  try {
    const res = await fetch(apiUrl('/api/gif/fetch?url=' + encodeURIComponent(url)), { credentials: 'include' });
    if (!res.ok) throw new Error('Could not fetch that GIF.');
    const blob = await res.blob();
    const file = new File([blob], 'tenor.gif', { type: 'image/gif' });
    await sendMediaFile(file, { gif: true });
  } catch (err) {
    toast(err.message, true);
  }
}

// ── Voice recording ──────────────────────────────────────────

let mediaRecorder = null;
let recordedChunks = [];
let recTimer = null;
let recStartedAt = null;

// Voice-to-text: live transcription only, during recording — the browser's
// SpeechRecognition API has no way to transcribe an already-recorded audio
// blob after the fact (that would need a paid cloud STT API + key). Picking
// a language in the dropdown turns the recording that follows into a
// transcribe-then-fill-composer flow instead of a voice-note upload; the
// audio itself is discarded once we have the text.
const SpeechRecognitionCtor = window.SpeechRecognition || window.webkitSpeechRecognition;
function speechToTextSupported() { return !!SpeechRecognitionCtor; }

let speechRecognizer = null;
let speechTranscript = '';

if (!speechToTextSupported()) $('speech-lang-select').classList.add('hidden');
else $('speech-lang-select').classList.remove('hidden');

$('mic-btn').addEventListener('click', startRecording);
$('cancel-record-btn').addEventListener('click', () => stopRecording(false));
$('send-record-btn').addEventListener('click', () => stopRecording(true));

async function startRecording() {
  if (!state.activeId) return;

  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch {
    toast('Microphone access was denied.', true);
    return;
  }

  recordedChunks = [];
  mediaRecorder = new MediaRecorder(stream);
  mediaRecorder.ondataavailable = (e) => { if (e.data.size > 0) recordedChunks.push(e.data); };
  mediaRecorder.start();

  recStartedAt = Date.now();
  $('rec-time').textContent = '0:00';
  recTimer = setInterval(() => {
    $('rec-time').textContent = formatDuration((Date.now() - recStartedAt) / 1000);
  }, 250);

  const lang = speechToTextSupported() ? $('speech-lang-select').value : '';
  const hint = $('rec-hint');
  if (lang) {
    speechTranscript = '';
    hint.textContent = 'Listening…';
    hint.classList.add('transcribing');

    speechRecognizer = new SpeechRecognitionCtor();
    speechRecognizer.lang = lang;
    speechRecognizer.continuous = true;
    speechRecognizer.interimResults = true;
    speechRecognizer.onresult = (e) => {
      let finalText = '', interimText = '';
      for (let i = 0; i < e.results.length; i++) {
        const r = e.results[i];
        if (r.isFinal) finalText += r[0].transcript;
        else interimText += r[0].transcript;
      }
      speechTranscript = finalText;
      hint.textContent = (finalText + interimText).trim() || 'Listening…';
    };
    speechRecognizer.onerror = () => { /* mic errors surface via getUserMedia already; ignore transcript hiccups */ };
    try { speechRecognizer.start(); } catch { /* already started — ignore */ }
  } else {
    hint.textContent = 'Recording voice note…';
    hint.classList.remove('transcribing');
  }

  $('composer-normal').classList.add('hidden');
  $('recording-bar').classList.remove('hidden');
}

/** send=false discards the recording (cancel); send=true finalizes and sends it. */
function stopRecording(send) {
  if (!mediaRecorder) return;

  clearInterval(recTimer);
  $('recording-bar').classList.add('hidden');
  $('composer-normal').classList.remove('hidden');

  const wasTranscribing = !!speechRecognizer;
  if (speechRecognizer) {
    speechRecognizer.onresult = null;
    speechRecognizer.stop();
    speechRecognizer = null;
  }

  const recorder = mediaRecorder;
  mediaRecorder = null;

  recorder.addEventListener('stop', () => {
    recorder.stream.getTracks().forEach((t) => t.stop());   // release the mic

    // recordedChunks only gets its data here: start() was called with no
    // timeslice, so the browser buffers everything internally and fires a
    // single 'dataavailable' event — which the spec guarantees lands before
    // this 'stop' event — as part of stop() itself. Checking chunk count any
    // earlier (e.g. synchronously right after calling stop()) always sees an
    // empty array and silently drops the recording.
    if (wasTranscribing) {
      // Text mode: the audio was only ever a means to get a transcript —
      // discard it, drop the transcript into the composer for the user to
      // review/edit, and let them send it like any normal typed message.
      if (send && speechTranscript.trim()) {
        input.value = input.value ? input.value + ' ' + speechTranscript.trim() : speechTranscript.trim();
        input.dispatchEvent(new Event('input'));
        input.focus();
      } else if (send) {
        toast("Didn't catch any speech.", true);
      }
    } else if (send && recordedChunks.length > 0) {
      sendVoiceNote(new Blob(recordedChunks, { type: recorder.mimeType }));
    }

    recordedChunks = [];
  }, { once: true });

  recorder.stop();
}

async function sendVoiceNote(blob) {
  if (!state.activeId) return;

  const conversationId = state.activeId;
  const convo = state.conversations.get(conversationId);
  if (!canSendTo(convo)) return;

  const tempId = 'temp-' + crypto.randomUUID();
  const optimistic = {
    id: tempId, senderId: state.me.id, kind: 'voice',
    createdAt: new Date().toISOString(), pending: true,
  };

  // A plain object duck-typed like a File — encryptFile only ever calls
  // .arrayBuffer()/.name/.type/.size, all of which a MediaRecorder Blob has
  // except .name, which we supply here.
  const fileLike = {
    name: 'voice-note.webm',
    type: blob.type || 'audio/webm',
    size: blob.size,
    arrayBuffer: () => blob.arrayBuffer(),
  };

  state.plaintext.set(tempId, { name: fileLike.name, mime: fileLike.type, size: fileLike.size });
  pushMessage(conversationId, optimistic);
  renderMessages();

  try {
    const key = await keyFor(convo);
    const { blob: encBlob, ciphertext, iv } = await encryptFile(key, fileLike);

    const form = new FormData();
    form.append('blob', encBlob, 'blob');
    const { filePath, fileSize } = await api('/api/upload', { method: 'POST', body: form });

    sendSocket({
      type: 'send', conversationId, ciphertext, iv,
      kind: 'voice', filePath, fileSize, tempId,
    });
  } catch (err) {
    removeMessage(conversationId, tempId);
    renderMessages();
    toast(err.message, true);
  }
}

// ── Location & contact cards ─────────────────────────────────

/** Shared sender for any JSON-payload message kind (location, contact). */
async function sendJsonMessage(kind, payload, extras = {}) {
  if (!state.activeId) return;

  const conversationId = state.activeId;
  const convo = state.conversations.get(conversationId);
  if (!canSendTo(convo)) return;

  const tempId = 'temp-' + crypto.randomUUID();
  const optimistic = {
    id: tempId, senderId: state.me.id, kind, ...extras,
    createdAt: new Date().toISOString(), pending: true,
  };

  state.plaintext.set(tempId, payload);
  pushMessage(conversationId, optimistic);
  renderMessages();

  try {
    const key = await keyFor(convo);
    const { ciphertext, iv } = await encryptText(key, JSON.stringify(payload));
    sendSocket({ type: 'send', conversationId, ciphertext, iv, kind, tempId, ...extras });
  } catch (err) {
    removeMessage(conversationId, tempId);
    renderMessages();
    toast(err.message, true);
  }
}

function shareLocation() {
  if (!state.activeId) return;
  if (!navigator.geolocation) {
    toast('Location is not available in this browser.', true);
    return;
  }

  toast('Getting your location…');
  navigator.geolocation.getCurrentPosition(
    (pos) => sendJsonMessage('location', { lat: pos.coords.latitude, lng: pos.coords.longitude }),
    () => toast('Could not get your location — permission denied?', true),
    { timeout: 10_000 }
  );
}

function openContactForm() {
  if (!state.activeId) return;

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Share a contact</h3>
      <div class="field"><label>Name</label><input id="contact-name-input" placeholder="Full name"></div>
      <div class="field"><label>Phone</label><input id="contact-phone-input" placeholder="+91 98765 43210"></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="contact-cancel">Cancel</button>
        <button type="button" class="btn-primary" id="contact-send">Send</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#contact-cancel').addEventListener('click', close);
  box.querySelector('#contact-send').addEventListener('click', () => {
    const name = box.querySelector('#contact-name-input').value.trim();
    const phone = box.querySelector('#contact-phone-input').value.trim();
    if (!name || !phone) { toast('Name and phone are both required.', true); return; }
    sendJsonMessage('contact', { name, phone });
    close();
  });
}

function pushMessage(conversationId, msg) {
  if (!state.messages.has(conversationId)) state.messages.set(conversationId, []);
  state.messages.get(conversationId).push(msg);
}

function removeMessage(conversationId, id) {
  const list = state.messages.get(conversationId);
  if (!list) return;
  const i = list.findIndex((m) => m.id === id);
  if (i !== -1) list.splice(i, 1);
}

// ═══════════════════════════════════════════════════════════
// Typing
// ═══════════════════════════════════════════════════════════

let typingSent = false;

function signalTyping() {
  if (!state.activeId) return;

  if (!typingSent) {
    typingSent = true;
    sendSocket({ type: 'typing', conversationId: state.activeId, isTyping: true });
  }

  clearTimeout(state.typingTimer);
  state.typingTimer = setTimeout(stopTyping, 2500);
}

function stopTyping() {
  clearTimeout(state.typingTimer);
  if (!typingSent) return;
  typingSent = false;
  if (state.activeId) {
    sendSocket({ type: 'typing', conversationId: state.activeId, isTyping: false });
  }
}

function showPeerTyping(isTyping) {
  const status = $('peer-status');
  clearTimeout(state.peerTypingTimer);

  if (isTyping) {
    status.textContent = 'typing…';
    status.className = 'peer-status typing';
    // Safety net: if the "stopped" frame is lost, don't leave it stuck forever.
    state.peerTypingTimer = setTimeout(updatePeerStatus, 4000);
  } else {
    updatePeerStatus();
  }
}

function updatePeerStatus() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;

  const status = $('peer-status');

  if (convo.kind === 'group') {
    status.textContent = `${convo.memberCount} member${convo.memberCount === 1 ? '' : 's'}`;
    status.className = 'peer-status';
    return;
  }

  const dot = $('peer-avatar').querySelector('.dot');

  if (state.online.has(convo.peer.id)) {
    status.textContent = 'online';
    status.className = 'peer-status online';
  } else {
    status.textContent = convo.peer.lastSeen
      ? 'last seen ' + relativeTime(convo.peer.lastSeen)
      : 'offline';
    status.className = 'peer-status';
  }

  if (dot) dot.classList.toggle('online', state.online.has(convo.peer.id));
}

// ═══════════════════════════════════════════════════════════
// WebSocket
// ═══════════════════════════════════════════════════════════

let reconnectDelay = 1000;

function connectSocket() {
  const ws = new WebSocket(API_BASE.replace(/^http/, 'ws') + '/ws');
  state.ws = ws;

  ws.addEventListener('open', () => {
    reconnectDelay = 1000;
    flushOutbox();   // anything typed while offline goes out now
  });

  ws.addEventListener('message', (e) => {
    let frame;
    try { frame = JSON.parse(e.data); } catch { return; }
    handleFrame(frame);
  });

  ws.addEventListener('close', async (e) => {
    if (e.code === 4001) {
      // Either "log out all other devices" was used elsewhere (this session
      // is gone), or another device just did it and this one holds the new
      // session — ask the server which.
      try {
        await new Promise((r) => setTimeout(r, 800));   // let a fresh session cookie land first
        await api('/api/auth/me');
        reconnectDelay = 1000;
        setTimeout(connectSocket, 300);
      } catch (err) {
        if (err.status === 401) await signedOutRemotely();
      }
      return;
    }

    // Exponential backoff, capped, so a server restart doesn't get hammered.
    setTimeout(connectSocket, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 1.7, 20_000);
  });
}

// The OS says the network is back — don't wait out the backoff timer.
window.addEventListener('online', () => {
  if (state.me && state.ws?.readyState !== WebSocket.OPEN) { reconnectDelay = 1000; connectSocket(); }
  else flushOutbox();
});

function sendSocket(obj) {
  if (state.ws?.readyState === WebSocket.OPEN) {
    state.ws.send(JSON.stringify(obj));
    return;
  }
  // Offline: keep real messages in the outbox so they go out on reconnect —
  // like WhatsApp's pending clock. Everything else (typing, receipts, call
  // signalling) is only meaningful live, so it's dropped.
  if (obj.type === 'send' && obj.tempId) {
    queueOutbound(obj);
    toast('No connection — this will send when you’re back online.');
  }
}

// ═══════════════════════════════════════════════════════════
// Outbox — messages sent while offline (persisted in localstore.js)
// ═══════════════════════════════════════════════════════════

/** Persist a 'send' frame (already encrypted) so it survives a refresh and
 *  goes out on reconnect. `upload` is set for media that still needs its blob
 *  posted to /api/upload first (that call needs the network too). */
function queueOutbound(frame, upload = null) {
  const list = state.messages.get(frame.conversationId) || [];
  const optimistic = list.find((m) => m.id === frame.tempId);
  const entry = {
    tempId: frame.tempId,
    conversationId: frame.conversationId,
    kind: frame.kind || 'text',
    replyToId: frame.replyToId ?? null,
    senderId: state.me?.id,
    createdAt: optimistic?.createdAt || new Date().toISOString(),
    plaintext: state.plaintext.get(frame.tempId) ?? null,
    frame,
    upload,
    queuedAt: Date.now(),
  };
  state.outbox.set(entry.tempId, entry);
  localStore.putOutbox(entry.tempId, entry);
}

function clearOutbound(tempId) {
  state.outbox.delete(tempId);
  localStore.deleteOutbox(tempId);
}

/** Optimistic message objects for anything still queued in a conversation. */
function outboxMessagesFor(conversationId) {
  return [...state.outbox.values()]
    .filter((e) => e.conversationId === conversationId)
    .map((e) => ({
      id: e.tempId, senderId: e.senderId, kind: e.kind,
      replyToId: e.replyToId, createdAt: e.createdAt, pending: true,
    }));
}

/** Pull the queue off disk on boot; show the pending bubbles again. */
async function hydrateOutbox() {
  try {
    const entries = await localStore.getOutbox();
    for (const e of entries) {
      state.outbox.set(e.tempId, e);
      state.plaintext.set(e.tempId, e.plaintext);
      if (!state.messages.has(e.conversationId)) state.messages.set(e.conversationId, []);
      const list = state.messages.get(e.conversationId);
      if (!list.some((m) => m.id === e.tempId)) {
        list.push({ id: e.tempId, senderId: e.senderId, kind: e.kind,
                    replyToId: e.replyToId, createdAt: e.createdAt, pending: true });
      }
    }
  } catch { /* no queue */ }
}

let flushing = false;
/** Send everything in the outbox, oldest first. Called on every WS 'open'. */
async function flushOutbox() {
  if (flushing || state.ws?.readyState !== WebSocket.OPEN) return;
  flushing = true;
  try {
    const entries = [...state.outbox.values()].sort((a, b) => a.queuedAt - b.queuedAt);
    for (const e of entries) {
      if (state.ws?.readyState !== WebSocket.OPEN) break;
      // Already sent and still waiting on the server's echo — don't double-send.
      if (e.sentAt && Date.now() - e.sentAt < 30_000) continue;
      try {
        let frame = e.frame;
        if (e.upload) {
          // Media: the blob still needs uploading before the message can go.
          const form = new FormData();
          form.append('blob', e.upload.blob, 'blob');
          const { filePath, fileSize } = await api('/api/upload', { method: 'POST', body: form });
          frame = { ...e.frame, filePath, fileSize };
        }
        state.ws.send(JSON.stringify(frame));
        e.sentAt = Date.now();
        localStore.putOutbox(e.tempId, e);
        // The server's 'sent' echo (matched by tempId) removes it from the
        // outbox and turns the bubble real — see the 'sent' case.
      } catch {
        // Upload failed (still flaky) — leave it queued, try again next 'open'.
      }
    }
  } finally {
    flushing = false;
  }
}

async function handleFrame(frame) {
  switch (frame.type) {
    case 'ready':
      break;

    case 'sent': {
      // Swap the optimistic bubble for the authoritative one.
      clearOutbound(frame.tempId);   // confirmed — drop it from the offline queue
      const list = state.messages.get(frame.conversationId);
      if (list) {
        const i = list.findIndex((m) => m.id === frame.tempId);
        if (i !== -1) {
          if (JSON_KINDS.has(frame.message.kind)) {
            // The optimistic placeholder (set before the file was even
            // encrypted, in send*()) only ever had name/mime/size — it's
            // missing fields the real encrypted metadata carries, like
            // blobIv, which the play/transcribe buttons need to decrypt the
            // attachment. Re-decrypt the confirmed message instead of
            // reusing that placeholder, or those buttons silently fail
            // until the page is reloaded.
            try {
              const convo = state.conversations.get(frame.conversationId);
              const key = await keyFor(convo);
              state.plaintext.set(frame.message.id, await decryptBody(key, frame.message));
            } catch {
              state.plaintext.set(frame.message.id, state.plaintext.get(frame.tempId));
            }
          } else {
            state.plaintext.set(frame.message.id, state.plaintext.get(frame.tempId));
          }
          state.plaintext.delete(frame.tempId);
          list[i] = frame.message;
          // Same bubble, real id now — it already popped in as the pending one.
          if (renderedFor.ids.has(frame.tempId)) renderedFor.ids.add(frame.message.id);
          localStore.putMessage(frame.message, state.plaintext.get(frame.message.id));
        }
      }
      touchConversation(frame.conversationId, frame.message);
      if (frame.conversationId === state.activeId) renderMessages();
      renderChatList();
      break;
    }

    case 'message':
      await onIncoming(frame);
      break;

    case 'receipts': {
      const list = state.messages.get(frame.conversationId);
      if (list) {
        const ids = new Set(frame.messageIds);
        for (const m of list) {
          if (!ids.has(m.id)) continue;
          if (frame.status === 'read') m.readAt = new Date().toISOString();
          m.deliveredAt = m.deliveredAt || new Date().toISOString();
        }
      }
      if (frame.conversationId === state.activeId) renderMessages();
      renderChatList();
      break;
    }

    case 'typing':
      if (frame.conversationId === state.activeId) showPeerTyping(frame.isTyping);
      break;

    case 'presence': {
      if (frame.online) state.online.add(frame.userId);
      else state.online.delete(frame.userId);

      for (const c of state.conversations.values()) {
        if (c.kind !== 'group' && c.peer.id === frame.userId) c.peer.lastSeen = frame.lastSeen;
      }
      renderChatList();
      updatePeerStatus();
      break;
    }

    case 'read-cleared': {
      const c = state.conversations.get(frame.conversationId);
      if (c) { c.unread = 0; renderChatList(); }
      break;
    }

    case 'error': {
      toast(frame.error, true);
      // A rejected send (e.g. replying into a still-pending request) leaves a
      // permanent "sending…" bubble unless the matching optimistic entry is
      // torn back out here — without this fix that's exactly what happens.
      if (frame.tempId) {
        for (const [conversationId, list] of state.messages) {
          const i = list.findIndex((m) => m.id === frame.tempId);
          if (i === -1) continue;
          list.splice(i, 1);
          state.plaintext.delete(frame.tempId);
          if (conversationId === state.activeId) renderMessages();
          break;
        }
      }
      break;
    }

    case 'reaction': {
      const list = state.messages.get(frame.conversationId);
      if (list) {
        const m = list.find((x) => x.id === frame.messageId);
        if (m) {
          m.reactions = m.reactions || [];
          const idx = m.reactions.findIndex((r) => r.userId === frame.userId);
          const cacheKey = `${frame.messageId}:${frame.userId}`;

          if (frame.removed) {
            if (idx !== -1) m.reactions.splice(idx, 1);
            state.reactionPlaintext.delete(cacheKey);
          } else {
            const entry = { userId: frame.userId, ciphertext: frame.ciphertext, iv: frame.iv };
            if (idx !== -1) m.reactions[idx] = entry; else m.reactions.push(entry);
            const key = state.keys.get(frame.conversationId);
            try {
              state.reactionPlaintext.set(cacheKey, key ? await decryptText(key, frame.ciphertext, frame.iv) : null);
            } catch {
              state.reactionPlaintext.set(cacheKey, null);
            }
          }
        }
      }
      if (frame.conversationId === state.activeId) renderMessages();
      break;
    }

    case 'message-deleted': {
      const list = state.messages.get(frame.conversationId);
      const m = list?.find((x) => x.id === frame.messageId);
      if (m) { m.deleted = true; localStore.putMessage(m, null); }
      if (frame.conversationId === state.activeId) renderMessages();
      renderChatList();
      break;
    }

    case 'message-edited': {
      const list = state.messages.get(frame.conversationId);
      const m = list?.find((x) => x.id === frame.messageId);
      if (m) {
        m.ciphertext = frame.ciphertext;
        m.iv = frame.iv;
        m.editedAt = frame.editedAt;
        const key = state.keys.get(frame.conversationId);
        try {
          state.plaintext.set(frame.messageId, key ? await decryptText(key, frame.ciphertext, frame.iv) : null);
        } catch {
          state.plaintext.set(frame.messageId, null);
        }
        localStore.putMessage(m, state.plaintext.get(frame.messageId));
      }
      if (frame.conversationId === state.activeId) renderMessages();
      renderChatList();
      break;
    }

    case 'request-accepted': {
      const c = state.conversations.get(frame.conversationId);
      if (c) {
        c.status = 'accepted';
        if (frame.conversationId === state.activeId) { updateRequestBar(c); updateCallButtons(c); }
        renderChatList();
        toast(`${c.peer?.displayName || 'They'} accepted your message request.`);
        refreshPresence().then(() => { renderChatList(); updatePeerStatus(); });
      }
      break;
    }

    case 'request-declined': {
      state.conversations.delete(frame.conversationId);
      state.messages.delete(frame.conversationId);
      state.keys.delete(frame.conversationId);
      if (state.activeId === frame.conversationId) {
        state.activeId = null;
        $('chat-pane').classList.add('hidden');
        $('no-chat').classList.remove('hidden');
      }
      renderChatList();
      toast('Your message request was declined.');
      break;
    }

    case 'call-offer':          onCallOfferReceived(frame); break;
    case 'call-answer':         onCallAnswerReceived(frame); break;
    case 'call-decline':        onCallDeclineReceived(frame); break;
    case 'call-ice':            onCallIceReceived(frame); break;
    case 'call-end':            onCallEndReceived(frame); break;
    case 'call-claimed':        onCallClaimedElsewhere(frame); break;
    case 'call-started-elsewhere': onCallStartedElsewhere(frame); break;
    case 'call-error':          toast(frame.error, true); break;

    case 'group-call-state':             onGroupCallState(frame); break;
    case 'group-call-participant-joined': onGroupCallParticipantJoined(frame); break;
    case 'group-call-participant-left':   onGroupCallParticipantLeft(frame); break;
    case 'group-call-offer':             onGroupCallOfferReceived(frame); break;
    case 'group-call-answer':            onGroupCallAnswerReceived(frame); break;
    case 'group-call-ice':               onGroupCallIceReceived(frame); break;
    case 'group-call-claimed':           onGroupCallClaimedElsewhere(frame); break;
    case 'group-call-error':             onGroupCallErrorReceived(frame); break;

    case 'game-signal': onGameSignal(frame); break;

    // Polls, pins, disappearing & view-once messages, login alerts.
    default: F.handleFeatureFrame(frame); break;
  }
}

async function onIncoming(frame) {
  const { conversationId, message } = frame;

  // A message from someone we've never chatted with — the conversation isn't in
  // our list yet, so pull the list again to pick it up.
  if (!state.conversations.has(conversationId)) {
    await loadConversations();
  }

  const convo = state.conversations.get(conversationId);
  if (!convo) return;

  try {
    const key = await keyFor(convo);
    state.plaintext.set(message.id, await decryptBody(key, message));
  } catch {
    state.plaintext.set(message.id, null);
  }
  localStore.putMessage(message, state.plaintext.get(message.id));

  const list = state.messages.get(conversationId);
  if (list && !list.some((m) => m.id === message.id)) list.push(message);

  touchConversation(conversationId, message);

  if (conversationId === state.activeId) {
    renderMessages();
    showPeerTyping(false);
    if (message.kind === 'text' && message.senderId !== state.me.id) F.maybePlayEffect(state.plaintext.get(message.id));
    sendSocket({ type: 'read', conversationId });   // we're looking at it
    if (!input.value.trim()) refreshComposerSuggestions();   // fresh quick replies
  } else if (message.senderId !== state.me.id) {
    convo.unread = (convo.unread || 0) + 1;
    if ((!convo.muted && !convo.archived) || message.mentionAll) notify(convo, message);
  }

  renderChatList();
}

function touchConversation(id, message) {
  const c = state.conversations.get(id);
  if (c) c.lastMessage = message;
}

// ═══════════════════════════════════════════════════════════
// Status / Stories
// ═══════════════════════════════════════════════════════════

async function loadStatuses() {
  try {
    const { statuses } = await api('/api/status');
    state.statuses = statuses;
    renderStatusTray();
  } catch {
    // The tray is decoration — a failure here shouldn't block the rest of the app.
  }
}

/** The public key needed to unwrap a status's content key: mine for my own
 *  statuses, or a contact's — found via the direct conversation I already
 *  have with them, since "contact" and "has a direct conversation" are the
 *  same set by definition in this app. */
function resolvePosterPublicKey(posterId) {
  if (posterId === state.me.id) return state.publicJwk;
  for (const c of state.conversations.values()) {
    if (c.kind !== 'group' && c.peer?.id === posterId) return c.peer.publicKey;
  }
  return null;
}

async function decryptStatus(s) {
  const posterKey = resolvePosterPublicKey(s.posterId);
  if (!posterKey) throw new Error('Could not resolve this status\'s encryption key.');

  const wrapKey = await deriveWrapKey(state.privateKey, posterKey);
  const contentKey = await unwrapContentKey(wrapKey, s.wrappedKey, s.wrappedIv);

  return s.kind === 'image' || s.kind === 'video'
    ? { key: contentKey, meta: await decryptFileMeta(contentKey, s.ciphertext, s.iv) }
    : { key: contentKey, text: await decryptText(contentKey, s.ciphertext, s.iv) };
}

function renderStatusTray() {
  const tray = $('status-tray');
  const mine = state.statuses.filter((s) => s.isMine);

  const grouped = new Map(); // posterId -> { name, color, photoUrl, items }
  for (const s of state.statuses) {
    if (s.isMine) continue;
    if (!grouped.has(s.posterId)) {
      grouped.set(s.posterId, { name: s.posterName, color: s.posterColor, photoUrl: s.posterPhotoUrl, items: [] });
    }
    grouped.get(s.posterId).items.push(s);
  }

  let html = `
    <div class="status-tray-item" id="my-status-item">
      <div class="status-ring ${mine.length ? '' : 'status-add-badge'}">
        <div class="avatar sm" style="background:${escapeAttr(state.me.avatarColor)}">
          ${avatarInner(state.me)}
        </div>
        ${mine.length ? `
          <button type="button" class="status-add-btn" id="my-status-add-btn"
                  aria-label="Add another status">+</button>
        ` : ''}
      </div>
      <span class="label">${mine.length ? 'My status' : 'Add status'}</span>
    </div>`;

  for (const [posterId, g] of grouped) {
    const unseen = g.items.some((s) => !s.viewed);
    const mentioned = g.items.some((s) => s.mentionsMe);
    html += `
      <div class="status-tray-item" data-poster="${escapeAttr(posterId)}">
        <div class="status-ring ${unseen ? 'unseen' : ''}">
          <div class="avatar sm" style="background:${escapeAttr(g.color)}">
            ${avatarInner({ displayName: g.name, photoUrl: g.photoUrl })}
          </div>
          ${mentioned ? '<span class="status-mention-dot" title="Mentioned you">@</span>' : ''}
        </div>
        <span class="label">${escapeHtml(g.name.split(/\s+/)[0])}</span>
      </div>`;
  }

  tray.innerHTML = html;

  $('my-status-item').addEventListener('click', () => {
    if (mine.length) openStatusViewer(mine, 0);
    else openStatusComposer();
  });

  $('my-status-add-btn')?.addEventListener('click', (e) => {
    e.stopPropagation(); // don't also trigger the tray item's own click (opens the viewer)
    openStatusComposer();
  });

  tray.querySelectorAll('[data-poster]').forEach((el) => {
    el.addEventListener('click', () => {
      const items = grouped.get(el.dataset.poster).items;
      const firstUnseen = items.findIndex((s) => !s.viewed);
      openStatusViewer(items, firstUnseen === -1 ? 0 : firstUnseen);
    });
  });
}

/** prefill (optional): { file, text, mentionIds } — used by "Add to my status"
 *  when re-sharing a status you were mentioned in. */
function openStatusComposer(prefill = {}) {
  const contacts = directContacts();

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  const pickerRows = (listId) => `
    <div class="picker-list" id="${listId}">
      ${contacts.map((c) => `
        <label class="picker-row">
          <input type="checkbox" value="${escapeAttr(c.id)}">
          <div class="avatar sm" style="background:${escapeAttr(c.avatarColor)}">${avatarInner(c)}</div>
          <span class="name">${escapeHtml(c.displayName)}</span>
        </label>`).join('')}
    </div>`;

  box.innerHTML = `
    <div class="modal-card">
      <h3>Post a status</h3>

      <div class="field">
        <textarea id="status-text-input" rows="3" placeholder="What's on your mind?"></textarea>
      </div>

      <div class="field">
        <label>Add to your status</label>
        <div class="attach-row">
          <button type="button" class="attach-chip" data-for="status-image-input">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg>
            <span class="attach-chip-label">Photo</span>
          </button>
          <button type="button" class="attach-chip" data-for="status-video-input">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m23 7-7 5 7 5V7z"/><rect x="1" y="5" width="15" height="14" rx="3"/></svg>
            <span class="attach-chip-label">Video</span>
          </button>
          <button type="button" class="attach-chip" data-for="status-audio-input">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>
            <span class="attach-chip-label">Song</span>
          </button>
        </div>
        <input type="file" id="status-image-input" accept="image/*" class="visually-hidden-file">
        <input type="file" id="status-video-input" accept="video/*" class="visually-hidden-file">
        <input type="file" id="status-audio-input" accept="audio/*" class="visually-hidden-file">
      </div>

      <div class="field hidden" id="status-caption-field">
        <label>Caption</label>
        <input type="text" id="status-caption-input" placeholder="Say something about this" maxlength="200">
      </div>

      <div class="field">
        <label>Who can see this</label>
        <select id="status-audience-select">
          <option value="contacts">All my contacts</option>
          <option value="selected"${contacts.length === 0 ? ' disabled' : ''}>Only share with…</option>
        </select>
      </div>
      <div class="field hidden" id="status-audience-field">
        ${pickerRows('status-audience-list')}
      </div>

      <div class="field">
        <label>Mention someone <span style="opacity:.55;font-weight:500">optional</span></label>
        <button type="button" class="btn-secondary" id="status-mention-toggle"
                ${contacts.length === 0 ? 'disabled' : ''}>+ Tag people</button>
      </div>
      <div class="field hidden" id="status-mention-field">
        ${pickerRows('status-mention-list')}
      </div>

      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="status-cancel">Cancel</button>
        <button type="button" class="btn-primary" id="status-post">Post</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  // Attach chips drive the (hidden) real file inputs and reflect their state.
  box.querySelectorAll('.attach-chip').forEach((chip) => {
    const input = box.querySelector('#' + chip.dataset.for);
    const label = chip.querySelector('.attach-chip-label');
    const baseLabel = label.textContent;
    chip.addEventListener('click', () => {
      if (chip.classList.contains('filled')) {
        input.value = '';
        input.dispatchEvent(new Event('change'));
      } else {
        input.click();
      }
    });
    input.addEventListener('change', () => {
      const f = input.files[0];
      chip.classList.toggle('filled', !!f);
      label.textContent = f ? f.name : baseLabel;
      label.classList.toggle('attach-chip-name', !!f);
      chip.title = f ? 'Remove ' + f.name : '';
    });
  });

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#status-cancel').addEventListener('click', close);

  const imageInput = box.querySelector('#status-image-input');
  const videoInput = box.querySelector('#status-video-input');
  const captionField = box.querySelector('#status-caption-field');

  // Photo and video are mutually exclusive — picking one clears the other,
  // same idea as WhatsApp's single-media-per-status composer. Caption only
  // makes sense once there's media — a text status already IS the text.
  // Re-dispatching change on the cleared input keeps its attach-chip in sync.
  imageInput.addEventListener('change', (e) => {
    if (e.target.files[0] && videoInput.files[0]) { videoInput.value = ''; videoInput.dispatchEvent(new Event('change')); }
    captionField.classList.toggle('hidden', !imageInput.files[0] && !videoInput.files[0]);
  });
  videoInput.addEventListener('change', (e) => {
    if (e.target.files[0] && imageInput.files[0]) { imageInput.value = ''; imageInput.dispatchEvent(new Event('change')); }
    captionField.classList.toggle('hidden', !imageInput.files[0] && !videoInput.files[0]);
  });

  box.querySelector('#status-audience-select').addEventListener('change', (e) => {
    box.querySelector('#status-audience-field').classList.toggle('hidden', e.target.value !== 'selected');
  });
  box.querySelector('#status-mention-toggle').addEventListener('click', () => {
    box.querySelector('#status-mention-field').classList.toggle('hidden');
  });

  // ── Prefill (from "Add to my status") ──
  const putFile = (inputEl, f) => {
    if (!f) return;
    try {
      const dt = new DataTransfer();
      dt.items.add(f);
      inputEl.files = dt.files;
      inputEl.dispatchEvent(new Event('change'));
    } catch { /* DataTransfer unavailable — user can re-pick manually */ }
  };
  if (prefill.text) box.querySelector('#status-text-input').value = prefill.text;
  if (prefill.file) putFile((prefill.file.type || '').startsWith('video') ? videoInput : imageInput, prefill.file);
  putFile(box.querySelector('#status-audio-input'), prefill.audioFile);
  if (prefill.caption) box.querySelector('#status-caption-input').value = prefill.caption;
  if (prefill.mentionIds?.length) {
    box.querySelector('#status-mention-field').classList.remove('hidden');
    prefill.mentionIds.forEach((id) => {
      const cb = box.querySelector(`#status-mention-list input[value="${id}"]`);
      if (cb) cb.checked = true;
    });
  }

  box.querySelector('#status-post').addEventListener('click', async () => {
    const text = box.querySelector('#status-text-input').value.trim();
    const imageFile = imageInput.files[0];
    const videoFile = videoInput.files[0];
    const file = imageFile || videoFile;
    const caption = box.querySelector('#status-caption-input').value.trim();
    const audioFile = box.querySelector('#status-audio-input').files[0] || null;
    const audience = box.querySelector('#status-audience-select').value;
    const selectedIds = [...box.querySelectorAll('#status-audience-list input:checked')].map((el) => el.value);
    const mentionIds = [...box.querySelectorAll('#status-mention-list input:checked')].map((el) => el.value);

    if (!text && !file) { toast('Write something or pick a photo/video.', true); return; }
    if (audience === 'selected' && selectedIds.length === 0) {
      toast('Pick at least one person to share this with.', true);
      return;
    }

    const btn = box.querySelector('#status-post');
    btn.disabled = true;
    btn.textContent = 'Posting…';
    try {
      const kind = videoFile ? 'video' : imageFile ? 'image' : 'text';
      await postStatus(kind, file || text, { caption, audioFile, audience, selectedIds, mentionIds });
      if (prefill.sourceStatusId) rememberReshared(prefill.sourceStatusId);
      close();
      toast('Status posted.');
    } catch (err) {
      toast(err.message, true);
      btn.disabled = false;
      btn.textContent = 'Post';
    }
  });
}

/**
 * data is a File for kind='image'/'video', or the raw string for kind='text'.
 * `caption` applies to image/video statuses (rides inside the same encrypted
 * metadata as the filename, via encryptFile's `extra` param). `audioFile`,
 * if given, is a separate optional song/voice attachment encrypted with the
 * SAME content key as the main content — one set of wrapped keys already
 * covers both, no new key-wrapping needed.
 *
 * `audience`: 'contacts' (default, everyone) or 'selected' (only
 * `selectedIds`). `mentionIds` are tagged regardless of audience — anyone
 * mentioned always gets a key too, even if they weren't in `selectedIds`,
 * so a mention can never point at a status its target can't actually open.
 */
async function postStatus(kind, data, {
  caption = '', audioFile = null, audience = 'contacts', selectedIds = [], mentionIds = [],
} = {}) {
  const { key: contentKey, raw: contentRaw } = await generateContentKey();

  let ciphertext, iv, filePath = null, fileSize = null;
  if (kind === 'image' || kind === 'video') {
    const encoded = await encryptFile(contentKey, data, caption ? { caption } : {});
    ciphertext = encoded.ciphertext;
    iv = encoded.iv;

    const form = new FormData();
    form.append('blob', encoded.blob, 'blob');
    const uploaded = await api('/api/upload', { method: 'POST', body: form });
    filePath = uploaded.filePath;
    fileSize = uploaded.fileSize;
  } else {
    ({ ciphertext, iv } = await encryptText(contentKey, data));
  }

  let audioCiphertext = null, audioIv = null, audioFilePath = null, audioFileSize = null;
  if (audioFile) {
    const encodedAudio = await encryptFile(contentKey, audioFile);
    audioCiphertext = encodedAudio.ciphertext;
    audioIv = encodedAudio.iv;

    const audioForm = new FormData();
    audioForm.append('blob', encodedAudio.blob, 'blob');
    const uploadedAudio = await api('/api/upload', { method: 'POST', body: audioForm });
    audioFilePath = uploadedAudio.filePath;
    audioFileSize = uploadedAudio.fileSize;
  }

  // Wrap the content key for myself (so I can re-open it after a refresh)
  // plus whoever the audience is. This MUST go through directContacts() —
  // not a separate inline scan of state.conversations — or a still-pending
  // contact could receive a real, decryptable status key before ever
  // accepting the request, defeating the entire point of gating. (The server
  // also independently re-checks this in status.js, so a stale/modified
  // client can't bypass it either — but the client should still get it right.)
  const contacts = directContacts();
  const audienceContacts = audience === 'selected'
    ? contacts.filter((c) => selectedIds.includes(c.id))
    : contacts;
  // Anyone tagged needs a key regardless of the audience picker above —
  // union them in (by id) rather than trusting they're already included.
  const audienceIds = new Set(audienceContacts.map((c) => c.id));
  const mentionContacts = contacts.filter((c) => mentionIds.includes(c.id) && !audienceIds.has(c.id));
  const recipients = [
    { id: state.me.id, publicKey: state.publicJwk },
    ...audienceContacts,
    ...mentionContacts,
  ];

  const keys = [];
  for (const r of recipients) {
    const wrapKey = await deriveWrapKey(state.privateKey, r.publicKey);
    const { wrappedKey, wrappedIv } = await wrapContentKey(wrapKey, contentRaw);
    keys.push({ viewerId: r.id, wrappedKey, wrappedIv });
  }

  await api('/api/status', {
    method: 'POST',
    body: JSON.stringify({
      kind, ciphertext, iv, filePath, fileSize, keys,
      audioCiphertext, audioIv, audioFilePath, audioFileSize,
      audience, mentions: mentionIds,
    }),
  });

  await loadStatuses();
}

let statusViewerState = null;

function openStatusViewer(items, startIndex) {
  if (items.length === 0) return;

  const box = document.createElement('div');
  box.className = 'status-viewer';
  document.body.appendChild(box);

  // Everything lives inside .status-card, which is the actual phone-story-
  // shaped box — .status-viewer itself is just the full-screen dimmed
  // backdrop that centers it (see Fix 3b: full-bleed stretching looked
  // wrong for story content on a wide desktop window).
  box.innerHTML = `
    <div class="status-card">
      <div class="status-viewer-bars">
        ${items.map(() => '<div class="bar"><i></i></div>').join('')}
      </div>
      <div class="status-viewer-head">
        <div class="avatar sm" id="sv-avatar"></div>
        <div class="grow">
          <div class="name" id="sv-name"></div>
          <div class="time" id="sv-time"></div>
        </div>
        <button class="icon-btn hidden" id="sv-audio-btn" aria-label="Toggle music" style="color:#fff">
          ${iconPlay()}
        </button>
        <button class="icon-btn hidden" id="sv-reshare-btn" aria-label="Add to my status" title="Add to my status" style="color:#fff">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="3" y="3" width="18" height="18" rx="3"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/>
          </svg>
        </button>
        <button class="icon-btn hidden" id="sv-delete-btn" aria-label="Delete status" title="Delete status" style="color:#fff">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M3 6h18"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2"/>
          </svg>
        </button>
        <button class="icon-btn hidden" id="sv-download-btn" aria-label="Download" style="color:#fff">
          ${iconDownload()}
        </button>
        <button class="icon-btn" id="sv-close" aria-label="Close" style="color:#fff">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round">
            <path d="M18 6 6 18"/><path d="m6 6 12 12"/>
          </svg>
        </button>
      </div>
      <div class="status-viewer-body" id="sv-body">
        <!-- Tap zones live INSIDE the body, not as a card-spanning sibling —
             position:absolute here only covers the body's own rectangle, so
             it can never sit on top of (and swallow clicks meant for) the
             seenby line or reply input below it. #sv-content is a separate
             child so showStatusItem() can swap it freely without wiping
             the tap zones out along with it. -->
        <div class="status-viewer-tap-zones">
          <div id="sv-prev"></div><div id="sv-next"></div>
        </div>
        <div id="sv-content"></div>
      </div>
      <div class="status-seenby" id="sv-seenby"></div>
      <div class="status-seenby-panel hidden" id="sv-seenby-panel"></div>
      <div class="status-reply-bar hidden" id="sv-reply-bar">
        <input id="sv-reply-input" placeholder="Reply…" autocomplete="off">
        <button class="icon-btn" id="sv-reply-send" aria-label="Send reply">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4 20-7z"/>
          </svg>
        </button>
      </div>
    </div>`;

  statusViewerState = { items, index: startIndex, box, timer: null, audio: null };

  box.querySelector('#sv-close').addEventListener('click', closeStatusViewer);
  box.querySelector('#sv-prev').addEventListener('click', () => stepStatusViewer(-1));
  box.querySelector('#sv-next').addEventListener('click', () => stepStatusViewer(1));
  box.querySelector('#sv-audio-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    toggleStatusAudio();
  });
  box.querySelector('#sv-download-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    downloadCurrentStatusMedia();
  });
  box.querySelector('#sv-reshare-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    reshareCurrentStatus();
  });
  box.querySelector('#sv-delete-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    deleteCurrentStatus();
  });

  // Pausing auto-advance while typing a reply — nobody wants the story to
  // skip out from under them mid-sentence.
  const replyInput = box.querySelector('#sv-reply-input');
  replyInput.addEventListener('focus', () => clearTimeout(statusViewerState.timer));
  replyInput.addEventListener('blur', () => {
    if (!replyInput.value.trim()) restartAutoAdvance();
  });
  replyInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); sendStatusReply(); }
  });
  box.querySelector('#sv-reply-send').addEventListener('click', sendStatusReply);

  box.querySelector('#sv-seenby').addEventListener('click', toggleSeenByPanel);

  showStatusItem(startIndex);
}

async function showStatusItem(index) {
  const st = statusViewerState;
  if (!st) return;
  clearTimeout(st.timer);
  stopStatusAudio();
  st.box.querySelector('#sv-seenby-panel').classList.add('hidden');

  if (index < 0 || index >= st.items.length) { closeStatusViewer(); return; }
  st.index = index;

  const bars = st.box.querySelectorAll('.status-viewer-bars .bar');
  bars.forEach((bar, i) => {
    bar.classList.toggle('done', i < index);
    const fill = bar.querySelector('i');
    fill.style.transition = 'none';
    fill.style.width = i < index ? '100%' : '0%';
  });

  const s = st.items[index];
  setAvatar(
    st.box.querySelector('#sv-avatar'),
    s.isMine ? state.me : { displayName: s.posterName, avatarColor: s.posterColor, photoUrl: s.posterPhotoUrl }
  );
  st.box.querySelector('#sv-name').textContent = s.isMine
    ? (s.audience === 'selected' ? 'My status 🔒' : 'My status')
    : s.posterName;
  st.box.querySelector('#sv-time').textContent = relativeTime(s.createdAt);
  st.box.querySelector('#sv-reply-bar').classList.toggle('hidden', s.isMine);
  st.box.querySelector('#sv-audio-btn').classList.add('hidden');
  st.box.querySelector('#sv-download-btn').classList.add('hidden');
  // "Add to my status" — re-post anyone else's status as your own (once each).
  st.box.querySelector('#sv-reshare-btn').classList.toggle('hidden', s.isMine || resharedIds.has(s.id));
  // Delete — only on your own.
  const delBtn = st.box.querySelector('#sv-delete-btn');
  delBtn.classList.toggle('hidden', !s.isMine);
  delBtn.disabled = false;
  st.currentMedia = null;
  st.currentText = '';
  st.currentCaption = '';
  st.currentAudio = null;

  const body = st.box.querySelector('#sv-content');
  body.innerHTML = '<div style="color:#fff">Decrypting…</div>';

  const mentionChips = (s.mentions || []).length
    ? `<div class="status-mentions">${s.mentions.map((m) =>
        `<span class="status-mention-chip">@${escapeHtml(m.displayName)}</span>`).join('')}</div>`
    : '';
  const mentionedBanner = s.mentionsMe
    ? `<div class="status-mentioned-banner">🔔 ${escapeHtml(s.posterName)} mentioned you</div>` : '';
  const topOverlay = (mentionedBanner || mentionChips)
    ? `<div class="status-top-overlay">${mentionedBanner}${mentionChips}</div>` : '';

  try {
    const decoded = await decryptStatus(s);
    if (s.kind === 'image' || s.kind === 'video') {
      const blob = await getDecryptedMediaBlob(s.filePath, decoded.key, decoded.meta.blobIv, decoded.meta.mime);
      const url = URL.createObjectURL(blob);
      st.currentCaption = decoded.meta.caption || '';
      const caption = decoded.meta.caption
        ? `<div class="status-caption">${escapeHtml(decoded.meta.caption)}</div>` : '';
      st.currentMedia = { url, mime: decoded.meta.mime, name: decoded.meta.name || `status.${s.kind === 'video' ? 'mp4' : 'jpg'}` };
      st.box.querySelector('#sv-download-btn').classList.remove('hidden');

      if (s.kind === 'video') {
        // Muted autoplay is the only kind guaranteed not to get blocked by the
        // browser (real autoplay-with-sound needs a fresh user gesture, which
        // the async decrypt work in between very likely burns through) — so
        // there's a small custom mute toggle instead of relying on native
        // <video controls>, which would sit underneath (and be unreachable
        // through) the prev/next tap-zone overlay covering the rest of the body.
        body.innerHTML = `${topOverlay}<video src="${escapeAttr(url)}" autoplay muted playsinline loop></video>
          <button type="button" class="status-video-mute-btn" id="sv-video-mute">🔇</button>
          ${caption}`;
        const video = body.querySelector('video');
        const muteBtn = body.querySelector('#sv-video-mute');
        muteBtn.addEventListener('click', (e) => {
          e.stopPropagation();
          video.muted = !video.muted;
          muteBtn.textContent = video.muted ? '🔇' : '🔊';
        });
        video.addEventListener('loadedmetadata', () => {
          if (isFinite(video.duration) && video.duration > 0) restartAutoAdvance(video.duration * 1000);
        });
      } else {
        body.innerHTML = `${topOverlay}<img src="${escapeAttr(url)}" alt="">${caption}`;
      }
    } else {
      st.currentText = decoded.text || '';
      body.innerHTML = `${topOverlay}<div class="status-text">${escapeHtml(decoded.text)}</div>`;
    }

    if (s.audioCiphertext) await loadStatusAudio(s, decoded.key);
  } catch {
    body.innerHTML = '<div style="color:#fff">Could not decrypt this status.</div>';
  }

  if (!s.isMine) {
    api(`/api/status/${s.id}/view`, { method: 'POST' }).catch(() => {});
    s.viewed = true;
  }

  const seenby = st.box.querySelector('#sv-seenby');
  if (s.isMine) {
    seenby.textContent = 'Loading views…';
    api(`/api/status/${s.id}/views`)
      .then(({ views }) => {
        // The user may have navigated to a different status while this was
        // in flight — a stale response landing here would show the wrong
        // seen-by list against the currently-displayed status.
        if (st.items[st.index]?.id !== s.id) return;
        seenby.textContent = views.length === 0 ? 'No views yet' : `Seen by ${views.length} — tap to see who`;
        st.currentViews = views;
      })
      .catch(() => { seenby.textContent = ''; });
  } else {
    seenby.textContent = '';
  }

  restartAutoAdvance();
}

/** durationMs defaults to the usual 5s (text/image); a video overrides this
 *  once its real length is known (see the 'loadedmetadata' handler above),
 *  so the progress bar and the auto-advance timer both track its actual
 *  runtime instead of cutting it off at a fixed 5 seconds. */
function restartAutoAdvance(durationMs = 5000) {
  const st = statusViewerState;
  if (!st) return;
  clearTimeout(st.timer);

  const bars = st.box.querySelectorAll('.status-viewer-bars .bar');
  const activeFill = bars[st.index]?.querySelector('i');
  if (activeFill) {
    activeFill.style.transition = 'none';
    activeFill.style.width = '0%';
    requestAnimationFrame(() => {
      activeFill.style.transition = `width ${durationMs / 1000}s linear`;
      activeFill.style.width = '100%';
    });
  }
  st.timer = setTimeout(() => stepStatusViewer(1), durationMs);
}

/** Saves the currently-displayed photo/video to the viewer's device. This is
 *  a real browser download (goes to the Downloads folder, same as any other
 *  site's download link) — a plain web page has no API to reach into the
 *  phone's Photos/gallery app directly, that's the honest ceiling here, but
 *  on both Android and iOS the Downloads location is picked up by the
 *  system's own Files/gallery apps shortly after. Pausing auto-advance
 *  while the browser's save dialog might be up avoids the story skipping
 *  out from under it. */
function downloadCurrentStatusMedia() {
  const st = statusViewerState;
  if (!st?.currentMedia) return;
  clearTimeout(st.timer);

  const a = document.createElement('a');
  a.href = st.currentMedia.url;
  a.download = st.currentMedia.name;
  document.body.appendChild(a);
  a.click();
  a.remove();

  toast('Saved to your downloads.');
  restartAutoAdvance();
}

// Each status can only be added to your own once — tracked locally (there's
// no server link between the source and the copy).
const resharedIds = {
  get: () => { try { return new Set(JSON.parse(localStorage.getItem('vesper.reshared') || '[]')); } catch { return new Set(); } },
  has: (id) => resharedIds.get().has(id),
};
function rememberReshared(id) {
  const set = resharedIds.get();
  set.add(id);
  try { localStorage.setItem('vesper.reshared', JSON.stringify([...set].slice(-200))); } catch { /* storage off */ }
}

/** "Add to my status" — re-post the exact status you're viewing (photo/video,
 *  its song, its caption) as your own. */
async function reshareCurrentStatus() {
  const st = statusViewerState;
  if (!st) return;
  const s = st.items[st.index];
  if (s.isMine) return;
  if (resharedIds.has(s.id)) { toast('You’ve already added this one to your status.', true); return; }

  const asFile = async (src, fallbackName) => {
    const blob = await (await fetch(src.url)).blob();
    return new File([blob], src.name || fallbackName, { type: blob.type || src.mime || 'application/octet-stream' });
  };

  let file = null, audioFile = null;
  const text = st.currentMedia ? '' : (st.currentText || '');
  const caption = st.currentMedia ? (st.currentCaption || '') : '';

  try {
    if (st.currentMedia?.url) {
      file = await asFile(st.currentMedia, `reshare.${(st.currentMedia.mime || '').includes('video') ? 'mp4' : 'jpg'}`);
    }
    if (st.currentAudio?.url) {
      audioFile = await asFile(st.currentAudio, 'song.mp3');
    }
  } catch {
    toast('Could not load that status to re-share.', true);
    return;
  }
  if (!file && !text) { toast('Nothing to re-share.', true); return; }

  closeStatusViewer();
  openStatusComposer({ file, audioFile, text, caption, sourceStatusId: s.id });
}

/** Decrypts the status's attached song and tries to play it. Autoplay can be
 *  blocked by the browser if too much async work happened since the user's
 *  last click (a real risk here, given decryption is itself async) — if so,
 *  this just leaves it paused with a visible play button rather than
 *  pretending it worked. */
async function loadStatusAudio(s, contentKey) {
  const st = statusViewerState;
  const meta = await decryptFileMeta(contentKey, s.audioCiphertext, s.audioIv);
  const res = await fetch(apiUrl(`/api/upload/${s.audioFilePath}`), { credentials: 'include' });
  if (!res.ok) return;

  const bytes = await decryptFileBytes(contentKey, await res.arrayBuffer(), meta.blobIv);
  const url = URL.createObjectURL(new Blob([bytes], { type: meta.mime }));

  // Kept so "Add to my status" can carry the same song into the re-share.
  st.currentAudio = { url, mime: meta.mime, name: meta.name || 'song.mp3' };

  const audio = new Audio(url);
  audio.loop = true;
  st.audio = audio;

  const btn = st.box.querySelector('#sv-audio-btn');
  btn.classList.remove('hidden');
  audio.addEventListener('play', () => { btn.innerHTML = iconPause(); });
  audio.addEventListener('pause', () => { btn.innerHTML = iconPlay(); });

  audio.play().catch(() => { btn.innerHTML = iconPlay(); });
}

function toggleStatusAudio() {
  const audio = statusViewerState?.audio;
  if (!audio) return;
  if (audio.paused) audio.play().catch(() => {}); else audio.pause();
}

function stopStatusAudio() {
  const st = statusViewerState;
  if (!st?.audio) return;
  st.audio.pause();
  st.audio = null;
}

function toggleSeenByPanel() {
  const st = statusViewerState;
  if (!st || !st.currentViews) return;

  const panel = st.box.querySelector('#sv-seenby-panel');
  const opening = panel.classList.contains('hidden');

  if (opening) {
    clearTimeout(st.timer); // pause the story while browsing who's seen it
    panel.innerHTML = st.currentViews.map((v) => `
      <div class="seenby-row">
        <div class="avatar sm" style="background:${escapeAttr(v.avatarColor)}">${avatarInner(v)}</div>
        <span class="name">${escapeHtml(v.displayName)}</span>
        <span class="time">${relativeTime(v.viewedAt)}</span>
      </div>`).join('') || '<div class="empty-hint">No views yet</div>';
  } else {
    restartAutoAdvance();
  }

  panel.classList.toggle('hidden', !opening);
}

/** A status reply is just a normal message into the direct conversation you
 *  already have with the poster — visibility rules already guarantee that
 *  conversation exists and is accepted, so no new send path is needed. */
async function sendStatusReply() {
  const st = statusViewerState;
  if (!st) return;

  const s = st.items[st.index];
  const input = st.box.querySelector('#sv-reply-input');
  const text = input.value.trim();
  if (!text) return;

  const convo = [...state.conversations.values()]
    .find((c) => c.kind !== 'group' && c.peer?.id === s.posterId);
  if (!convo) { toast('Could not find your conversation with them.', true); return; }

  input.value = '';
  input.disabled = true;
  try {
    // Same optimistic-bubble pattern as sendMessage() — without a tempId the
    // 'sent' echo has nothing to swap in, so if this conversation happens to
    // already be open (or gets opened right after), the reply would silently
    // be missing from it until a reload.
    const tempId = 'temp-' + crypto.randomUUID();
    state.plaintext.set(tempId, text);
    pushMessage(convo.id, {
      id: tempId, senderId: state.me.id, kind: 'text',
      createdAt: new Date().toISOString(), pending: true,
    });

    const key = await keyFor(convo);
    const { ciphertext, iv } = await encryptText(key, text);
    sendSocket({ type: 'send', conversationId: convo.id, ciphertext, iv, kind: 'text', tempId });
    if (convo.id === state.activeId) renderMessages();
    toast('Reply sent.');
  } catch (err) {
    toast(err.message, true);
  } finally {
    input.disabled = false;
    restartAutoAdvance();
  }
}

function stepStatusViewer(delta) {
  showStatusItem(statusViewerState.index + delta);
}

/** Delete one of your own statuses from inside the viewer. */
async function deleteCurrentStatus() {
  const st = statusViewerState;
  if (!st) return;
  const s = st.items[st.index];
  if (!s?.isMine) return;

  clearTimeout(st.timer);
  const btn = st.box.querySelector('#sv-delete-btn');
  if (!confirm('Delete this status? This can’t be undone.')) { restartAutoAdvance(); return; }

  btn.disabled = true;
  try {
    await api(`/api/status/${s.id}`, { method: 'DELETE' });
    state.statuses = state.statuses.filter((x) => x.id !== s.id);
    st.items.splice(st.index, 1);
    renderStatusTray();
    toast('Status deleted.');
    if (st.items.length === 0) { closeStatusViewer(); return; }
    st.box.querySelector('.status-viewer-bars').innerHTML =
      st.items.map(() => '<div class="bar"><i></i></div>').join('');
    showStatusItem(Math.min(st.index, st.items.length - 1));
  } catch (err) {
    toast(err.message, true);
    btn.disabled = false;
    restartAutoAdvance();
  }
}

function closeStatusViewer() {
  if (!statusViewerState) return;
  clearTimeout(statusViewerState.timer);
  stopStatusAudio();
  statusViewerState.box.remove();
  statusViewerState = null;
  loadStatuses(); // refresh tray ring state (viewed flags) now that we've closed
}

// ═══════════════════════════════════════════════════════════
// Groups
// ═══════════════════════════════════════════════════════════

/** Every ACCEPTED direct-chat peer — the pool of people you can start/add to
 *  a group or share a status with. A still-pending request doesn't count —
 *  gating message requests would mean nothing if a pending contact could
 *  still be status-shared with or group-invited before ever accepting. */
function directContacts() {
  return [...state.conversations.values()]
    .filter((c) => c.kind !== 'group' && c.status === 'accepted' && c.peer?.publicKey)
    .map((c) => c.peer);
}

$('new-group-btn').addEventListener('click', openGroupCreator);

function openGroupCreator() {
  const contacts = directContacts();
  if (contacts.length === 0) {
    toast('Start a direct chat with someone first — groups are built from your existing contacts.', true);
    return;
  }

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>New group</h3>
      <div class="field"><label>Group name</label><input id="group-name-input" placeholder="Team Veyon"></div>
      <div class="field">
        <label>Members</label>
        <div class="picker-list" id="group-picker-list">
          ${contacts.map((c) => `
            <label class="picker-row">
              <input type="checkbox" value="${escapeAttr(c.id)}">
              <div class="avatar sm" style="background:${escapeAttr(c.avatarColor)}">${avatarInner(c)}</div>
              <span class="name">${escapeHtml(c.displayName)}</span>
            </label>`).join('')}
        </div>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="group-cancel">Cancel</button>
        <button type="button" class="btn-primary" id="group-create">Create</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#group-cancel').addEventListener('click', close);

  box.querySelector('#group-create').addEventListener('click', async () => {
    const title = box.querySelector('#group-name-input').value.trim();
    const memberIds = [...box.querySelectorAll('#group-picker-list input:checked')].map((el) => el.value);

    if (!title) { toast('Give the group a name.', true); return; }
    if (memberIds.length === 0) { toast('Pick at least one member.', true); return; }

    const btn = box.querySelector('#group-create');
    btn.disabled = true;
    btn.textContent = 'Creating…';
    try {
      const conversation = await createGroup(title, memberIds, contacts);
      close();
      state.conversations.set(conversation.id, conversation);
      renderChatList();
      await openConversation(conversation.id);
    } catch (err) {
      toast(err.message, true);
      btn.disabled = false;
      btn.textContent = 'Create';
    }
  });
}

/**
 * Generates the group's content key client-side, wraps it once for the
 * creator (required — see the server-side validation this pairs with) and
 * once per selected member, then hands the server only already-wrapped key
 * material. `contacts` supplies each member's public key without an extra
 * round trip, since they're all people we already have a direct chat with.
 */
async function createGroup(title, memberIds, contacts) {
  const { raw: contentRaw } = await generateContentKey();
  const byId = new Map(contacts.map((c) => [c.id, c]));

  const keys = [];
  for (const id of [state.me.id, ...memberIds]) {
    const publicKey = id === state.me.id ? state.publicJwk : byId.get(id)?.publicKey;
    if (!publicKey) continue;
    const wrapKey = await deriveWrapKey(state.privateKey, publicKey);
    const { wrappedKey, wrappedIv } = await wrapContentKey(wrapKey, contentRaw);
    keys.push({ userId: id, wrappedKey, wrappedIv });
  }

  const { conversation } = await api('/api/conversations/group', {
    method: 'POST',
    body: JSON.stringify({ title, members: keys }),
  });
  return conversation;
}

$('group-info-btn').addEventListener('click', openGroupInfo);

// Tapping the peer's photo or name in the chat header opens their info,
// the same as WhatsApp.
function openActiveConversationInfo() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;
  if (convo.kind === 'group') openGroupInfo();
  else openContactInfo();
}
$('peer-avatar')?.addEventListener('click', openActiveConversationInfo);
$('peer-name')?.addEventListener('click', openActiveConversationInfo);

function openGroupInfo() { return F.openGroupInfo(); }

async function openAddMember(convo, currentMembers) {
  const currentIds = new Set(currentMembers.map((m) => m.id));
  const candidates = directContacts().filter((c) => !currentIds.has(c.id));

  if (candidates.length === 0) {
    toast('Everyone in your contacts is already in this group.', true);
    return;
  }

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Add to ${escapeHtml(convo.title)}</h3>
      <div class="picker-list">
        ${candidates.map((c) => `
          <label class="picker-row">
            <input type="checkbox" value="${escapeAttr(c.id)}">
            <div class="avatar sm" style="background:${escapeAttr(c.avatarColor)}">${avatarInner(c)}</div>
            <span class="name">${escapeHtml(c.displayName)}</span>
          </label>`).join('')}
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="add-member-cancel">Cancel</button>
        <button type="button" class="btn-primary" id="add-member-confirm">Add</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#add-member-cancel').addEventListener('click', close);

  box.querySelector('#add-member-confirm').addEventListener('click', async () => {
    const picked = [...box.querySelectorAll('input:checked')].map((el) => el.value);
    if (picked.length === 0) { toast('Pick at least one person.', true); return; }

    const btn = box.querySelector('#add-member-confirm');
    btn.disabled = true;
    try {
      // Re-wrap the group's already-unwrapped content key for each new member —
      // this client already holds it (from keyFor) precisely because it's a
      // current member.
      const contentKey = await keyFor(convo);
      const rawKey = new Uint8Array(await crypto.subtle.exportKey('raw', contentKey));
      const byId = new Map(candidates.map((c) => [c.id, c]));

      for (const id of picked) {
        const publicKey = byId.get(id)?.publicKey;
        if (!publicKey) continue;
        const wrapKey = await deriveWrapKey(state.privateKey, publicKey);
        const { wrappedKey, wrappedIv } = await wrapContentKey(wrapKey, rawKey);
        await api(`/api/conversations/${convo.id}/members`, {
          method: 'POST',
          body: JSON.stringify({ userId: id, wrappedKey, wrappedIv }),
        });
      }

      close();
      toast('Member(s) added.');
    } catch (err) {
      toast(err.message, true);
      btn.disabled = false;
    }
  });
}

// ═══════════════════════════════════════════════════════════
// Calling (WebRTC — direct conversations only)
// ═══════════════════════════════════════════════════════════
//
// state.call shape while a call is in progress:
//   { conversationId, toUserId, role: 'caller'|'callee', phase,
//     callType, pc, localStream, pendingRemoteIce, noAnswerTimer,
//     remoteOfferSdp (callee only, before accepting) }
// phase: 'ringing' -> 'connecting' -> 'active', or the call state is torn
// down entirely (state.call = null) on decline/end/timeout/error.
//
// Signaling only ever touches this WebSocket — the actual audio/video is
// peer-to-peer between browsers once ICE completes, already encrypted by
// WebRTC's own DTLS-SRTP. STUN-only (see README): calls between two people
// on very restrictive/symmetric NATs may fail to connect.

const ICE_SERVERS = [{ urls: 'stun:stun.l.google.com:19302' }];
const NO_ANSWER_MS = 35_000;

/** Feature-detects WebRTC + camera/mic access. Some browsers (very old, or a
 *  non-secure context) lack RTCPeerConnection/getUserMedia entirely — better
 *  to hide the call buttons and say so than let a click fail silently. */
function callingSupported() {
  return typeof RTCPeerConnection !== 'undefined' && !!navigator.mediaDevices?.getUserMedia;
}

function updateCallButtons(convo) {
  const canCall = callingSupported() &&
    ((convo.kind === 'direct' && convo.status === 'accepted') || convo.kind === 'group');
  $('audio-call-btn').classList.toggle('hidden', !canCall);
  $('video-call-btn').classList.toggle('hidden', !canCall);
}

// Groups use the same two header buttons as 1:1 calls, but "start or join a
// room" instead of "ring" — see the group-calling section below.
$('audio-call-btn').addEventListener('click', () => {
  const convo = state.conversations.get(state.activeId);
  if (convo?.kind === 'group') startOrJoinGroupCall('audio');
  else startCall('audio');
});
$('video-call-btn').addEventListener('click', () => {
  const convo = state.conversations.get(state.activeId);
  if (convo?.kind === 'group') startOrJoinGroupCall('video');
  else startCall('video');
});

async function startCall(callType) {
  const convo = state.conversations.get(state.activeId);
  if (!convo || convo.kind !== 'direct') return;   // calling is direct-only
  if (!canSendTo(convo)) return;                    // same pending-request gate as sending
  if (state.call || state.groupCall) { toast('You are already in a call.', true); return; }
  if (!callingSupported()) { toast('Calling is not supported in this browser.', true); return; }

  let localStream;
  try {
    localStream = await navigator.mediaDevices.getUserMedia({
      audio: true, video: callType === 'video',
    });
  } catch {
    toast(`Could not access your ${callType === 'video' ? 'camera/microphone' : 'microphone'}.`, true);
    return;
  }

  // Everything past this point can fail (SDP negotiation, codec mismatch,
  // etc.) — without a catch here, a failure leaves the mic/camera open and
  // state.call permanently set, locking out every future call attempt
  // (startCall's own re-entrancy guard above would then always say "already
  // in a call") until the page is refreshed.
  let pc;
  try {
    pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    state.call = {
      conversationId: convo.id, toUserId: convo.peer.id, role: 'caller',
      phase: 'ringing', callType, pc, localStream, pendingRemoteIce: [],
    };

    wireCallPeerConnection(pc, convo.id, convo.peer.id);
    localStream.getTracks().forEach((t) => pc.addTrack(t, localStream));

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    sendSocket({
      type: 'call-offer', conversationId: convo.id, toUserId: convo.peer.id,
      callType, sdp: offer,
    });
    F.startRinging('ringback');   // soft ring-back while it rings at their end

    state.call.noAnswerTimer = setTimeout(() => {
      if (state.call?.phase === 'ringing') {
        sendSocket({ type: 'call-end', conversationId: convo.id, toUserId: convo.peer.id });
        toast('No answer.');
        cleanupCall();
      }
    }, NO_ANSWER_MS);

    showOutgoingCallUI(convo, callType);
  } catch (err) {
    localStream.getTracks().forEach((t) => t.stop());
    pc?.close();
    state.call = null;
    toast('Could not start the call.', true);
    console.error('[call] startCall failed:', err);
  }
}

function onCallOfferReceived(frame) {
  const { conversationId, fromUserId, callType, sdp } = frame;

  // Glare: I'm already ringing as the caller on this exact conversation when
  // an offer comes back the other way. Resolve deterministically so both
  // sides reach the same conclusion independently — lower user ID wins.
  if (state.call?.phase === 'ringing' && state.call.role === 'caller'
      && state.call.conversationId === conversationId) {
    if (state.me.id < fromUserId) {
      return; // my offer wins — ignore theirs, mine is already in flight
    }
    // their offer wins — abandon mine and auto-accept theirs. Still show the
    // incoming-call UI first (cleanupCall() just hid the overlay) so the
    // getUserMedia permission prompt that's about to appear has visible
    // context instead of popping up out of nowhere.
    cleanupCall();
    state.call = {
      conversationId, toUserId: fromUserId, role: 'callee', phase: 'ringing',
      callType, remoteOfferSdp: sdp, pendingRemoteIce: [],
    };
    showIncomingCallUI(state.conversations.get(conversationId), fromUserId, callType);
    acceptCall();
    return;
  }

  if (state.call || state.groupCall) {
    // Already in/starting a different call — automatically busy.
    sendSocket({ type: 'call-decline', conversationId, toUserId: fromUserId });
    return;
  }

  state.call = {
    conversationId, toUserId: fromUserId, role: 'callee', phase: 'ringing',
    callType, remoteOfferSdp: sdp, pendingRemoteIce: [],
  };

  const convo = state.conversations.get(conversationId);
  showIncomingCallUI(convo, fromUserId, callType);
}

async function acceptCall() {
  const call = state.call;
  if (!call || call.role !== 'callee') return;

  let localStream;
  try {
    localStream = await navigator.mediaDevices.getUserMedia({
      audio: true, video: call.callType === 'video',
    });
  } catch {
    toast(`Could not access your ${call.callType === 'video' ? 'camera/microphone' : 'microphone'}.`, true);
    declineCall();
    return;
  }

  // Same reasoning as startCall(): SDP/negotiation failure here must not
  // leave the mic/camera open or state.call stuck with no way to retry.
  try {
    const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    call.pc = pc;
    call.localStream = localStream;
    call.phase = 'connecting';

    wireCallPeerConnection(pc, call.conversationId, call.toUserId);
    localStream.getTracks().forEach((t) => pc.addTrack(t, localStream));

    await pc.setRemoteDescription(call.remoteOfferSdp);
    await drainPendingIce(call);

    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    sendSocket({
      type: 'call-answer', conversationId: call.conversationId,
      toUserId: call.toUserId, sdp: answer,
    });

    showInCallUI(call);
  } catch (err) {
    localStream.getTracks().forEach((t) => t.stop());
    call.pc?.close();
    state.call = null;
    $('call-overlay').classList.add('hidden');
    toast('Could not connect the call.', true);
    console.error('[call] acceptCall failed:', err);
  }
}

function declineCall() {
  const call = state.call;
  if (!call) return;
  sendSocket({ type: 'call-decline', conversationId: call.conversationId, toUserId: call.toUserId });
  cleanupCall();
}

async function onCallAnswerReceived(frame) {
  F.stopRinging();
  const call = state.call;
  if (!call || call.role !== 'caller' || call.conversationId !== frame.conversationId) return;

  clearTimeout(call.noAnswerTimer);
  call.phase = 'connecting';
  await call.pc.setRemoteDescription(frame.sdp);
  await drainPendingIce(call);
  showInCallUI(call);
}

function onCallDeclineReceived(frame) {
  if (!state.call || state.call.conversationId !== frame.conversationId) return;
  toast('Call declined.');
  cleanupCall();
}

async function onCallIceReceived(frame) {
  const call = state.call;
  if (!call || call.conversationId !== frame.conversationId) return;

  // A candidate can arrive before setRemoteDescription has run on this end
  // (real timing race, not theoretical) — addIceCandidate() throws before
  // that point, so queue it and drain once the remote description lands.
  if (!call.pc || !call.pc.remoteDescription) {
    call.pendingRemoteIce.push(frame.candidate);
    return;
  }
  try { await call.pc.addIceCandidate(frame.candidate); } catch { /* stale/duplicate candidate — harmless */ }
}

async function drainPendingIce(call) {
  const queued = call.pendingRemoteIce;
  call.pendingRemoteIce = [];
  for (const candidate of queued) {
    try { await call.pc.addIceCandidate(candidate); } catch { /* stale/duplicate — harmless */ }
  }
}

function onCallEndReceived(frame) {
  if (!state.call || state.call.conversationId !== frame.conversationId) return;
  toast('Call ended.');
  cleanupCall();
}

/** My OWN other tab already answered/declined this call — stand down. */
function onCallClaimedElsewhere(frame) {
  if (state.call?.conversationId === frame.conversationId) cleanupCall(false);
}

/** My own other tab already originated a call — nothing to reconcile here
 *  beyond not also trying to start one; this tab has no call UI up yet in
 *  that scenario, so there's nothing to tear down. */
function onCallStartedElsewhere() { /* intentionally minimal — see comment above */ }

// One button serves all three phases — decline an incoming ring, cancel my
// own outgoing ring, or hang up an active call — since the receiving side
// tears the call down identically either way (see onCallDeclineReceived /
// onCallEndReceived). Sending the phase-accurate frame type just keeps the
// signal semantically honest, not because the two paths behave differently.
$('call-accept-btn').addEventListener('click', acceptCall);
$('call-decline-btn').addEventListener('click', () => {
  const call = state.call;
  if (!call) return;
  sendSocket({
    type: call.phase === 'active' ? 'call-end' : 'call-decline',
    conversationId: call.conversationId, toUserId: call.toUserId,
  });
  cleanupCall();
});

$('call-mute-btn').addEventListener('click', () => {
  const track = state.call?.localStream?.getAudioTracks()[0];
  if (!track) return;
  track.enabled = !track.enabled;
  $('call-mute-btn').classList.toggle('active', !track.enabled);
});

$('call-camera-btn').addEventListener('click', () => {
  const track = state.call?.localStream?.getVideoTracks()[0];
  if (!track) return;
  track.enabled = !track.enabled;
  $('call-camera-btn').classList.toggle('active', !track.enabled);
});

// ── Screen sharing (1:1 video calls) ────────────────────────
// replaceTrack() swaps the outgoing video without renegotiating the peer
// connection, so no signalling changes are needed — the far side just sees
// a different video. Only offered on video calls (an audio call has no
// video transceiver to swap into, and adding one needs renegotiation this
// build doesn't do). getDisplayMedia requires a secure context — fine on
// localhost / the HTTPS listener, unavailable on a plain-http LAN IP.
const screenShareSupported = () => !!navigator.mediaDevices?.getDisplayMedia;

$('call-screen-btn')?.addEventListener('click', toggleScreenShare);

async function toggleScreenShare() {
  const call = state.call;
  if (!call || call.callType !== 'video' || !call.pc) return;
  if (call.screenTrack) { stopScreenShare(); return; }
  if (!navigator.mediaDevices?.getDisplayMedia) {
    toast('Screen sharing isn’t available on this device.', true);
    return;
  }

  let displayStream;
  try {
    displayStream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
  } catch {
    return; // user dismissed the picker, or it's blocked
  }
  const screenTrack = displayStream.getVideoTracks()[0];
  if (!screenTrack) return;

  call.screenTrack = screenTrack;
  // Fires when the user hits the browser's own "Stop sharing" control.
  screenTrack.addEventListener('ended', stopScreenShare, { once: true });

  $('call-local-video').classList.remove('hidden');
  $('call-screen-btn')?.classList.add('active');
  await resyncCallVideo();
  toast('You are sharing your screen.');
}

async function stopScreenShare() {
  const call = state.call;
  $('call-screen-btn')?.classList.remove('active');
  if (!call || !call.screenTrack) return;

  try { call.screenTrack.stop(); } catch { /* already ended */ }
  call.screenTrack = null;
  await resyncCallVideo();
}

// ── Flip camera + video filters (1:1 video calls) ──────────
// All three video features (screen share, flip, filters) feed the same
// outgoing video sender. resyncCallVideo() is the single place that decides
// what track it should carry right now and swaps it without renegotiating.

const CALL_FILTERS = [
  { id: 'none',    label: 'None',    css: 'none' },
  { id: 'mono',    label: 'Mono',    css: 'grayscale(1) contrast(1.05)' },
  { id: 'warm',    label: 'Warm',    css: 'sepia(0.3) saturate(1.5) hue-rotate(-8deg) brightness(1.03)' },
  { id: 'cool',    label: 'Cool',    css: 'saturate(1.15) hue-rotate(12deg) brightness(1.05) contrast(1.03)' },
  { id: 'vivid',   label: 'Vivid',   css: 'saturate(1.7) contrast(1.12)' },
  { id: 'vintage', label: 'Vintage', css: 'sepia(0.55) contrast(1.1) brightness(0.95) saturate(1.25)' },
  { id: 'noir',    label: 'Noir',    css: 'grayscale(1) contrast(1.45) brightness(0.9)' },
  { id: 'soft',    label: 'Soft',    css: 'brightness(1.08) contrast(0.96) saturate(1.05) blur(0.5px)' },
];
const filterCss = (id) => CALL_FILTERS.find((f) => f.id === id)?.css || 'none';

/** Runs a rAF loop drawing the camera track through a canvas with ctx.filter,
 *  and returns a stable captureStream track (so no renegotiation on toggle). */
function ensureFilterTrack() {
  const call = state.call;
  if (!call?.cameraTrack) return null;

  if (!call._fCanvas) {
    call._fCanvas = document.createElement('canvas');
    call._fVideo = document.createElement('video');
    call._fVideo.muted = true;
    call._fVideo.playsInline = true;
  }
  const v = call._fVideo, cv = call._fCanvas;

  // (Re)point the hidden video at the current camera track — matters after a flip.
  if (call._fSourceTrack !== call.cameraTrack) {
    call._fSourceTrack = call.cameraTrack;
    v.srcObject = new MediaStream([call.cameraTrack]);
    v.play().catch(() => {});
  }
  const s = call.cameraTrack.getSettings ? call.cameraTrack.getSettings() : {};
  cv.width = s.width || 640;
  cv.height = s.height || 480;

  if (!call._fTrack) {
    if (!cv.captureStream) return null;   // old browser — filter only on local preview
    call._fStream = cv.captureStream(24);
    call._fTrack = call._fStream.getVideoTracks()[0];
  }

  const ctx = cv.getContext('2d');
  cancelAnimationFrame(call._fRaf);
  const draw = () => {
    const c = state.call;
    if (!c || !c.filterName || c.filterName === 'none' || c.screenTrack) return;
    ctx.filter = filterCss(c.filterName);
    try { ctx.drawImage(v, 0, 0, cv.width, cv.height); } catch { /* frame not ready */ }
    c._fRaf = requestAnimationFrame(draw);
  };
  draw();
  return call._fTrack;
}

function stopFilterLoop(call) {
  if (!call) return;
  cancelAnimationFrame(call._fRaf);
}

/** Decides what the outgoing video should be right now and applies it +
 *  updates the local preview. */
async function resyncCallVideo() {
  const call = state.call;
  if (!call || call.callType !== 'video') return;
  call.videoSender ||= call.pc?.getSenders().find((s) => s.track && s.track.kind === 'video');

  let target;
  if (call.screenTrack) target = call.screenTrack;
  else if (call.filterName && call.filterName !== 'none') target = ensureFilterTrack();
  else { stopFilterLoop(call); target = call.cameraTrack; }

  if (call.videoSender && target && call.videoSender.track !== target) {
    try { await call.videoSender.replaceTrack(target); } catch { /* mid-negotiation */ }
  }

  updateLocalPreview();
}

/** The little self-view. A FRESH MediaStream each call so the <video>
 *  actually re-renders after a camera flip (mutating the old stream's tracks
 *  doesn't reliably repaint on mobile). */
function updateLocalPreview() {
  const call = state.call;
  const lv = $('call-local-video');
  if (!call) { lv.srcObject = null; return; }

  const track = call.screenTrack || call.cameraTrack;
  lv.srcObject = track ? new MediaStream([track]) : null;

  const mirror = !call.screenTrack && call.facingMode !== 'environment';
  lv.style.transform = mirror ? '' : 'none';  // '' => CSS scaleX(-1); 'none' => not mirrored
  lv.style.filter = (!call.screenTrack && call.filterName && call.filterName !== 'none')
    ? filterCss(call.filterName) : '';
}

async function flipCamera() {
  const call = state.call;
  if (!call || call.callType !== 'video' || call.screenTrack || !call.cameraTrack) return;
  const btn = $('call-flip-btn');
  if (btn) btn.disabled = true;

  const next = call.facingMode === 'environment' ? 'user' : 'environment';
  try {
    // Open the other camera fresh, swap it in, then stop the old one. Doing it
    // in this order means a failure leaves the current camera untouched.
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: next } }, audio: false,
    });
    const newTrack = stream.getVideoTracks()[0];
    if (!newTrack) throw new Error('no camera');

    const old = call.cameraTrack;
    call.cameraTrack = newTrack;
    call.facingMode = newTrack.getSettings?.().facingMode || next;
    call._fSourceTrack = null;                // force the filter loop to re-point
    try { old.stop(); } catch { /* already gone */ }

    await resyncCallVideo();
  } catch {
    toast('Could not switch camera — this device may only expose one.', true);
  } finally {
    if (btn) btn.disabled = false;
  }
}

function renderCallFilterBar() {
  const bar = $('call-filter-bar');
  if (!bar) return;
  bar.innerHTML = CALL_FILTERS.map((f) =>
    `<button type="button" class="call-filter-chip${state.call?.filterName === f.id ? ' active' : ''}" data-f="${f.id}">${f.label}</button>`
  ).join('');
  bar.querySelectorAll('.call-filter-chip').forEach((b) =>
    b.addEventListener('click', () => applyCallFilter(b.dataset.f)));
}

async function applyCallFilter(id) {
  if (!state.call) return;
  state.call.filterName = id;
  renderCallFilterBar();
  $('call-filter-btn')?.classList.toggle('active', id !== 'none');
  await resyncCallVideo();
}

$('call-flip-btn')?.addEventListener('click', flipCamera);
$('call-filter-btn')?.addEventListener('click', () => {
  const bar = $('call-filter-bar');
  if (!bar) return;
  bar.classList.toggle('hidden');
  if (!bar.classList.contains('hidden')) renderCallFilterBar();
});

// Tap the self-view to blow it up to full screen (and tap again to shrink it).
$('call-local-video')?.addEventListener('click', () => {
  $('call-local-video').classList.toggle('expanded');
});

function wireCallPeerConnection(pc, conversationId, toUserId) {
  pc.onicecandidate = (e) => {
    if (e.candidate) sendSocket({ type: 'call-ice', conversationId, toUserId, candidate: e.candidate });
  };
  pc.ontrack = (e) => {
    const remote = $('call-remote-video');
    if (remote.srcObject !== e.streams[0]) remote.srcObject = e.streams[0];
    if (state.call) state.call.phase = 'active';
    $('call-status-text').textContent = formatCallDuration();
    startCallDurationTicker();
  };
  pc.onconnectionstatechange = () => {
    if (['failed', 'closed'].includes(pc.connectionState) && state.call) {
      toast('Call connection lost.');
      cleanupCall();
    }
  };
}

let callStartedAt = null;
let callDurationTimer = null;

function startCallDurationTicker() {
  if (callDurationTimer) return;
  callStartedAt = Date.now();
  callDurationTimer = setInterval(() => {
    $('call-status-text').textContent = formatCallDuration();
  }, 1000);
}

function formatCallDuration() {
  if (!callStartedAt) return 'Connecting…';
  return formatDuration((Date.now() - callStartedAt) / 1000);
}

function showOutgoingCallUI(convo, callType) {
  $('call-overlay').classList.remove('hidden');
  $('call-overlay').classList.toggle('video-call', callType === 'video');
  setAvatar($('call-avatar'), convo.peer);
  $('call-name').textContent = convo.peer.displayName;
  $('call-status-text').textContent = 'Calling…';
  $('call-accept-btn').classList.add('hidden');
  $('call-decline-btn').classList.remove('hidden');
  $('call-decline-btn').innerHTML = iconPhoneOff();
  $('call-in-progress-controls').classList.add('hidden');
}

function showIncomingCallUI(convo, fromUserId, callType) {
  const name = convo?.peer?.displayName || 'Someone';

  $('call-overlay').classList.remove('hidden');
  $('call-overlay').classList.toggle('video-call', callType === 'video');
  setAvatar($('call-avatar'), convo?.peer || { displayName: name, avatarColor: '#6C5CE7' });
  $('call-name').textContent = name;
  $('call-status-text').textContent = callType === 'video' ? 'Incoming video call…' : 'Incoming call…';
  $('call-accept-btn').classList.remove('hidden');
  $('call-decline-btn').classList.remove('hidden');
  $('call-decline-btn').innerHTML = iconPhoneOff();
  $('call-in-progress-controls').classList.add('hidden');
  F.startRinging(F.ringtoneFor(fromUserId));   // this contact's ringtone (or the default)

  if ('Notification' in window && Notification.permission === 'granted' && document.hidden) {
    new Notification(`Incoming call from ${name}`);
  }
}

function showInCallUI(call) {
  F.stopRinging();
  $('call-accept-btn').classList.add('hidden');
  $('call-in-progress-controls').classList.remove('hidden');
  $('call-status-text').textContent = 'Connecting…';

  const isVideo = call.callType === 'video';
  const isTouch = window.matchMedia?.('(pointer: coarse)').matches;

  // Screen share: video call + a browser that can capture a display (desktop).
  $('call-screen-btn')?.classList.toggle('hidden', !isVideo || !screenShareSupported());
  // Flip camera: video call on a touch device (a phone with two cameras).
  $('call-flip-btn')?.classList.toggle('hidden', !isVideo || !isTouch);
  // Filters: any video call.
  $('call-filter-btn')?.classList.toggle('hidden', !isVideo);
  ['call-screen-btn', 'call-flip-btn', 'call-filter-btn'].forEach((id) => $(id)?.classList.remove('active'));
  $('call-filter-bar')?.classList.add('hidden');

  if (isVideo && call.localStream) {
    call.cameraTrack = call.localStream.getVideoTracks()[0] || null;
    call.facingMode = call.facingMode || 'user';
    call.filterName = call.filterName || 'none';
    call.videoSender = call.pc?.getSenders().find((s) => s.track && s.track.kind === 'video') || null;
    $('call-local-video').srcObject = call.localStream;
    $('call-local-video').classList.remove('hidden');
  } else {
    $('call-local-video').classList.add('hidden');
  }
}

/** notifyPeer=true (default) tells the other side; false is used when this
 *  tab is standing down because ANOTHER of my own tabs already handled it —
 *  that case must not also send call-end/call-decline to the real peer. */
function cleanupCall(notifyPeer = true) {
  F.stopRinging();
  const call = state.call;
  if (!call) return;

  clearTimeout(call.noAnswerTimer);
  clearInterval(callDurationTimer);
  callDurationTimer = null;
  callStartedAt = null;

  cancelAnimationFrame(call._fRaf);
  try { call.screenTrack?.stop(); } catch { /* already ended */ }
  try { call._fTrack?.stop(); } catch { /* n/a */ }
  try { call._fStream?.getTracks().forEach((t) => t.stop()); } catch { /* n/a */ }
  if (call._fVideo) call._fVideo.srcObject = null;
  try { call.cameraTrack?.stop(); } catch { /* n/a */ }
  call.localStream?.getTracks().forEach((t) => t.stop());
  call.pc?.close();

  state.call = null;
  $('call-overlay').classList.add('hidden');
  $('call-screen-btn')?.classList.remove('active');
  $('call-filter-btn')?.classList.remove('active');
  $('call-flip-btn')?.classList.remove('active');
  $('call-filter-bar')?.classList.add('hidden');
  $('call-local-video').srcObject = null;
  $('call-local-video').style.transform = '';
  $('call-local-video').style.filter = '';
  $('call-local-video').classList.remove('expanded');
  $('call-remote-video').srcObject = null;

  void notifyPeer; // reserved for future use — cleanup never itself re-signals
}

function iconPhoneOff() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M10.68 13.31a16 16 0 0 0 3.41 2.6l1.27-1.27a2 2 0 0 1 2.11-.45
                     2.85 2.85 0 0 0 3.53 2.5v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07
                     19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 3 2h3a2 2 0 0 1 2 1.72
                     2.85 2.85 0 0 0 .78 4.12 2 2 0 0 1-.45 2.11z"/>
            <line x1="23" y1="1" x2="1" y2="23"/></svg>`;
}

// ═══════════════════════════════════════════════════════════
// Group calling — "start or join a room", not ring-and-accept (see the
// matching design note in hub.js's group-calling section for why). A
// deliberately SEPARATE state machine from state.call above — different
// shape entirely (N peers via a mesh, not one; join-anytime, not
// ring-then-accept) — so nothing here touches the tested 1:1 code path.
// ═══════════════════════════════════════════════════════════
//
// state.groupCall shape while active:
//   { conversationId, callType, phase: 'joining'|'active', localStream,
//     peers: Map<userId, {pc, stream, pendingRemoteIce}> }
//
// groupCallBannerState: conversationId -> Set<userId> currently in that
// room. Kept for every conversation we've heard about (not just the open
// one) so switching back to one shows the right banner immediately without
// waiting on a fresh query.

const groupCallBannerState = new Map();

function renderGroupCallBanner() {
  const banner = $('group-call-banner');
  const convo = state.conversations.get(state.activeId);
  if (!convo || convo.kind !== 'group' || !callingSupported()) {
    banner.classList.add('hidden');
    return;
  }

  const participants = groupCallBannerState.get(state.activeId);
  if (!participants || participants.size === 0) {
    banner.classList.add('hidden');
    return;
  }

  const iAmIn = state.groupCall?.conversationId === state.activeId;
  banner.classList.remove('hidden');
  $('group-call-banner-text').textContent = iAmIn
    ? `You're in this call · ${participants.size} joined`
    : `Call in progress · ${participants.size} joined`;
  $('group-call-banner-join').classList.toggle('hidden', iAmIn);
}

$('group-call-banner-join').addEventListener('click', () => startOrJoinGroupCall('video'));

async function startOrJoinGroupCall(callType) {
  const convo = state.conversations.get(state.activeId);
  if (!convo || convo.kind !== 'group') return;
  if (state.call || state.groupCall) { toast('You are already in a call.', true); return; }
  if (!callingSupported()) { toast('Calling is not supported in this browser.', true); return; }

  let localStream;
  try {
    localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: callType === 'video' });
  } catch {
    toast(`Could not access your ${callType === 'video' ? 'camera/microphone' : 'microphone'}.`, true);
    return;
  }

  // From the moment the server replies to group-call-join, the whole group
  // sees me as a participant — a failure anywhere past this point must
  // explicitly leave the room (not just clear local state), or I'm a ghost
  // in everyone else's banner/tile list. See hub.js's join comment for the
  // matching server-side half of this guarantee.
  state.groupCall = { conversationId: convo.id, callType, phase: 'joining', localStream, peers: new Map() };
  showGroupCallOverlay(convo, callType);
  sendSocket({ type: 'group-call-join', conversationId: convo.id, callType });
}

async function onGroupCallState(frame) {
  const { conversationId, participantIds } = frame;

  const set = groupCallBannerState.get(conversationId) || new Set();
  for (const id of participantIds) set.add(id);
  groupCallBannerState.set(conversationId, set);

  const call = state.groupCall;
  const isMyJoin = call && call.conversationId === conversationId && call.phase === 'joining';

  if (!isMyJoin) {
    if (conversationId === state.activeId) renderGroupCallBanner();
    return;
  }

  // This is the reply to MY OWN group-call-join — participantIds is who was
  // already there before me. I offer to each of them; nobody offers to me,
  // which is what keeps a group join glare-free (see hub.js).
  set.add(state.me.id);
  call.phase = 'active';
  if (conversationId === state.activeId) renderGroupCallBanner();

  try {
    for (const peerId of participantIds) await createGroupCallOffer(call, peerId);
  } catch (err) {
    leaveGroupCall();
    toast('Could not connect the call.', true);
    console.error('[group-call] initial offer fanout failed:', err);
  }
}

async function createGroupCallOffer(call, peerId) {
  const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
  const peer = { pc, stream: null, pendingRemoteIce: [] };
  call.peers.set(peerId, peer);
  wireGroupCallPeerConnection(call, peerId, pc);
  call.localStream.getTracks().forEach((t) => pc.addTrack(t, call.localStream)); F.applyGroupScreenShare(pc);

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  sendSocket({ type: 'group-call-offer', conversationId: call.conversationId, toUserId: peerId, sdp: offer });
  renderGroupCallTiles();
}

function onGroupCallParticipantJoined(frame) {
  const { conversationId, userId } = frame;
  const set = groupCallBannerState.get(conversationId) || new Set();
  set.add(userId);
  groupCallBannerState.set(conversationId, set);
  if (conversationId === state.activeId) renderGroupCallBanner();
  // No PC action here — if I'm in this room, the newcomer offers to ME
  // directly (onGroupCallOfferReceived); existing members never initiate.
}

async function onGroupCallOfferReceived(frame) {
  const { conversationId, fromUserId, sdp } = frame;
  const call = state.groupCall;
  if (!call || call.conversationId !== conversationId) return; // not in this room — server already validated membership before relaying, so this shouldn't fire, but don't act on a stray frame

  let peer = call.peers.get(fromUserId);
  try {
    if (!peer) {
      const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
      peer = { pc, stream: null, pendingRemoteIce: [] };
      call.peers.set(fromUserId, peer);
      wireGroupCallPeerConnection(call, fromUserId, pc);
      call.localStream.getTracks().forEach((t) => pc.addTrack(t, call.localStream)); F.applyGroupScreenShare(pc);
    }

    await peer.pc.setRemoteDescription(sdp);
    await drainGroupCallIce(peer);
    const answer = await peer.pc.createAnswer();
    await peer.pc.setLocalDescription(answer);
    sendSocket({ type: 'group-call-answer', conversationId, toUserId: fromUserId, sdp: answer });
    renderGroupCallTiles();
  } catch (err) {
    call.peers.get(fromUserId)?.pc.close();
    call.peers.delete(fromUserId);
    renderGroupCallTiles();
    console.error('[group-call] answering offer failed:', err);
  }
}

async function onGroupCallAnswerReceived(frame) {
  const { conversationId, fromUserId, sdp } = frame;
  const call = state.groupCall;
  if (!call || call.conversationId !== conversationId) return;

  const peer = call.peers.get(fromUserId);
  if (!peer) return;
  await peer.pc.setRemoteDescription(sdp);
  await drainGroupCallIce(peer);
}

async function onGroupCallIceReceived(frame) {
  const { conversationId, fromUserId, candidate } = frame;
  const call = state.groupCall;
  if (!call || call.conversationId !== conversationId) return;

  const peer = call.peers.get(fromUserId);
  if (!peer) return;

  if (!peer.pc.remoteDescription) { peer.pendingRemoteIce.push(candidate); return; }
  try { await peer.pc.addIceCandidate(candidate); } catch { /* stale/duplicate — harmless */ }
}

async function drainGroupCallIce(peer) {
  const queued = peer.pendingRemoteIce;
  peer.pendingRemoteIce = [];
  for (const candidate of queued) {
    try { await peer.pc.addIceCandidate(candidate); } catch { /* stale/duplicate — harmless */ }
  }
}

function onGroupCallParticipantLeft(frame) {
  const { conversationId, userId } = frame;
  groupCallBannerState.get(conversationId)?.delete(userId);
  if (conversationId === state.activeId) renderGroupCallBanner();

  const call = state.groupCall;
  if (!call || call.conversationId !== conversationId) return;
  const peer = call.peers.get(userId);
  if (!peer) return;
  peer.pc.close();
  call.peers.delete(userId);
  renderGroupCallTiles();
}

/** My OWN other tab already occupies my seat in this room — stand down
 *  without re-notifying the server (it already knows; it's the one that
 *  told us), mirroring 1:1 calling's call-claimed handling. */
function onGroupCallClaimedElsewhere(frame) {
  if (state.groupCall?.conversationId === frame.conversationId) teardownGroupCallLocal();
}

function onGroupCallErrorReceived(frame) {
  const call = state.groupCall;

  if (frame.peerId) {
    // A specific peer's connection is dead (they left mid-negotiation) —
    // drop that one stub instead of waiting out an ICE/DTLS timeout.
    if (call && call.conversationId === frame.conversationId) {
      const peer = call.peers.get(frame.peerId);
      if (peer) { peer.pc.close(); call.peers.delete(frame.peerId); renderGroupCallTiles(); }
    }
    return;
  }

  toast(frame.error, true);
  // No peerId means the JOIN ITSELF was rejected (full room, wrong kind) —
  // I was never actually seated server-side, so just clean up locally.
  if (call && call.conversationId === frame.conversationId && call.phase === 'joining') {
    teardownGroupCallLocal();
  }
}

function wireGroupCallPeerConnection(call, peerId, pc) {
  pc.onicecandidate = (e) => {
    if (e.candidate) {
      sendSocket({ type: 'group-call-ice', conversationId: call.conversationId, toUserId: peerId, candidate: e.candidate });
    }
  };
  pc.ontrack = (e) => {
    const peer = call.peers.get(peerId);
    if (peer) peer.stream = e.streams[0];
    renderGroupCallTiles();
  };
  pc.onconnectionstatechange = () => {
    if (['failed', 'closed'].includes(pc.connectionState) && call.peers.get(peerId)?.pc === pc) {
      pc.close();
      call.peers.delete(peerId);
      renderGroupCallTiles();
    }
  };
}

function leaveGroupCall() {
  if (!state.groupCall) return;
  sendSocket({ type: 'group-call-leave', conversationId: state.groupCall.conversationId });
  teardownGroupCallLocal();
}

function teardownGroupCallLocal() {
  F.stopGroupScreenShare();   // puts the camera back so it's stopped below
  const call = state.groupCall;
  if (!call) return;

  call.localStream?.getTracks().forEach((t) => t.stop());
  for (const peer of call.peers.values()) peer.pc.close();

  groupCallBannerState.get(call.conversationId)?.delete(state.me.id);

  state.groupCall = null;
  $('group-call-overlay').classList.add('hidden');
  if (call.conversationId === state.activeId) renderGroupCallBanner();
}

function showGroupCallOverlay(convo, callType) {
  $('group-call-overlay').classList.remove('hidden');
  $('group-call-title').textContent = convo.title;
  $('group-call-camera-btn').classList.toggle('hidden', callType !== 'video');
  $('group-call-screen-btn').classList.toggle('hidden', callType !== 'video' || !navigator.mediaDevices?.getDisplayMedia);
  renderGroupCallTiles();
}

function renderGroupCallTiles() {
  const call = state.groupCall;
  const grid = $('group-call-tiles');
  if (!call) { grid.innerHTML = ''; return; }

  const tiles = [
    { id: state.me.id, name: 'You', stream: call.localStream, muted: true },
    ...[...call.peers].map(([peerId, peer]) => ({
      id: peerId, name: groupCallPeerName(call.conversationId, peerId), stream: peer.stream, muted: false,
    })),
  ];

  grid.innerHTML = tiles.map((t) => `
    <div class="group-call-tile" data-id="${escapeAttr(t.id)}">
      ${t.stream?.getVideoTracks().length
        ? `<video class="group-call-video" autoplay playsinline ${t.muted ? 'muted' : ''}></video>`
        : `<div class="avatar lg">${avatarInner({ displayName: t.name, avatarColor: '#6C5CE7' })}</div>`}
      <div class="group-call-tile-name">${escapeHtml(t.name)}</div>
    </div>`).join('');

  for (const t of tiles) {
    if (!t.stream) continue;
    const video = grid.querySelector(`.group-call-tile[data-id="${CSS.escape(String(t.id))}"] video`);
    if (video && video.srcObject !== t.stream) video.srcObject = t.stream;
  }
}

function groupCallPeerName(conversationId, userId) {
  const members = state.groupMembers.get(conversationId) || [];
  return members.find((m) => m.id === userId)?.displayName || 'Someone';
}

$('group-call-leave-btn').addEventListener('click', leaveGroupCall);

$('group-call-mute-btn').addEventListener('click', () => {
  const track = state.groupCall?.localStream?.getAudioTracks()[0];
  if (!track) return;
  track.enabled = !track.enabled;
  $('group-call-mute-btn').classList.toggle('active', !track.enabled);
});

$('group-call-screen-btn').addEventListener('click', () => F.toggleGroupScreenShare());

$('group-call-camera-btn').addEventListener('click', () => {
  const track = state.groupCall?.localStream?.getVideoTracks()[0];
  if (!track) return;
  track.enabled = !track.enabled;
  $('group-call-camera-btn').classList.toggle('active', !track.enabled);
});

// ═══════════════════════════════════════════════════════════
// QR — my code, and scan-to-chat
// ═══════════════════════════════════════════════════════════
//
// Generation is server-side (GET /api/users/me/qr, plain PNG — the content
// is just "vesper:user:<id>", not sensitive) since a hand-rolled or vendored
// client-side QR encoder risks a subtle bug producing a silently unscannable
// code. Scanning needs the camera either way, so it's feature-detected on
// getUserMedia — decoding itself prefers the native BarcodeDetector where the
// browser has it (Chrome/Edge on Android and ChromeOS), and otherwise falls
// back to jsQR, vendored locally at /js/vendor/jsqr.min.js and lazy-loaded
// only when a scanner actually opens. That covers desktop Chrome/Edge/Firefox
// too, where BarcodeDetector isn't shipped — so scanning works everywhere a
// camera does, with no third-party script fetched at runtime.

$('qr-btn').addEventListener('click', openQrModal);

function scannerSupported() {
  return !!navigator.mediaDevices?.getUserMedia;
}

/** Loads the vendored jsQR decoder once per page load and caches the promise. */
let jsQRPromise = null;
function loadJsQR() {
  if (window.jsQR) return Promise.resolve(window.jsQR);
  if (jsQRPromise) return jsQRPromise;
  jsQRPromise = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = '/js/vendor/jsqr.min.js';
    script.onload = () => (window.jsQR ? resolve(window.jsQR) : reject(new Error('jsQR did not load')));
    script.onerror = () => reject(new Error('Could not load the QR scanner.'));
    document.head.appendChild(script);
  });
  return jsQRPromise;
}

function openQrModal() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>QR code</h3>
      <div class="qr-tabs">
        <button type="button" class="qr-tab active" data-tab="mine">My code</button>
        <button type="button" class="qr-tab" data-tab="scan">Scan</button>
      </div>
      <div class="qr-panel" id="qr-panel-mine">
        <img src="${apiUrl('/api/users/me/qr')}" alt="Your QR code" class="qr-image">
        <p class="qr-hint">Let someone scan this to start a chat with you instantly.</p>
      </div>
      <div class="qr-panel hidden" id="qr-panel-scan">
        ${scannerSupported() ? `
          <video id="qr-scan-video" autoplay playsinline muted></video>
          <p class="qr-hint" id="qr-scan-status">Point your camera at their QR code.</p>
        ` : `
          <p class="qr-hint">Camera scanning isn't supported in this browser — type
             their username instead:</p>
          <input id="qr-manual-input" placeholder="username" autocomplete="off" style="margin-top:8px;">
          <button type="button" class="btn-primary" id="qr-manual-go" style="margin-top:10px;width:100%;">Open chat</button>
        `}
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="qr-close">Close</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  let scanHandle = null;
  const close = () => { scanHandle?.stop(); box.remove(); };
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#qr-close').addEventListener('click', close);

  box.querySelectorAll('.qr-tab').forEach((tab) => {
    tab.addEventListener('click', async () => {
      box.querySelectorAll('.qr-tab').forEach((t) => t.classList.remove('active'));
      tab.classList.add('active');
      const showScan = tab.dataset.tab === 'scan';
      box.querySelector('#qr-panel-mine').classList.toggle('hidden', showScan);
      box.querySelector('#qr-panel-scan').classList.toggle('hidden', !showScan);

      if (showScan && scannerSupported() && !scanHandle) {
        scanHandle = await startQrScanner(box, (userId) => { close(); startChatWith(userId); });
      } else if (!showScan && scanHandle) {
        scanHandle.stop();
        scanHandle = null;
      }
    });
  });

  const manualGo = box.querySelector('#qr-manual-go');
  if (manualGo) {
    manualGo.addEventListener('click', async () => {
      const username = box.querySelector('#qr-manual-input').value.trim();
      if (!username) return;
      try {
        const { users } = await api('/api/users?q=' + encodeURIComponent(username));
        const match = users.find((u) => u.username.toLowerCase() === username.toLowerCase());
        if (!match) { toast('Nobody found with that exact username.', true); return; }
        close();
        startChatWith(match.id);
      } catch (err) {
        toast(err.message, true);
      }
    });
  }
}

/** Polls the camera feed for a QR code every 400ms (not every animation frame
 *  — a decode pass is real image analysis, and running it at 60fps would be
 *  wasteful for something a human is holding reasonably still). Prefers the
 *  native BarcodeDetector; falls back to the vendored jsQR decoder reading a
 *  canvas snapshot of the video frame. Calls onFound(payload) once (with the
 *  `prefix` stripped), then stops itself. Returns null if the camera itself
 *  couldn't be opened or no decoder is available — callers fall back to
 *  manual entry in that case. */
async function startQrScanner(box, onFound, prefix = 'vesper:user:') {
  const video = box.querySelector('#qr-scan-video');
  const statusEl = box.querySelector('#qr-scan-status');

  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
  } catch {
    if (statusEl) statusEl.textContent = 'Could not access your camera.';
    return null;
  }

  video.srcObject = stream;

  const nativeDetector = 'BarcodeDetector' in window ? new BarcodeDetector({ formats: ['qr_code'] }) : null;
  let decodeFrame = null;   // set below once a decoder is ready

  if (nativeDetector) {
    decodeFrame = async () => {
      const codes = await nativeDetector.detect(video);
      return codes.map((c) => c.rawValue).find((v) => v?.startsWith(prefix)) || null;
    };
  } else {
    let jsQRFn;
    try {
      if (statusEl) statusEl.textContent = 'Loading scanner…';
      jsQRFn = await loadJsQR();
    } catch (err) {
      if (statusEl) statusEl.textContent = err.message;
      stream.getTracks().forEach((t) => t.stop());
      return null;
    }
    if (statusEl) statusEl.textContent = `Point your camera at ${prefix.includes('link') ? 'the code' : 'their QR code'}.`;
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    decodeFrame = () => {
      if (!video.videoWidth) return null;
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      const frame = ctx.getImageData(0, 0, canvas.width, canvas.height);
      const code = jsQRFn(frame.data, frame.width, frame.height, { inversionAttempts: 'dontInvert' });
      return code?.data?.startsWith(prefix) ? code.data : null;
    };
  }

  const interval = setInterval(async () => {
    try {
      const match = await decodeFrame();
      if (match) {
        clearInterval(interval);
        stream.getTracks().forEach((t) => t.stop());
        onFound(match.slice(prefix.length));
      }
    } catch {
      // A decode pass can throw transiently before the video has a real
      // frame — ignore and let the next tick try again.
    }
  }, 400);

  return {
    stop: () => {
      clearInterval(interval);
      stream.getTracks().forEach((t) => t.stop());
    },
  };
}

// ═══════════════════════════════════════════════════════════
// AI Chat — talks to a locally-running Ollama model. Deliberately NOT
// end-to-end encrypted (the server has to read the text to forward it to
// Ollama), kept in its own table/route so that exception can never bleed
// into the real messaging pipeline's invariants.
// ═══════════════════════════════════════════════════════════

$('ai-chat-btn').addEventListener('click', openAiChat);
$('games-btn').addEventListener('click', openGames);

// ── Games — standalone entry point for the offline diversions (Trivia /
// Chess / Sliding puzzle). Separate from AI Chat: reachable on its own,
// not just as a fallback when Ollama is unreachable.
function openGames() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card ai-chat-card">
      <div class="ai-chat-head">
        <div class="ai-chat-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <line x1="6" y1="12" x2="10" y2="12"/><line x1="8" y1="10" x2="8" y2="14"/>
            <circle cx="15" cy="13" r="1"/><circle cx="18" cy="11" r="1"/>
            <path d="M17.32 5H6.68a4 4 0 0 0-3.98 3.55l-.79 7A4 4 0 0 0 5.9 20a4 4 0 0 0 3.16-1.55l.86-1.1a2 2 0 0 1 1.58-.77h1a2 2 0 0 1 1.58.77l.86 1.1A4 4 0 0 0 18.1 20a4 4 0 0 0 3.98-4.45l-.79-7A4 4 0 0 0 17.32 5Z"/>
          </svg>
        </div>
        <div class="grow">
          <h3>Games</h3>
          <div class="ai-chat-sub">Play offline — no connection needed</div>
        </div>
        <button type="button" class="icon-btn ai-chat-close" id="games-close" aria-label="Close">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </button>
      </div>
      <div class="ai-chat-body" id="games-body"></div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#games-close').addEventListener('click', close);

  box.querySelector('#games-body').appendChild(offlineGamesCard({ aiDown: false }));
}

async function openAiChat() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card ai-chat-card">
      <div class="ai-chat-head">
        <div class="ai-chat-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M12 3a5 5 0 0 0-5 5v1a3 3 0 0 0-2 2.83V15a3 3 0 0 0 3 3h1"/>
            <path d="M12 3a5 5 0 0 1 5 5v1a3 3 0 0 1 2 2.83V15a3 3 0 0 1-3 3h-1"/>
            <path d="M9 18v1a2 2 0 0 0 2 2h2a2 2 0 0 0 2-2v-1"/>
            <circle cx="9.5" cy="9" r="1"/><circle cx="14.5" cy="9" r="1"/>
          </svg>
        </div>
        <div class="grow">
          <h3>AI Chat</h3>
          <div class="ai-chat-sub">Powered by a local model · not end-to-end encrypted</div>
        </div>
        <button type="button" class="icon-btn ai-chat-close" id="ai-chat-close" aria-label="Close">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </button>
      </div>
      <div class="ai-chat-body" id="ai-chat-body">
        <div class="ai-chat-empty">Loading…</div>
      </div>
      <div class="ai-chat-composer">
        <textarea id="ai-chat-input" placeholder="Message the AI…" rows="1"></textarea>
        <button type="button" class="ai-chat-send" id="ai-chat-send" disabled aria-label="Send">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"
               stroke-linecap="round" stroke-linejoin="round">
            <line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/>
          </svg>
        </button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#ai-chat-close').addEventListener('click', close);

  const body = box.querySelector('#ai-chat-body');
  const input = box.querySelector('#ai-chat-input');
  const sendBtn = box.querySelector('#ai-chat-send');

  input.addEventListener('input', () => {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 120) + 'px';
    sendBtn.disabled = input.value.trim().length === 0;
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      if (!sendBtn.disabled) sendAiMessage(box);
    }
  });
  sendBtn.addEventListener('click', () => sendAiMessage(box));

  try {
    const { messages } = await api('/api/ai/messages');
    body.innerHTML = messages.length ? '' : aiEmptyHint();
    for (const m of messages) body.appendChild(aiBubble(m.role, m.content));
    body.scrollTop = body.scrollHeight;
  } catch (err) {
    body.innerHTML = `<div class="ai-chat-error">Could not load your AI chat history.<br>${escapeHtml(err.message)}</div>`;
    if (!navigator.onLine) body.appendChild(offlineGamesCard());
  }

  input.focus();
}

function aiEmptyHint() {
  return '<div class="ai-chat-empty">Ask it anything — this chat is not end-to-end ' +
    'encrypted, unlike the rest of your conversations, since the message has to be ' +
    'readable to send to the AI.</div>';
}

function aiBubble(role, text) {
  const row = document.createElement('div');
  row.className = 'bubble-row ' + (role === 'user' ? 'me' : '') + ' first-of-run last-of-run';
  row.innerHTML = `<div class="bubble ${role === 'user' ? 'me' : 'them'}"><div class="text"></div></div>`;
  row.querySelector('.text').textContent = text; // textContent, not innerHTML — model output is untrusted text
  return row;
}

async function sendAiMessage(box) {
  const input = box.querySelector('#ai-chat-input');
  const sendBtn = box.querySelector('#ai-chat-send');
  const body = box.querySelector('#ai-chat-body');

  const content = input.value.trim();
  if (!content) return;

  body.querySelector('.ai-chat-empty')?.remove();

  input.value = '';
  input.style.height = 'auto';
  sendBtn.disabled = true;

  body.appendChild(aiBubble('user', content));
  const thinking = document.createElement('div');
  thinking.className = 'ai-chat-thinking';
  thinking.textContent = 'Thinking…';
  body.appendChild(thinking);
  body.scrollTop = body.scrollHeight;

  try {
    const { assistantMessage } = await api('/api/ai/message', {
      method: 'POST',
      body: JSON.stringify({ content }),
    });
    thinking.remove();
    body.appendChild(aiBubble('assistant', assistantMessage.content));
  } catch (err) {
    thinking.remove();
    const errEl = document.createElement('div');
    errEl.className = 'ai-chat-error';
    errEl.textContent = err.message;
    body.appendChild(errEl);
    // The AI is unreachable (your internet dropped, or Ollama isn't running)
    // — offer something to do instead of leaving a dead end.
    body.appendChild(offlineGamesCard());
  }
  body.scrollTop = body.scrollHeight;
}

// ── Offline fallback: a small knowledge quiz ────────────────
// Entirely client-side and offline-capable — when the AI can't be reached,
// this gives the user something to actually do instead of staring at an
// error. Not meant to be exhaustive; just enough questions that repeats
// aren't obvious in a normal 5-question round.

const TRIVIA_BANK = [
  { q: 'Which planet is known as the Red Planet?', options: ['Venus', 'Mars', 'Jupiter', 'Saturn'], a: 1 },
  { q: 'What is the capital of Japan?', options: ['Seoul', 'Beijing', 'Tokyo', 'Bangkok'], a: 2 },
  { q: 'Who wrote the play "Romeo and Juliet"?', options: ['Charles Dickens', 'William Shakespeare', 'Mark Twain', 'Leo Tolstoy'], a: 1 },
  { q: 'What is the largest ocean on Earth?', options: ['Atlantic', 'Indian', 'Arctic', 'Pacific'], a: 3 },
  { q: 'How many continents are there on Earth?', options: ['5', '6', '7', '8'], a: 2 },
  { q: 'What gas do plants absorb from the atmosphere for photosynthesis?', options: ['Oxygen', 'Nitrogen', 'Carbon dioxide', 'Hydrogen'], a: 2 },
  { q: 'Which country is home to the Great Barrier Reef?', options: ['Brazil', 'Australia', 'Mexico', 'Indonesia'], a: 1 },
  { q: 'What is the chemical symbol for gold?', options: ['Ag', 'Au', 'Gd', 'Go'], a: 1 },
  { q: 'Who painted the Mona Lisa?', options: ['Vincent van Gogh', 'Pablo Picasso', 'Leonardo da Vinci', 'Claude Monet'], a: 2 },
  { q: 'What is the tallest mountain in the world?', options: ['K2', 'Kangchenjunga', 'Mount Everest', 'Lhotse'], a: 2 },
  { q: 'Which is the smallest country in the world?', options: ['Monaco', 'San Marino', 'Vatican City', 'Liechtenstein'], a: 2 },
  { q: 'How many strings does a standard guitar have?', options: ['4', '5', '6', '7'], a: 2 },
  { q: 'What is the main language spoken in Brazil?', options: ['Spanish', 'Portuguese', 'French', 'Italian'], a: 1 },
  { q: 'Which organ in the human body pumps blood?', options: ['Lungs', 'Liver', 'Kidney', 'Heart'], a: 3 },
  { q: 'What is the freezing point of water in Celsius?', options: ['0°C', '32°C', '-1°C', '100°C'], a: 0 },
  { q: 'Which planet has the most moons in our solar system?', options: ['Earth', 'Mars', 'Saturn', 'Mercury'], a: 2 },
  { q: 'What does "www" stand for?', options: ['World Wide Web', 'World Web Wide', 'Wide World Web', 'Web World Wide'], a: 0 },
  { q: 'Which ancient wonder still stands today?', options: ['Colossus of Rhodes', 'Great Pyramid of Giza', 'Hanging Gardens', 'Lighthouse of Alexandria'], a: 1 },
  { q: 'What is the currency of Japan?', options: ['Won', 'Yuan', 'Yen', 'Ringgit'], a: 2 },
  { q: 'Which element has the atomic number 1?', options: ['Helium', 'Hydrogen', 'Oxygen', 'Carbon'], a: 1 },
];

const TRIVIA_ROUND_LEN = 5;

// Which intro the games menu shows: the AI chat falls back to it when the
// model can't be reached; the Games button opens it directly.
let gamesMenuAiDown = true;

/** Menu of offline games — from the Games button, or as the AI chat's
 *  fallback when the model can't be reached. */
function offlineGamesCard({ aiDown = gamesMenuAiDown } = {}) {
  gamesMenuAiDown = aiDown;
  const card = document.createElement('div');
  card.className = 'ai-quiz-card';
  card.innerHTML = `
    <div class="ai-quiz-intro">
      ${aiDown
        ? "<strong>Can't reach the AI right now.</strong> Pick something to play while you wait — no connection needed:"
        : '<strong>Pick a game.</strong> Everything here works offline:'}
    </div>
    <div class="ai-games-menu">
      <button type="button" class="btn-secondary" data-game="chess-ai">♟️ Chess vs computer</button>
      <button type="button" class="btn-secondary" data-game="trivia">Trivia quiz</button>
      <button type="button" class="btn-secondary" data-game="chess">Chess — 2 players (pass &amp; play)</button>
      <button type="button" class="btn-secondary" data-game="puzzle">Sliding puzzle</button>
    </div>`;
  card.querySelectorAll('[data-game]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const g = btn.dataset.game;
      const view = g === 'trivia' ? triviaRound()
        : g === 'chess-ai' ? chessGame({ vsComputer: true })
        : g === 'chess' ? chessGame()
        : puzzleGame();
      card.replaceWith(view);
    });
  });
  return card;
}

/** Every offline game shares this shell: a "← Games" link back to the menu,
 *  plus a body element the game re-renders into. */
function gameCard(extraClass) {
  const card = document.createElement('div');
  card.className = 'ai-quiz-card' + (extraClass ? ' ' + extraClass : '');
  const back = document.createElement('button');
  back.type = 'button';
  back.className = 'ai-game-back';
  back.textContent = '← Games';
  back.addEventListener('click', () => card.replaceWith(offlineGamesCard()));
  card.appendChild(back);
  return card;
}

function triviaRound() {
  const shuffled = [...TRIVIA_BANK].sort(() => Math.random() - 0.5).slice(0, TRIVIA_ROUND_LEN);
  const card = gameCard();
  const bodyEl = document.createElement('div');
  card.appendChild(bodyEl);
  let index = 0;
  let score = 0;

  const renderQuestion = () => {
    const item = shuffled[index];
    bodyEl.innerHTML = `
      <div class="ai-quiz-progress">Question ${index + 1} of ${shuffled.length} · Score ${score}</div>
      <div class="ai-quiz-question"></div>
      <div class="ai-quiz-options"></div>`;
    bodyEl.querySelector('.ai-quiz-question').textContent = item.q;

    const optionsEl = bodyEl.querySelector('.ai-quiz-options');
    item.options.forEach((text, i) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'ai-quiz-option';
      btn.textContent = text;
      btn.addEventListener('click', () => {
        optionsEl.querySelectorAll('.ai-quiz-option').forEach((b) => { b.disabled = true; });
        if (i === item.a) {
          btn.classList.add('correct');
          score++;
        } else {
          btn.classList.add('wrong');
          optionsEl.children[item.a].classList.add('correct');
        }
        const next = document.createElement('button');
        next.type = 'button';
        next.className = 'btn-secondary ai-quiz-next';
        next.textContent = index + 1 < shuffled.length ? 'Next question' : 'See score';
        next.addEventListener('click', () => {
          index++;
          if (index < shuffled.length) renderQuestion();
          else renderFinal();
        });
        bodyEl.appendChild(next);
      }, { once: true });
      optionsEl.appendChild(btn);
    });
  };

  const renderFinal = () => {
    bodyEl.innerHTML = `
      <div class="ai-quiz-intro"><strong>${score} / ${shuffled.length}</strong> — nice one.</div>
      <button type="button" class="btn-secondary ai-quiz-again">Play again</button>`;
    bodyEl.querySelector('.ai-quiz-again').addEventListener('click', () => {
      card.replaceWith(triviaRound());
    });
  };

  renderQuestion();
  return card;
}

// ── Chess — local pass-and-play, no engine/AI opponent, no network. ─────
// Standard piece movement and check/checkmate/stalemate detection; castling
// and en passant are intentionally left out to keep this a compact, casual
// diversion rather than a full rules engine. Pawns auto-promote to queen.

const CHESS_GLYPH = {
  w: { k: '♔', q: '♕', r: '♖', b: '♗', n: '♘', p: '♙' },
  b: { k: '♚', q: '♛', r: '♜', b: '♝', n: '♞', p: '♟' },
};

function initialChessBoard() {
  const back = ['r', 'n', 'b', 'q', 'k', 'b', 'n', 'r'];
  const board = Array.from({ length: 8 }, () => Array(8).fill(null));
  for (let c = 0; c < 8; c++) {
    board[0][c] = { type: back[c], color: 'b' };
    board[1][c] = { type: 'p', color: 'b' };
    board[6][c] = { type: 'p', color: 'w' };
    board[7][c] = { type: back[c], color: 'w' };
  }
  return board;
}

function cloneChessBoard(board) {
  return board.map((row) => row.map((p) => (p ? { ...p } : null)));
}

/** Pseudo-legal moves — doesn't yet check whether the move leaves its own
 *  king in check; legalMovesFrom() filters that in. */
function chessPieceMoves(board, r, c) {
  const piece = board[r][c];
  if (!piece) return [];
  const moves = [];
  const inBounds = (rr, cc) => rr >= 0 && rr < 8 && cc >= 0 && cc < 8;
  const add = (rr, cc) => {
    if (!inBounds(rr, cc)) return;
    const t = board[rr][cc];
    if (!t || t.color !== piece.color) moves.push([rr, cc]);
  };
  const slide = (dr, dc) => {
    let rr = r + dr, cc = c + dc;
    while (inBounds(rr, cc)) {
      const t = board[rr][cc];
      if (!t) moves.push([rr, cc]);
      else { if (t.color !== piece.color) moves.push([rr, cc]); break; }
      rr += dr; cc += dc;
    }
  };

  if (piece.type === 'p') {
    const dir = piece.color === 'w' ? -1 : 1;
    if (inBounds(r + dir, c) && !board[r + dir][c]) {
      moves.push([r + dir, c]);
      const startRow = piece.color === 'w' ? 6 : 1;
      if (r === startRow && !board[r + 2 * dir][c]) moves.push([r + 2 * dir, c]);
    }
    for (const dc of [-1, 1]) {
      const rr = r + dir, cc = c + dc;
      if (inBounds(rr, cc) && board[rr][cc] && board[rr][cc].color !== piece.color) moves.push([rr, cc]);
    }
  } else if (piece.type === 'n') {
    for (const [dr, dc] of [[-2, -1], [-2, 1], [-1, -2], [-1, 2], [1, -2], [1, 2], [2, -1], [2, 1]]) add(r + dr, c + dc);
  } else if (piece.type === 'k') {
    for (const [dr, dc] of [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]]) add(r + dr, c + dc);
  } else {
    const dirs = piece.type === 'b' ? [[-1, -1], [-1, 1], [1, -1], [1, 1]]
      : piece.type === 'r' ? [[-1, 0], [1, 0], [0, -1], [0, 1]]
      : [[-1, -1], [-1, 1], [1, -1], [1, 1], [-1, 0], [1, 0], [0, -1], [0, 1]]; // queen
    for (const [dr, dc] of dirs) slide(dr, dc);
  }
  return moves;
}

/** Pawns attack diagonally only (no forward attack), so this can't just
 *  reuse chessPieceMoves for them — everything else's move list doubles as
 *  its attack list. */
function isSquareAttacked(board, r, c, byColor) {
  for (let rr = 0; rr < 8; rr++) {
    for (let cc = 0; cc < 8; cc++) {
      const p = board[rr][cc];
      if (!p || p.color !== byColor) continue;
      if (p.type === 'p') {
        const dir = p.color === 'w' ? -1 : 1;
        if (rr + dir === r && (cc - 1 === c || cc + 1 === c)) return true;
        continue;
      }
      if (chessPieceMoves(board, rr, cc).some(([mr, mc]) => mr === r && mc === c)) return true;
    }
  }
  return false;
}

function findKing(board, color) {
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      const p = board[r][c];
      if (p && p.type === 'k' && p.color === color) return [r, c];
    }
  }
  return null;
}

function applyChessMove(board, [fr, fc], [tr, tc]) {
  const next = cloneChessBoard(board);
  const piece = next[fr][fc];
  next[tr][tc] = piece;
  next[fr][fc] = null;
  if (piece.type === 'p' && (tr === 0 || tr === 7)) piece.type = 'q'; // auto-promote
  return next;
}

function legalMovesFrom(board, r, c, color) {
  const piece = board[r][c];
  if (!piece || piece.color !== color) return [];
  return chessPieceMoves(board, r, c).filter(([tr, tc]) => {
    const next = applyChessMove(board, [r, c], [tr, tc]);
    const kingPos = findKing(next, color);
    return kingPos && !isSquareAttacked(next, kingPos[0], kingPos[1], color === 'w' ? 'b' : 'w');
  });
}

function allLegalChessMoves(board, color) {
  const all = [];
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      if (board[r][c]?.color === color) all.push(...legalMovesFrom(board, r, c, color));
    }
  }
  return all;
}

// ── Chess computer opponent — runs in the browser, no server/AI model. ───
// Alpha-beta search over the same move rules as above, scoring material
// plus simple positional bonuses. In the search, moves are pseudo-legal and
// "capturing the king" ends a line (a cheap, standard way to see mate);
// only the computer's actual choice is checked for full legality.

const CHESS_VALUE = { p: 100, n: 320, b: 330, r: 500, q: 900, k: 20000 };
const CHESS_LEVELS = {
  easy: { label: 'Easy', depth: 1, noise: 80 },
  medium: { label: 'Medium', depth: 2, noise: 15 },
  hard: { label: 'Hard', depth: 4, noise: 4 },
};

function chessPositional(type, r, c, color) {
  const fromHome = color === 'w' ? 7 - r : r;          // 0 on own back rank
  const center = 3.5 - Math.max(Math.abs(3.5 - r), Math.abs(3.5 - c)); // 0.5 edge … 3.5 centre
  switch (type) {
    case 'p': return (fromHome - 1) * 8 + (c >= 2 && c <= 5 ? center * 4 : 0);
    case 'n': return center * 10 - 15;
    case 'b': return center * 6;
    case 'q': return center * 2;
    case 'k': return fromHome === 0 ? 15 : -8 * fromHome; // keep the king home
    default: return 0;
  }
}

/** Score of the position for `color` (positive = good for `color`). */
function chessEvaluate(board, color) {
  let score = 0;
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      const p = board[r][c];
      if (!p) continue;
      const v = CHESS_VALUE[p.type] + chessPositional(p.type, r, c, p.color);
      score += p.color === color ? v : -v;
    }
  }
  return score;
}

/** Pseudo-legal moves, captures first (best victim first) so alpha-beta cuts more. */
function chessPseudoMoves(board, color) {
  const moves = [];
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      if (board[r][c]?.color !== color) continue;
      for (const to of chessPieceMoves(board, r, c)) {
        const victim = board[to[0]][to[1]];
        moves.push({ from: [r, c], to, order: victim ? CHESS_VALUE[victim.type] : 0 });
      }
    }
  }
  return moves.sort((a, b) => b.order - a.order);
}

function chessSearch(board, color, depth, alpha, beta) {
  if (depth === 0) return chessEvaluate(board, color);
  const opp = color === 'w' ? 'b' : 'w';
  const moves = chessPseudoMoves(board, color);
  if (!moves.length) return 0;
  for (const m of moves) {
    if (board[m.to[0]][m.to[1]]?.type === 'k') return 100000 + depth; // king falls = win
    const score = -chessSearch(applyChessMove(board, m.from, m.to), opp, depth - 1, -beta, -alpha);
    if (score >= beta) return score;
    if (score > alpha) alpha = score;
  }
  return alpha;
}

/** The computer's move for `color`, or null when it has none. */
function chessComputerMove(board, color, level) {
  const { depth, noise } = CHESS_LEVELS[level] || CHESS_LEVELS.medium;
  const opp = color === 'w' ? 'b' : 'w';
  let best = null;
  let bestScore = -Infinity;
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      for (const to of legalMovesFrom(board, r, c, color)) {
        const next = applyChessMove(board, [r, c], to);
        let score;
        if (allLegalChessMoves(next, opp).length === 0) {
          const k = findKing(next, opp);
          score = isSquareAttacked(next, k[0], k[1], color) ? 1000000 : 0; // mate : stalemate
        } else {
          score = -chessSearch(next, opp, depth - 1, -Infinity, Infinity);
        }
        score += (Math.random() - 0.5) * 2 * noise; // a little variety; more on Easy
        if (score > bestScore) { bestScore = score; best = { from: [r, c], to }; }
      }
    }
  }
  return best;
}

function chessGame({ vsComputer = false } = {}) {
  const card = gameCard('ai-chess-card');
  const human = 'w';
  const computer = 'b';
  let level = 'medium';
  let thinking = false;

  if (vsComputer) {
    const levels = document.createElement('div');
    levels.className = 'ai-games-menu';
    levels.style.cssText = 'display:flex;gap:6px;margin:4px 0 8px';
    levels.innerHTML = Object.entries(CHESS_LEVELS).map(([key, l]) =>
      `<button type="button" class="chat-filter-tab${key === level ? ' active' : ''}" data-level="${key}" style="flex:1">${l.label}</button>`
    ).join('');
    levels.querySelectorAll('[data-level]').forEach((btn) => {
      btn.addEventListener('click', () => {
        level = btn.dataset.level;
        levels.querySelectorAll('[data-level]').forEach((b) => b.classList.toggle('active', b === btn));
      });
    });
    const hint = document.createElement('div');
    hint.className = 'ai-quiz-progress';
    hint.textContent = 'You play White ♔ — the computer plays Black ♚';
    card.append(levels, hint);
  }

  const statusEl = document.createElement('div');
  statusEl.className = 'ai-chess-status';
  const boardEl = document.createElement('div');
  boardEl.className = 'ai-chess-board';
  const newBtn = document.createElement('button');
  newBtn.type = 'button';
  newBtn.className = 'btn-secondary ai-chess-new';
  newBtn.textContent = 'New game';
  card.append(statusEl, boardEl, newBtn);

  let st = { board: initialChessBoard(), turn: 'w', selected: null, status: 'playing' };

  function evaluateStatus() {
    const kingPos = findKing(st.board, st.turn);
    const inCheck = isSquareAttacked(st.board, kingPos[0], kingPos[1], st.turn === 'w' ? 'b' : 'w');
    const hasMoves = allLegalChessMoves(st.board, st.turn).length > 0;
    st.status = hasMoves ? 'playing' : (inCheck ? 'checkmate' : 'stalemate');
  }

  function render() {
    const kingPos = findKing(st.board, st.turn);
    const inCheck = isSquareAttacked(st.board, kingPos[0], kingPos[1], st.turn === 'w' ? 'b' : 'w');
    const legalTargets = st.selected ? legalMovesFrom(st.board, st.selected[0], st.selected[1], st.turn) : [];

    boardEl.innerHTML = '';
    for (let r = 0; r < 8; r++) {
      for (let c = 0; c < 8; c++) {
        const sq = document.createElement('div');
        sq.className = 'ai-chess-sq ' + ((r + c) % 2 === 0 ? 'light' : 'dark');
        if (st.selected && st.selected[0] === r && st.selected[1] === c) sq.classList.add('selected');
        if (legalTargets.some(([mr, mc]) => mr === r && mc === c)) sq.classList.add('legal');
        if (inCheck && kingPos[0] === r && kingPos[1] === c) sq.classList.add('king-check');

        const piece = st.board[r][c];
        if (piece) {
          const span = document.createElement('span');
          span.className = 'ai-chess-piece ' + piece.color;
          span.textContent = CHESS_GLYPH[piece.color][piece.type];
          sq.appendChild(span);
        }
        sq.addEventListener('click', () => onSquareClick(r, c));
        boardEl.appendChild(sq);
      }
    }

    let text;
    if (vsComputer) {
      if (st.status === 'checkmate') text = st.turn === human ? 'Checkmate — the computer wins' : '🎉 Checkmate — you win!';
      else if (st.status === 'stalemate') text = 'Stalemate — draw';
      else if (thinking) text = 'Computer is thinking…';
      else text = st.turn === human ? (inCheck ? "Your move — you're in check!" : 'Your move') : 'Computer to move';
    } else {
      text = (st.turn === 'w' ? 'White' : 'Black') + ' to move';
      if (st.status === 'checkmate') text = 'Checkmate — ' + (st.turn === 'w' ? 'Black' : 'White') + ' wins';
      else if (st.status === 'stalemate') text = 'Stalemate — draw';
      else if (inCheck) text += ' — check!';
    }
    statusEl.textContent = text;
  }

  function computerTurn() {
    if (!vsComputer || st.status !== 'playing' || st.turn !== computer) return;
    thinking = true;
    render();
    const game = st;
    // Let the "thinking…" status paint before the (synchronous) search runs.
    setTimeout(() => {
      if (st !== game) return; // "New game" was pressed meanwhile
      const move = chessComputerMove(st.board, computer, level);
      thinking = false;
      if (move) {
        st.board = applyChessMove(st.board, move.from, move.to);
        st.turn = human;
        st.lastMove = move;
      }
      evaluateStatus();
      render();
    }, 60);
  }

  function onSquareClick(r, c) {
    if (st.status !== 'playing' || thinking) return;
    if (vsComputer && st.turn !== human) return;
    const piece = st.board[r][c];

    if (st.selected) {
      const [sr, sc] = st.selected;
      const legal = legalMovesFrom(st.board, sr, sc, st.turn);
      if (legal.some(([mr, mc]) => mr === r && mc === c)) {
        st.board = applyChessMove(st.board, [sr, sc], [r, c]);
        st.turn = st.turn === 'w' ? 'b' : 'w';
        st.selected = null;
        evaluateStatus();
        render();
        computerTurn();
        return;
      }
      st.selected = (piece && piece.color === st.turn) ? [r, c] : null;
      render();
      return;
    }

    if (piece && piece.color === st.turn) {
      st.selected = [r, c];
      render();
    }
  }

  newBtn.addEventListener('click', () => {
    st = { board: initialChessBoard(), turn: 'w', selected: null, status: 'playing' };
    thinking = false;
    render();
  });

  render();
  return card;
}

// ── Sliding puzzle — classic 15-puzzle, shuffled via random legal slides
// from the solved state so it's always solvable. ─────────────────────────

function shuffledPuzzleTiles() {
  const tiles = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0];
  let blank = 15;
  for (let i = 0; i < 200; i++) {
    const r = Math.floor(blank / 4), c = blank % 4;
    const candidates = [];
    if (r > 0) candidates.push(blank - 4);
    if (r < 3) candidates.push(blank + 4);
    if (c > 0) candidates.push(blank - 1);
    if (c < 3) candidates.push(blank + 1);
    const swap = candidates[Math.floor(Math.random() * candidates.length)];
    [tiles[blank], tiles[swap]] = [tiles[swap], tiles[blank]];
    blank = swap;
  }
  return tiles;
}

function puzzleGame() {
  const card = gameCard();
  const statusEl = document.createElement('div');
  statusEl.className = 'ai-quiz-progress';
  const boardEl = document.createElement('div');
  boardEl.className = 'ai-puzzle-board';
  const newBtn = document.createElement('button');
  newBtn.type = 'button';
  newBtn.className = 'btn-secondary ai-puzzle-new';
  newBtn.textContent = 'Shuffle again';
  card.append(statusEl, boardEl, newBtn);

  let tiles = shuffledPuzzleTiles();
  let moves = 0;

  const isSolved = () => tiles.every((v, i) => (i === 15 ? v === 0 : v === i + 1));

  function render() {
    const solved = isSolved();
    boardEl.innerHTML = '';
    tiles.forEach((v, i) => {
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = 'ai-puzzle-tile' + (v === 0 ? ' blank' : '');
      tile.textContent = v === 0 ? '' : String(v);
      // Staggered so the celebration reads as a left-to-right, top-to-bottom
      // ripple across the board rather than every tile popping at once.
      if (solved) tile.style.animationDelay = `${i * 25}ms`;
      tile.addEventListener('click', () => onTileClick(i));
      boardEl.appendChild(tile);
    });
    boardEl.classList.toggle('solved', solved);
    statusEl.classList.toggle('solved-status', solved);
    statusEl.textContent = solved ? `🎉 Solved in ${moves} moves!` : `Moves: ${moves}`;
    // render() only ever transitions INTO solved once — onTileClick refuses
    // further moves once solved, so this can't double-fire on the same win.
    if (solved) toast('🎉 Puzzle solved!');
  }

  function onTileClick(i) {
    if (isSolved()) return;
    const blank = tiles.indexOf(0);
    const r = Math.floor(i / 4), c = i % 4;
    const br = Math.floor(blank / 4), bc = blank % 4;
    if (Math.abs(r - br) + Math.abs(c - bc) !== 1) return;
    [tiles[i], tiles[blank]] = [tiles[blank], tiles[i]];
    moves++;
    render();
  }

  newBtn.addEventListener('click', () => {
    tiles = shuffledPuzzleTiles();
    moves = 0;
    render();
  });

  render();
  return card;
}

// ═══════════════════════════════════════════════════════════
// Search
// ═══════════════════════════════════════════════════════════

let searchTimer;

$('search-input').addEventListener('input', (e) => {
  const q = e.target.value.trim();
  clearTimeout(searchTimer);

  if (q.length === 0) {
    state.searching = false;
    renderChatList();
    return;
  }

  // Debounced so typing "kumar" is one request, not five.
  searchTimer = setTimeout(async () => {
    try {
      const { users } = await api('/api/users?q=' + encodeURIComponent(q));
      state.searching = true;
      renderSearchResults(users);
    } catch (err) {
      toast(err.message, true);
    }
  }, 220);
});

// ═══════════════════════════════════════════════════════════
// Misc UI
// ═══════════════════════════════════════════════════════════

$('back-btn').addEventListener('click', () => {
  $('app-screen').classList.remove('viewing-chat');
  state.activeId = null;
  renderChatList();
});

$('safety-btn').addEventListener('click', async () => {
  const convo = state.conversations.get(state.activeId);
  if (!convo || !state.publicJwk) return;

  const number = await safetyNumber(state.publicJwk, convo.peer.publicKey);
  alert(
    `Safety number with ${convo.peer.displayName}:\n\n${number}\n\n` +
    'Compare this with them over a channel you already trust (in person, a phone ' +
    'call). If it matches on both sides, nobody is intercepting this conversation.'
  );
});

// ═══════════════════════════════════════════════════════════
// Chat-head overflow menu — search in chat, wallpaper
// ═══════════════════════════════════════════════════════════

$('chat-menu-btn').addEventListener('click', (e) => {
  e.stopPropagation();
  updateChatMenuLabels();
  $('chat-menu').classList.toggle('hidden');
});
document.addEventListener('click', () => $('chat-menu').classList.add('hidden'));

$('chat-menu').addEventListener('click', (e) => {
  const action = e.target.closest('button')?.dataset.action;
  if (!action) return;
  $('chat-menu').classList.add('hidden');
  if (action === 'search') openChatSearch();
  else if (action === 'wallpaper') openWallpaperPicker();
  else if (action === 'schedule') openScheduleMessagePanel();
  else if (action === 'play-game') openLiveGamePicker();
  else if (action === 'contact-info') openContactInfo();
  else if (action === 'select-messages') enterMessageSelectMode();
  else if (action === 'mute') toggleMute();
  else if (action === 'favorite') toggleFavorite(state.activeId);
  else if (action === 'add-to-list') openAddToListPanel();
  else if (action === 'close-chat') closeActiveChat();
  else if (action === 'block') toggleBlockActiveChatPeer();
  else if (action === 'clear-chat') clearActiveChat();
  else if (action === 'delete-chat') deleteActiveChat();
  else if (action === 'disappearing') F.openDisappearingPicker();
  else if (action === 'summarize') F.openSummarize();
  else if (action === 'export') F.openExportChat();
  else if (action === 'lock-chat') F.toggleChatLock(state.conversations.get(state.activeId));
  else if (action === 'notes') F.openChatNotes();
  else if (action === 'archive') F.toggleArchive(state.conversations.get(state.activeId));
});

// ── Sidebar overflow menu — starred, select chats, mark all read, app lock ──

$('sidebar-menu-btn').addEventListener('click', (e) => {
  e.stopPropagation();
  updateVoiceCommandsMenuLabel();
  $('sidebar-menu').classList.toggle('hidden');
});
document.addEventListener('click', () => $('sidebar-menu').classList.add('hidden'));

$('sidebar-menu').addEventListener('click', (e) => {
  const action = e.target.closest('button')?.dataset.action;
  if (!action) return;
  $('sidebar-menu').classList.add('hidden');
  if (action === 'starred') openStarredMessagesPanel();
  else if (action === 'select-chats') enterChatSelectMode();
  else if (action === 'mark-all-read') markAllRead();
  else if (action === 'app-lock') openAppLockSettings();
  else if (action === 'blocked-users') openBlockedUsersPanel();
  else if (action === 'linked-devices') openLinkedDevicesPanel();
  else if (action === 'storage') openStoragePanel();
  else if (action === 'voice-commands') toggleVoiceCommands();
  else if (action === 'broadcasts') F.openBroadcastsPanel();
  else if (action === 'quick-replies') F.openQuickRepliesPanel();
  else if (action === 'security') F.openSecurityPanel();
  else if (action === 'chat-features') F.openFeatureSettings();
  else if (action === 'communities') F.openCommunities();
  else if (action === 'join-link') F.openJoinWithLink();
});

// ── Wallpaper ─────────────────────────────────────────────

// Each preset layers a couple of soft, off-center radial highlights over a
// linear base — closer to an actual lit room than a flat two-stop gradient,
// while staying dark enough for message bubbles to stay readable on top.
const WALLPAPER_PRESETS = {
  dawn:     { label: 'Dawn',     css: 'radial-gradient(circle at 20% 15%, rgba(108,92,231,.35), transparent 55%), radial-gradient(circle at 85% 80%, rgba(253,203,110,.18), transparent 50%), linear-gradient(160deg, #2B2C54, #1A1B2E)' },
  sunset:   { label: 'Sunset',   css: 'radial-gradient(circle at 15% 20%, rgba(225,112,85,.35), transparent 55%), radial-gradient(circle at 90% 85%, rgba(253,121,168,.25), transparent 50%), linear-gradient(160deg, #3A2340, #1A1B2E)' },
  forest:   { label: 'Forest',   css: 'radial-gradient(circle at 20% 20%, rgba(0,184,148,.3), transparent 55%), radial-gradient(circle at 85% 80%, rgba(85,239,196,.15), transparent 50%), linear-gradient(160deg, #123A34, #1A1B2E)' },
  ocean:    { label: 'Ocean',    css: 'radial-gradient(circle at 15% 20%, rgba(9,132,227,.3), transparent 55%), radial-gradient(circle at 90% 85%, rgba(116,185,255,.18), transparent 50%), linear-gradient(160deg, #123048, #1A1B2E)' },
  rose:     { label: 'Rose',     css: 'radial-gradient(circle at 20% 15%, rgba(232,67,147,.3), transparent 55%), radial-gradient(circle at 85% 85%, rgba(253,203,110,.12), transparent 50%), linear-gradient(160deg, #3A1D2E, #1A1B2E)' },
  slate:    { label: 'Slate',    css: 'radial-gradient(circle at 20% 20%, rgba(162,155,254,.18), transparent 55%), linear-gradient(160deg, #2A2A35, #1A1B2E)' },
  midnight: { label: 'Midnight', css: 'radial-gradient(circle at 80% 10%, rgba(9,132,227,.2), transparent 50%), radial-gradient(circle at 10% 90%, rgba(108,92,231,.22), transparent 55%), linear-gradient(160deg, #0F1226, #05060F)' },
  peach:    { label: 'Peach',    css: 'radial-gradient(circle at 20% 15%, rgba(253,203,110,.35), transparent 55%), radial-gradient(circle at 85% 85%, rgba(225,112,85,.22), transparent 50%), linear-gradient(160deg, #3D2B2A, #1A1B2E)' },
  mint:     { label: 'Mint',     css: 'radial-gradient(circle at 15% 20%, rgba(85,239,196,.28), transparent 55%), radial-gradient(circle at 90% 80%, rgba(0,206,201,.18), transparent 50%), linear-gradient(160deg, #123A3A, #1A1B2E)' },
  lavender: { label: 'Lavender', css: 'radial-gradient(circle at 20% 20%, rgba(162,155,254,.32), transparent 55%), radial-gradient(circle at 85% 80%, rgba(108,92,231,.22), transparent 50%), linear-gradient(160deg, #2E2A50, #1A1B2E)' },
  amber:    { label: 'Amber',    css: 'radial-gradient(circle at 15% 20%, rgba(253,203,110,.32), transparent 55%), radial-gradient(circle at 90% 85%, rgba(225,177,44,.2), transparent 50%), linear-gradient(160deg, #3A2E12, #1A1B2E)' },
  coral:    { label: 'Coral',    css: 'radial-gradient(circle at 20% 15%, rgba(255,118,117,.32), transparent 55%), radial-gradient(circle at 85% 85%, rgba(253,121,168,.2), transparent 50%), linear-gradient(160deg, #3A1F22, #1A1B2E)' },
};

const WALLPAPER_FIT_LABELS = { cover: 'Cover', contain: 'Fit', fill: 'Stretch', tile: 'Tile' };
const WALLPAPER_FIT_SIZES = { cover: 'cover', contain: 'contain', fill: '100% 100%' };

function applyWallpaper(convo) {
  const el = $('messages');
  if (convo?.wallpaper === 'photo' && convo.wallpaperPhotoUrl) {
    const fit = convo.wallpaperFit || 'cover';
    // Two layers: a dark scrim (does the same job the preset gradients' dark
    // base does — keeps message bubbles legible over a busy image), then the
    // photo itself. background-size/repeat/position each need one value per
    // layer, in the same order — the scrim's own values barely matter since
    // a gradient has no natural size to fit/tile, but the count must match.
    el.style.background = `linear-gradient(rgba(10,10,20,.55), rgba(10,10,20,.55)), url("${apiUrl(convo.wallpaperPhotoUrl)}")`;
    if (fit === 'tile') {
      el.style.backgroundSize = 'auto, auto';
      el.style.backgroundRepeat = 'no-repeat, repeat';
      el.style.backgroundPosition = 'center, top left';
    } else {
      el.style.backgroundSize = `auto, ${WALLPAPER_FIT_SIZES[fit] || 'cover'}`;
      el.style.backgroundRepeat = 'no-repeat, no-repeat';
      el.style.backgroundPosition = 'center, center';
    }
    return;
  }
  const preset = convo?.wallpaper ? WALLPAPER_PRESETS[convo.wallpaper] : null;
  el.style.background = preset ? preset.css : '';
  el.style.backgroundSize = '';
  el.style.backgroundRepeat = '';
  el.style.backgroundPosition = '';
}

function openWallpaperPicker() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Chat wallpaper</h3>
      <div class="wallpaper-grid">
        <button type="button" class="wallpaper-swatch ${!convo.wallpaper ? 'active' : ''}"
                data-key="" style="background:var(--panel-2)">Default</button>
        <label class="wallpaper-swatch wallpaper-photo-tile ${convo.wallpaper === 'photo' ? 'active' : ''}"
               id="wallpaper-photo-tile"
               style="${convo.wallpaperPhotoUrl ? `background-image:url('${escapeAttr(apiUrl(convo.wallpaperPhotoUrl))}')` : ''}">
          <input type="file" id="wallpaper-photo-input" accept="image/jpeg,image/png,image/webp" class="hidden">
          <span>${convo.wallpaperPhotoUrl ? 'Change photo' : '+ Upload photo'}</span>
        </label>
        ${Object.entries(WALLPAPER_PRESETS).map(([key, p]) => `
          <button type="button" class="wallpaper-swatch ${convo.wallpaper === key ? 'active' : ''}"
                  data-key="${key}" style="background:${p.css}">${escapeHtml(p.label)}</button>
        `).join('')}
      </div>
      <div class="wallpaper-fit-row">
        <span class="wallpaper-fit-label">Photo fit</span>
        <div class="chat-filter-tabs wallpaper-fit-tabs">
          ${Object.entries(WALLPAPER_FIT_LABELS).map(([key, label]) => `
            <button type="button" class="chat-filter-tab wallpaper-fit-btn ${(convo.wallpaperFit || 'cover') === key ? 'active' : ''}"
                    data-fit="${key}">${escapeHtml(label)}</button>
          `).join('')}
          <button type="button" class="btn-primary wallpaper-fit-apply" id="wallpaper-fit-apply">Set</button>
        </div>
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="wallpaper-close">Close</button>
      </div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#wallpaper-close').addEventListener('click', close);

  box.querySelectorAll('.wallpaper-swatch[data-key]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const key = btn.dataset.key || null;
      const prev = convo.wallpaper;
      convo.wallpaper = key; // optimistic
      applyWallpaper(convo);
      box.querySelectorAll('.wallpaper-swatch').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      try {
        await api(`/api/conversations/${convo.id}/wallpaper`, {
          method: 'PATCH',
          body: JSON.stringify({ wallpaper: key }),
        });
      } catch (err) {
        convo.wallpaper = prev;
        applyWallpaper(convo);
        toast(err.message, true);
      }
    });
  });

  box.querySelector('#wallpaper-photo-input').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    e.target.value = '';
    if (!file) return;

    const tile = $('wallpaper-photo-tile');
    const label = tile.querySelector('span');
    const original = label.textContent;
    label.textContent = 'Uploading…';

    try {
      const form = new FormData();
      form.append('photo', file);
      const { wallpaperPhotoUrl } = await api(`/api/conversations/${convo.id}/wallpaper-photo`, {
        method: 'POST', body: form,
      });
      convo.wallpaper = 'photo';
      convo.wallpaperPhotoUrl = wallpaperPhotoUrl + '?t=' + Date.now(); // bust the cache on replace
      applyWallpaper(convo);
      close();
      toast('Wallpaper updated.');
    } catch (err) {
      label.textContent = original;
      toast(err.message, true);
    }
  });

  // Picking a fit tab only previews the selection (just the active-tab
  // highlight) — it doesn't touch the actual wallpaper until "Set" is
  // pressed, unlike the preset/photo tiles above which apply instantly.
  let pendingFit = convo.wallpaperFit || 'cover';
  box.querySelectorAll('.wallpaper-fit-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      pendingFit = btn.dataset.fit;
      box.querySelectorAll('.wallpaper-fit-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
    });
  });

  box.querySelector('#wallpaper-fit-apply').addEventListener('click', async () => {
    const prev = convo.wallpaperFit || 'cover';
    if (pendingFit === prev) { close(); return; }

    const applyBtn = box.querySelector('#wallpaper-fit-apply');
    applyBtn.disabled = true;
    convo.wallpaperFit = pendingFit;
    applyWallpaper(convo);
    try {
      await api(`/api/conversations/${convo.id}/wallpaper-fit`, {
        method: 'PATCH',
        body: JSON.stringify({ fit: pendingFit }),
      });
      toast('Wallpaper updated.');
      close();
    } catch (err) {
      convo.wallpaperFit = prev;
      applyWallpaper(convo);
      applyBtn.disabled = false;
      toast(err.message, true);
    }
  });
}

// ═══════════════════════════════════════════════════════════
// Reminders — Web Push notifications, delivered even with the
// app/browser closed (see public/sw.js and src/reminders-scheduler.js).
// ═══════════════════════════════════════════════════════════

const REMINDER_CATEGORIES = {
  birthday: { label: 'Birthday', emoji: '🎂' },
  happy:    { label: 'Happy',    emoji: '😊' },
  love:     { label: 'Love',     emoji: '❤️' },
  sad:      { label: 'Sad',      emoji: '🤗' },
  breakup:  { label: 'Breakup',  emoji: '💙' },
  general:  { label: 'General',  emoji: '⏰' },
};

function urlBase64ToUint8Array(base64) {
  const padding = '='.repeat((4 - base64.length % 4) % 4);
  const normalized = (base64 + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(normalized);
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}

/**
 * Registers the service worker, asks for notification permission, and
 * subscribes to push — all three are required before a reminder can
 * actually reach this browser. Safe to call repeatedly (e.g. every time the
 * Reminders panel opens): each step is a no-op if already done, and
 * subscribe() returns the existing subscription instead of creating a new
 * one if one's already active.
 */
async function ensurePushSubscription() {
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
    return { ok: false, reason: 'unsupported' };
  }

  try {
    const reg = await navigator.serviceWorker.register('/sw.js');

    let permission = Notification.permission;
    if (permission === 'default') permission = await Notification.requestPermission();
    if (permission !== 'granted') return { ok: false, reason: 'denied' };

    let sub = await reg.pushManager.getSubscription();
    if (!sub) {
      const { publicKey } = await api('/api/push/vapid-public-key');
      if (!publicKey) return { ok: false, reason: 'unconfigured' };
      sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(publicKey),
      });
    }

    await api('/api/push/subscribe', {
      method: 'POST',
      body: JSON.stringify({ subscription: sub.toJSON() }),
    });
    return { ok: true };
  } catch (err) {
    return { ok: false, reason: err.message };
  }
}

$('reminders-btn').addEventListener('click', openRemindersPanel);

async function openRemindersPanel() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Reminders</h3>
      <div class="reminder-notice hidden" id="reminder-notice"></div>
      <div class="field">
        <label>What's this about?</label>
        <textarea id="reminder-content-input" rows="2" maxlength="2000"
                  placeholder="e.g. Priya's birthday, call mom, project deadline…"></textarea>
      </div>
      <div class="field">
        <label>Type</label>
        <select id="reminder-category-input">
          ${Object.entries(REMINDER_CATEGORIES).map(([key, c]) => `
            <option value="${key}">${c.emoji} ${escapeHtml(c.label)}</option>
          `).join('')}
        </select>
      </div>
      <div class="field">
        <label>When</label>
        <input type="datetime-local" id="reminder-when-input">
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="reminders-close">Close</button>
        <button type="button" class="btn-primary" id="reminder-add-btn">Add reminder</button>
      </div>
      <div class="reminder-list" id="reminder-list"></div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#reminders-close').addEventListener('click', close);

  // Default to an hour from now — close enough to be a plausible pick,
  // never in the past (which the backend would reject anyway).
  // datetime-local wants a LOCAL wall-clock string, but toISOString() always
  // prints as UTC — shifting the timestamp by the timezone offset first is
  // the standard way to get toISOString() to print local numbers instead.
  const whenInput = box.querySelector('#reminder-when-input');
  const soon = new Date(Date.now() + 60 * 60 * 1000);
  whenInput.value = new Date(soon.getTime() - soon.getTimezoneOffset() * 60000).toISOString().slice(0, 16);

  const notice = box.querySelector('#reminder-notice');
  const pushResult = await ensurePushSubscription();
  if (!pushResult.ok) {
    const messages = {
      unsupported: "This browser doesn't support push notifications — reminders will still save, but nothing will notify you.",
      denied: 'Notifications are blocked for this site — allow them in your browser settings or reminders will just silently save with no alert.',
      unconfigured: 'Push notifications aren\'t set up on this server yet.',
    };
    notice.textContent = messages[pushResult.reason] || 'Could not enable notifications for reminders.';
    notice.classList.remove('hidden');
  }

  async function loadList() {
    const list = box.querySelector('#reminder-list');
    list.innerHTML = '<div class="empty-hint">Loading…</div>';
    try {
      const { reminders } = await api('/api/reminders');
      if (reminders.length === 0) {
        list.innerHTML = '<div class="empty-hint">No reminders yet.</div>';
        return;
      }
      list.innerHTML = reminders.map((r) => {
        const cat = REMINDER_CATEGORIES[r.category] || REMINDER_CATEGORIES.general;
        return `
          <div class="reminder-item">
            <div class="reminder-item-emoji">${cat.emoji}</div>
            <div class="reminder-item-body">
              <div class="reminder-item-content">${escapeHtml(r.content)}</div>
              <div class="reminder-item-when">${escapeHtml(cat.label)} · ${dayLabel(r.remindAt)} at ${shortTime(r.remindAt)}${r.notifiedAt ? ' · sent' : ''}</div>
            </div>
            <button type="button" class="icon-btn reminder-item-delete" aria-label="Delete reminder" data-id="${escapeAttr(r.id)}">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>
                <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
              </svg>
            </button>
          </div>`;
      }).join('');

      list.querySelectorAll('.reminder-item-delete').forEach((btn) => {
        btn.addEventListener('click', async () => {
          btn.disabled = true;
          try {
            await api(`/api/reminders/${btn.dataset.id}`, { method: 'DELETE' });
            loadList();
          } catch (err) {
            btn.disabled = false;
            toast(err.message, true);
          }
        });
      });
    } catch (err) {
      list.innerHTML = `<div class="empty-hint">${escapeHtml(err.message)}</div>`;
    }
  }

  box.querySelector('#reminder-add-btn').addEventListener('click', async () => {
    const content = box.querySelector('#reminder-content-input').value.trim();
    const category = box.querySelector('#reminder-category-input').value;
    const whenVal = whenInput.value;
    if (!content) { toast('Write what this reminder is about.', true); return; }
    if (!whenVal) { toast('Pick a date and time.', true); return; }

    const btn = box.querySelector('#reminder-add-btn');
    btn.disabled = true;
    try {
      await api('/api/reminders', {
        method: 'POST',
        body: JSON.stringify({ content, category, remindAt: new Date(whenVal).toISOString() }),
      });
      box.querySelector('#reminder-content-input').value = '';
      toast('Reminder set.');
      await loadList();
    } catch (err) {
      toast(err.message, true);
    } finally {
      btn.disabled = false;
    }
  });

  loadList();
}

// ═══════════════════════════════════════════════════════════
// Scheduled messages — pick a date/time and this chat gets a real message
// at that moment, even if you're not online when it fires. Unlike Reminders
// (which are necessarily plaintext — the server has to act on them itself),
// this one stays fully end-to-end encrypted: the browser encrypts the text
// with the conversation's key right now, at scheduling time, and the server
// just holds onto ciphertext it can't read until send_at arrives (see
// db/schema.sql's note on scheduled_messages for why that's safe to do
// ahead of time). Two ways to pick the text: write it yourself, or let the
// app generate one from the category, using the same warmth-by-category
// idea as Reminders' notification titles.
// ═══════════════════════════════════════════════════════════

const SCHEDULED_MESSAGE_TEMPLATES = {
  birthday: [
    '🎂 Happy Birthday! Wishing you a year full of joy, health, and everything good.',
    '🎉 Happy Birthday! Hope your day is as wonderful as you are.',
    "🎈 Happy Birthday! Here's to another great year ahead.",
  ],
  happy: [
    '😊 Just wanted to say — hope this made you smile today!',
    '🌟 Thinking of you and hoping today is a good one.',
    '🥳 Celebrating this moment with you!',
  ],
  love: [
    "❤️ Just a little reminder that you're loved.",
    '💕 Thinking of you today, always.',
    '💖 Sending you all my love.',
  ],
  sad: [
    "🤗 Sending you strength today — you're not alone in this.",
    "💙 It's okay to not be okay. Take it one moment at a time.",
    "🫂 Thinking of you — I'm here if you need to talk.",
  ],
  breakup: [
    '💙 Healing takes time — be gentle with yourself today.',
    '🌤️ This chapter closing makes room for something better.',
    '🫶 You deserve peace and someone who matches your effort.',
  ],
  general: ['⏰ Just checking in with you.'],
};

function openScheduleMessagePanel() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;

  const targetName = convo.kind === 'group' ? convo.title : (convo.peer?.displayName || 'them');

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Schedule a message</h3>
      <div class="field">
        <label>How should the message be picked?</label>
        <div class="chat-filter-tabs schedule-mode-tabs">
          <button type="button" class="chat-filter-tab schedule-mode-btn active" data-mode="auto">Automatic</button>
          <button type="button" class="chat-filter-tab schedule-mode-btn" data-mode="manual">Type my own</button>
        </div>
      </div>
      <div class="field" id="schedule-category-field">
        <label>Type</label>
        <select id="schedule-category-input">
          ${Object.entries(REMINDER_CATEGORIES).map(([key, c]) => `
            <option value="${key}">${c.emoji} ${escapeHtml(c.label)}</option>
          `).join('')}
        </select>
      </div>
      <div class="field hidden" id="schedule-manual-field">
        <label>Message to ${escapeHtml(targetName)}</label>
        <textarea id="schedule-manual-input" rows="3" maxlength="4000" placeholder="Type the exact message to send…"></textarea>
      </div>
      <div class="field">
        <label>Send at</label>
        <input type="datetime-local" id="schedule-when-input">
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="schedule-close">Close</button>
        <button type="button" class="btn-primary" id="schedule-add-btn">Schedule</button>
      </div>
      <div class="reminder-list" id="schedule-list"></div>
    </div>`;
  document.body.appendChild(box);

  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#schedule-close').addEventListener('click', close);

  const whenInput = box.querySelector('#schedule-when-input');
  const soon = new Date(Date.now() + 60 * 60 * 1000);
  whenInput.value = new Date(soon.getTime() - soon.getTimezoneOffset() * 60000).toISOString().slice(0, 16);

  let mode = 'auto';
  box.querySelectorAll('.schedule-mode-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      mode = btn.dataset.mode;
      box.querySelectorAll('.schedule-mode-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      box.querySelector('#schedule-category-field').classList.toggle('hidden', mode !== 'auto');
      box.querySelector('#schedule-manual-field').classList.toggle('hidden', mode !== 'manual');
    });
  });

  async function loadScheduledList() {
    const list = box.querySelector('#schedule-list');
    list.innerHTML = '<div class="empty-hint">Loading…</div>';
    try {
      const { scheduledMessages } = await api(`/api/conversations/${convo.id}/scheduled-messages`);
      if (scheduledMessages.length === 0) {
        list.innerHTML = '<div class="empty-hint">Nothing scheduled yet.</div>';
        return;
      }

      const key = await keyFor(convo);
      const items = await Promise.all(scheduledMessages.map(async (m) => {
        let text;
        try { text = await decryptText(key, m.ciphertext, m.iv); } catch { text = '(could not decrypt)'; }
        return { ...m, text };
      }));

      list.innerHTML = items.map((m) => `
        <div class="reminder-item">
          <div class="reminder-item-emoji">🕒</div>
          <div class="reminder-item-body">
            <div class="reminder-item-content">${escapeHtml(m.text)}</div>
            <div class="reminder-item-when">To ${escapeHtml(targetName)} · ${dayLabel(m.sendAt)} at ${shortTime(m.sendAt)}</div>
          </div>
          <button type="button" class="icon-btn reminder-item-delete" aria-label="Cancel" data-id="${escapeAttr(m.id)}">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>
              <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
            </svg>
          </button>
        </div>`).join('');

      list.querySelectorAll('.reminder-item-delete').forEach((btn) => {
        btn.addEventListener('click', async () => {
          btn.disabled = true;
          try {
            await api(`/api/conversations/${convo.id}/scheduled-messages/${btn.dataset.id}`, { method: 'DELETE' });
            loadScheduledList();
          } catch (err) {
            btn.disabled = false;
            toast(err.message, true);
          }
        });
      });
    } catch (err) {
      list.innerHTML = `<div class="empty-hint">${escapeHtml(err.message)}</div>`;
    }
  }

  box.querySelector('#schedule-add-btn').addEventListener('click', async () => {
    const whenVal = whenInput.value;
    if (!whenVal) { toast('Pick a date and time.', true); return; }

    let text;
    if (mode === 'manual') {
      text = box.querySelector('#schedule-manual-input').value.trim();
      if (!text) { toast('Type the message to send.', true); return; }
    } else {
      const category = box.querySelector('#schedule-category-input').value;
      const templates = SCHEDULED_MESSAGE_TEMPLATES[category] || SCHEDULED_MESSAGE_TEMPLATES.general;
      text = templates[Math.floor(Math.random() * templates.length)];
    }

    const btn = box.querySelector('#schedule-add-btn');
    btn.disabled = true;
    try {
      const key = await keyFor(convo);
      const { ciphertext, iv } = await encryptText(key, text);
      await api(`/api/conversations/${convo.id}/scheduled-messages`, {
        method: 'POST',
        body: JSON.stringify({ ciphertext, iv, sendAt: new Date(whenVal).toISOString() }),
      });
      toast('Message scheduled.');
      box.querySelector('#schedule-manual-input').value = '';
      await loadScheduledList();
    } catch (err) {
      toast(err.message, true);
    } finally {
      btn.disabled = false;
    }
  });

  loadScheduledList();
}

// ═══════════════════════════════════════════════════════════
// Live games — Ludo & Candy Crush, played in real time with whoever
// you're chatting with, over the same WebSocket the app already uses for
// calling's signaling relay (see hub.js's onGameSignal — one generic
// frame type, `data.kind` says what it means, exactly like a call's SDP
// offer/answer/ICE). The server never sees game state, only relays it.
//
// Ludo is kept in sync by REPLAY, not by sending full board state: it's
// fully deterministic, so whoever's turn it is performs an action locally
// (roll the die, or pick a token) and just tells the other side what
// happened; the other side runs the exact same pure function and arrives
// at the exact same result. Candy Crush is different — each player's
// board is their OWN independent puzzle (same starting layout via a
// shared seed, so it's a fair duel), so there's nothing to replay; the
// only thing that crosses the wire is each side's live score. Pong is a
// third pattern again — continuous physics can't be replayed (two
// browsers' requestAnimationFrame timing drifts, so "run the same
// function" doesn't stay in sync like Ludo's discrete turns do) and
// there's no independent board to keep separate like Candy Crush, so it's
// HOST-AUTHORITATIVE instead: only the inviter ever simulates the ball,
// broadcasting {ball, scores, own paddle} a few times a second; the guest
// just renders that plus its own instantly-local paddle, and sends its
// paddle position back the same way.
// ═══════════════════════════════════════════════════════════

const LIVE_GAMES = {
  ludo: { label: 'Ludo', emoji: '🎲' },
  chess: { label: 'Chess', emoji: '♟️' },
  'candy-crush': { label: 'Candy Crush', emoji: '🍬' },
  pong: { label: 'Pong', emoji: '🏓' },
  tictactoe: { label: 'Tic-tac-toe', emoji: '❌' },
  snakes: { label: 'Snake & Ladder', emoji: '🐍' },
};

function sendGameSignal(data) {
  const g = state.liveGame;
  if (!g) return;
  sendSocket({ type: 'game-signal', conversationId: g.conversationId, toUserId: g.peerId, data });
}

function openLiveGamePicker() {
  const convo = state.conversations.get(state.activeId);
  if (!convo || convo.kind !== 'direct') { toast('Live games are 1:1 only, for now.', true); return; }
  if (!convo.peer?.id) return;
  if (!state.online.has(convo.peer.id)) {
    toast(`${convo.peer.displayName} is offline — they need to be online to play.`, true);
    return;
  }
  if (state.liveGame) { toast('Finish or leave your current game first.', true); return; }

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Play with ${escapeHtml(convo.peer.displayName)}</h3>
      <div class="wallpaper-grid">
        ${Object.entries(LIVE_GAMES).map(([key, g]) => `
          <button type="button" class="wallpaper-swatch game-pick-btn" data-game="${key}" style="background:var(--panel-3)">
            <span style="font-size:20px">${g.emoji}</span>&nbsp; ${escapeHtml(g.label)}
          </button>
        `).join('')}
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="game-picker-close">Close</button>
      </div>
    </div>`;
  document.body.appendChild(box);
  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#game-picker-close').addEventListener('click', close);

  box.querySelectorAll('.game-pick-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      close();
      inviteToGame(convo, btn.dataset.game);
    });
  });
}

function inviteToGame(convo, game) {
  state.liveGame = {
    conversationId: convo.id,
    peerId: convo.peer.id,
    peerName: convo.peer.displayName,
    game,
    role: 'host',
    phase: 'inviting',
  };
  sendGameSignal({ kind: 'invite', game });
  showGameWaitingBanner();
}

function showGameWaitingBanner() {
  closeGameWaitingBanner();
  const g = state.liveGame;
  const meta = LIVE_GAMES[g.game];
  const box = document.createElement('div');
  box.className = 'game-invite-banner';
  box.id = 'game-waiting-banner';
  box.innerHTML = `
    <div class="game-invite-emoji">${meta.emoji}</div>
    <div class="game-invite-body">
      <div class="game-invite-title">Waiting for ${escapeHtml(g.peerName)}…</div>
      <div class="game-invite-sub">${escapeHtml(meta.label)} invite sent</div>
    </div>
    <button type="button" class="btn-secondary" id="game-waiting-cancel">Cancel</button>`;
  document.body.appendChild(box);
  box.querySelector('#game-waiting-cancel').addEventListener('click', () => {
    sendGameSignal({ kind: 'leave' });
    state.liveGame = null;
    box.remove();
  });
}

function closeGameWaitingBanner() { $('game-waiting-banner')?.remove(); }
function removeGameInviteBanner() { $('game-invite-banner')?.remove(); }

function renderIncomingInviteBanner() {
  removeGameInviteBanner();
  const inv = state.pendingGameInvite;
  if (!inv) return;
  const meta = LIVE_GAMES[inv.game] || { label: inv.game, emoji: '🎮' };
  const box = document.createElement('div');
  box.className = 'game-invite-banner';
  box.id = 'game-invite-banner';
  box.innerHTML = `
    <div class="game-invite-emoji">${meta.emoji}</div>
    <div class="game-invite-body">
      <div class="game-invite-title">${escapeHtml(inv.peerName)} wants to play</div>
      <div class="game-invite-sub">${escapeHtml(meta.label)}</div>
    </div>
    <button type="button" class="btn-secondary" id="game-invite-decline">Decline</button>
    <button type="button" class="btn-primary" id="game-invite-accept">Accept</button>`;
  document.body.appendChild(box);

  box.querySelector('#game-invite-accept').addEventListener('click', () => {
    state.liveGame = {
      conversationId: inv.conversationId, peerId: inv.peerId, peerName: inv.peerName,
      game: inv.game, role: 'guest', phase: 'active',
    };
    sendSocket({
      type: 'game-signal', conversationId: inv.conversationId, toUserId: inv.peerId,
      data: { kind: 'accept' },
    });
    state.pendingGameInvite = null;
    box.remove();
    startGameUI();
  });
  box.querySelector('#game-invite-decline').addEventListener('click', () => {
    sendSocket({
      type: 'game-signal', conversationId: inv.conversationId, toUserId: inv.peerId,
      data: { kind: 'decline' },
    });
    state.pendingGameInvite = null;
    box.remove();
  });
}

function onGameSignal(frame) {
  const { conversationId, fromUserId, data } = frame;

  if (data.kind === 'invite') {
    if (state.liveGame || state.pendingGameInvite) {
      sendSocket({
        type: 'game-signal', conversationId, toUserId: fromUserId,
        data: { kind: 'decline', reason: 'busy' },
      });
      return;
    }
    const convo = state.conversations.get(conversationId);
    state.pendingGameInvite = {
      conversationId, peerId: fromUserId,
      peerName: convo?.peer?.displayName || 'Someone', game: data.game,
    };
    renderIncomingInviteBanner();
    return;
  }

  // Anything else only matters if it's about the game we're currently in.
  if (!state.liveGame || state.liveGame.conversationId !== conversationId || state.liveGame.peerId !== fromUserId) {
    return;
  }

  switch (data.kind) {
    case 'accept':
      state.liveGame.phase = 'active';
      closeGameWaitingBanner();
      startGameUI();
      break;
    case 'decline':
      toast(`${state.liveGame.peerName} declined${data.reason === 'busy' ? ' — already in a game' : ''}.`, true);
      closeGameWaitingBanner();
      state.liveGame = null;
      break;
    case 'move':
      applyRemoteGameMove(data.move);
      break;
    case 'end':
      applyRemoteGameEnd(data.result);
      break;
    case 'leave':
      toast(`${state.liveGame.peerName} left the game.`, true);
      teardownLiveGame();
      break;
  }
}

function startGameUI() {
  const g = state.liveGame;
  if (g.game === 'ludo') startLudoGame();
  else if (g.game === 'chess') startLiveChessGame();
  else if (g.game === 'candy-crush') startCandyCrushGame();
  else if (g.game === 'pong') startPongGame();
  else if (g.game === 'tictactoe') F.startTicTacToe();
  else if (g.game === 'snakes') F.startSnakes();
}

function applyRemoteGameMove(move) {
  const g = state.liveGame;
  if (!g) return;
  if (g.game === 'ludo') {
    if (move.type === 'roll') applyLudoRoll(move.value);
    else if (move.type === 'pick') applyLudoPick(move.tokenIndex);
  } else if (g.game === 'chess') {
    if (move.type === 'chess-move') applyLiveChessMove(move.from, move.to);
  } else if (g.game === 'candy-crush') {
    if (move.type === 'candy-init') onCandyRemoteInit(move.seed, move.startAt);
    else if (move.type === 'score') onCandyRemoteScore(move.value);
  } else if (g.game === 'pong') {
    if (move.type === 'pong-init') onPongRemoteInit(move.startAt);
    else if (move.type === 'pong-state') onPongRemoteState(move.state);
    else if (move.type === 'pong-paddle') onPongRemotePaddle(move.y);
  } else if (g.game === 'tictactoe') {
    F.applyTicTacToeMove(move);
  } else if (g.game === 'snakes') {
    F.applySnakesMove(move);
  }
}

function applyRemoteGameEnd(result) {
  const g = state.liveGame;
  if (!g) return;
  if (g.game === 'candy-crush') onCandyRemoteEnd(result);
  else if (g.game === 'pong') onPongRemoteEnd(result);
}

function leaveLiveGame() {
  if (state.liveGame) sendGameSignal({ kind: 'leave' });
  teardownLiveGame();
}

function teardownLiveGame() {
  const p = state.liveGame?.pong;
  if (p) {
    if (p.rafId) cancelAnimationFrame(p.rafId);
    p.resizeObserver?.disconnect();
    if (p.onKeyDown) window.removeEventListener('keydown', p.onKeyDown);
    if (p.onKeyUp) window.removeEventListener('keyup', p.onKeyUp);
  }
  $('live-game-modal')?.remove();
  closeGameWaitingBanner();
  removeGameInviteBanner();
  state.liveGame = null;
}

// ── Ludo ──────────────────────────────────────────────────────
// Board is the classic 52-square ring, generated (not hand-typed) by
// walking the perimeter of a 14×14 grid — 4×14-4 = 52, so it lines up
// exactly with a real Ludo main track's length. Each color's 4 tokens
// start in a "yard" (off-board) and need a 6 to enter, at which point a
// token's position is (that color's entry cell + steps traveled) mod 52;
// reaching 52 steps means home. Two colors only, entering at opposite
// points on the ring (0 and 26) for a fair 2-player race.

const LUDO_GRID_SIZE = 14;
const LUDO_RING_LEN = 52;
const LUDO_SAFE = new Set([0, 13, 26, 39]);
const LUDO_ENTRY = { host: 0, guest: 26 };

const LUDO_RING = (() => {
  const n = LUDO_GRID_SIZE;
  const cells = [];
  for (let c = 0; c < n; c++) cells.push([0, c]);
  for (let r = 1; r < n; r++) cells.push([r, n - 1]);
  for (let c = n - 2; c >= 0; c--) cells.push([n - 1, c]);
  for (let r = n - 2; r >= 1; r--) cells.push([r, 0]);
  return cells;
})();

function newLudoState() {
  return {
    tokens: { host: [-1, -1, -1, -1], guest: [-1, -1, -1, -1] },
    turn: 'host',
    dice: null,
    winner: null,
  };
}

function ludoAbsPos(player, steps) {
  return (LUDO_ENTRY[player] + steps) % LUDO_RING_LEN;
}

function ludoLegalTokens(ludo, player, dice) {
  const legal = [];
  ludo.tokens[player].forEach((steps, i) => {
    if (steps >= LUDO_RING_LEN) return;
    if (steps === -1) { if (dice === 6) legal.push(i); return; }
    if (steps + dice <= LUDO_RING_LEN) legal.push(i);
  });
  return legal;
}

function startLudoGame() {
  state.liveGame.ludo = newLudoState();
  openLiveGameModal('🎲 Ludo', 'ludo-board', 'ludo-controls');
  renderLudo();
}

function applyLudoRoll(value) {
  const ludo = state.liveGame?.ludo;
  if (!ludo || ludo.winner) return;
  ludo.dice = value;
  if (ludoLegalTokens(ludo, ludo.turn, value).length === 0) {
    ludo.dice = null;
    ludo.turn = ludo.turn === 'host' ? 'guest' : 'host';
  }
  renderLudo();
}

function applyLudoPick(tokenIndex) {
  const g = state.liveGame;
  const ludo = g?.ludo;
  if (!ludo || ludo.winner || ludo.dice == null) return;

  const player = ludo.turn;
  const opponent = player === 'host' ? 'guest' : 'host';
  const dice = ludo.dice;
  const tokens = ludo.tokens[player];

  tokens[tokenIndex] = tokens[tokenIndex] === -1 ? 0 : tokens[tokenIndex] + dice;

  if (tokens[tokenIndex] < LUDO_RING_LEN) {
    const landedAbs = ludoAbsPos(player, tokens[tokenIndex]);
    if (!LUDO_SAFE.has(landedAbs)) {
      ludo.tokens[opponent] = ludo.tokens[opponent].map((s) =>
        (s >= 0 && s < LUDO_RING_LEN && ludoAbsPos(opponent, s) === landedAbs) ? -1 : s
      );
    }
  }

  const rolledSix = dice === 6;
  ludo.dice = null;
  if (tokens.every((s) => s >= LUDO_RING_LEN)) {
    ludo.winner = player;
  } else if (!rolledSix) {
    ludo.turn = opponent;
  }
  renderLudo();
}

function renderLudo() {
  const g = state.liveGame;
  if (!g || g.game !== 'ludo') return;
  const board = $('ludo-board');
  const controls = $('ludo-controls');
  if (!board || !controls) return;
  const ludo = g.ludo;

  const ringHtml = LUDO_RING.map(([r, c], i) => {
    const safe = LUDO_SAFE.has(i);
    const hostDots = ludo.tokens.host.filter((s) => s >= 0 && s < LUDO_RING_LEN && ludoAbsPos('host', s) === i)
      .map(() => '<span class="ludo-token host"></span>').join('');
    const guestDots = ludo.tokens.guest.filter((s) => s >= 0 && s < LUDO_RING_LEN && ludoAbsPos('guest', s) === i)
      .map(() => '<span class="ludo-token guest"></span>').join('');
    return `<div class="ludo-cell${safe ? ' safe' : ''}" style="grid-row:${r + 1};grid-column:${c + 1}">${hostDots}${guestDots}</div>`;
  }).join('');
  board.innerHTML = ringHtml + `<div class="ludo-home" style="grid-row:6/9;grid-column:6/9">🏠</div>`;

  const myRole = g.role;
  const isMyTurn = ludo.turn === myRole && !ludo.winner;
  const dice = ludo.dice;
  const legal = dice ? ludoLegalTokens(ludo, ludo.turn, dice) : [];

  const tokenChips = (player) => ludo.tokens[player].map((s, idx) => {
    const label = s === -1 ? 'Yard' : s >= LUDO_RING_LEN ? 'Home 🏁' : `#${s + 1}`;
    const clickable = isMyTurn && player === myRole && dice != null && legal.includes(idx);
    return `<button type="button" class="ludo-chip ${player}${clickable ? ' clickable' : ''}" data-token="${idx}" ${clickable ? '' : 'disabled'}>
      T${idx + 1}<br><small>${label}</small>
    </button>`;
  }).join('');

  const statusText = ludo.winner
    ? (ludo.winner === myRole ? '🎉 You won!' : `${escapeHtml(g.peerName)} won.`)
    : isMyTurn
      ? (dice ? `You rolled ${dice} — pick a token` : 'Your turn — roll the dice')
      : `Waiting for ${escapeHtml(g.peerName)}…`;

  controls.innerHTML = `
    <div class="ludo-status${ludo.winner ? ' solved-status' : ''}">${statusText}</div>
    <div class="ludo-players-row">
      <div class="ludo-player-tokens">${tokenChips('host')}</div>
      <button type="button" class="btn-primary ludo-roll-btn" id="ludo-roll" ${isMyTurn && dice == null && !ludo.winner ? '' : 'disabled'}>
        🎲 ${dice ?? 'Roll'}
      </button>
      <div class="ludo-player-tokens">${tokenChips('guest')}</div>
    </div>`;

  $('ludo-roll')?.addEventListener('click', () => {
    const value = 1 + Math.floor(Math.random() * 6);
    applyLudoRoll(value);
    sendGameSignal({ kind: 'move', move: { type: 'roll', value } });
  });
  controls.querySelectorAll('.ludo-chip.clickable').forEach((btn) => {
    btn.addEventListener('click', () => {
      const tokenIndex = Number(btn.dataset.token);
      applyLudoPick(tokenIndex);
      sendGameSignal({ kind: 'move', move: { type: 'pick', tokenIndex } });
    });
  });
}

// ── Chess (live) ─────────────────────────────────────────────
// Reuses the exact same rules engine as the offline pass-and-play Chess
// game above (initialChessBoard/applyChessMove/legalMovesFrom/etc.) — the
// only things that differ are turn-gating by network role instead of "pass
// the device", and broadcasting each move instead of applying it straight
// to local state. Same replay-sync approach as Ludo: whoever's turn it is
// moves locally, then tells the other side which two squares — chess is
// just as deterministic as Ludo, so that's all either side ever needs.

function liveChessMyColor() {
  return state.liveGame.role === 'host' ? 'w' : 'b';
}

function startLiveChessGame() {
  state.liveGame.chess = { board: initialChessBoard(), turn: 'w', selected: null, status: 'playing' };
  openLiveGameModal('♟️ Chess', 'live-chess-board', 'ludo-controls', 'ai-chess-board');
  renderLiveChess();
}

function applyLiveChessMove(from, to) {
  const st = state.liveGame?.chess;
  if (!st || st.status !== 'playing') return;

  st.board = applyChessMove(st.board, from, to);
  st.turn = st.turn === 'w' ? 'b' : 'w';
  st.selected = null;

  const kingPos = findKing(st.board, st.turn);
  const inCheck = !!kingPos && isSquareAttacked(st.board, kingPos[0], kingPos[1], st.turn === 'w' ? 'b' : 'w');
  const hasMoves = allLegalChessMoves(st.board, st.turn).length > 0;
  st.status = hasMoves ? 'playing' : (inCheck ? 'checkmate' : 'stalemate');
  renderLiveChess();
}

function onLiveChessSquareClick(r, c) {
  const g = state.liveGame;
  const st = g?.chess;
  if (!st || st.status !== 'playing') return;
  const myColor = liveChessMyColor();
  if (st.turn !== myColor) return; // not your turn — clicks are inert

  const piece = st.board[r][c];

  if (st.selected) {
    const [sr, sc] = st.selected;
    const legal = legalMovesFrom(st.board, sr, sc, st.turn);
    if (legal.some(([mr, mc]) => mr === r && mc === c)) {
      const from = [sr, sc], to = [r, c];
      applyLiveChessMove(from, to);
      sendGameSignal({ kind: 'move', move: { type: 'chess-move', from, to } });
      return;
    }
    st.selected = (piece && piece.color === st.turn) ? [r, c] : null;
    renderLiveChess();
    return;
  }

  if (piece && piece.color === myColor) {
    st.selected = [r, c];
    renderLiveChess();
  }
}

function renderLiveChess() {
  const g = state.liveGame;
  if (!g || g.game !== 'chess') return;
  const boardEl = $('live-chess-board');
  const controls = $('ludo-controls');
  if (!boardEl || !controls) return;
  const st = g.chess;
  const myColor = liveChessMyColor();

  const kingPos = findKing(st.board, st.turn);
  const inCheck = !!kingPos && isSquareAttacked(st.board, kingPos[0], kingPos[1], st.turn === 'w' ? 'b' : 'w');
  const legalTargets = st.selected ? legalMovesFrom(st.board, st.selected[0], st.selected[1], st.turn) : [];

  boardEl.innerHTML = '';
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      const sq = document.createElement('div');
      sq.className = 'ai-chess-sq ' + ((r + c) % 2 === 0 ? 'light' : 'dark');
      if (st.selected && st.selected[0] === r && st.selected[1] === c) sq.classList.add('selected');
      if (legalTargets.some(([mr, mc]) => mr === r && mc === c)) sq.classList.add('legal');
      if (inCheck && kingPos[0] === r && kingPos[1] === c) sq.classList.add('king-check');

      const piece = st.board[r][c];
      if (piece) {
        const span = document.createElement('span');
        span.className = 'ai-chess-piece ' + piece.color;
        span.textContent = CHESS_GLYPH[piece.color][piece.type];
        sq.appendChild(span);
      }
      sq.addEventListener('click', () => onLiveChessSquareClick(r, c));
      boardEl.appendChild(sq);
    }
  }

  let text;
  if (st.status === 'checkmate') {
    const winnerColor = st.turn === 'w' ? 'b' : 'w';
    text = winnerColor === myColor ? '🎉 Checkmate — you win!' : 'Checkmate — you lose.';
  } else if (st.status === 'stalemate') {
    text = "Stalemate — it's a draw.";
  } else if (st.turn === myColor) {
    text = inCheck ? "Your move — you're in check!" : 'Your move';
  } else {
    text = `Waiting for ${escapeHtml(g.peerName)}…${inCheck ? ' (in check)' : ''}`;
  }

  controls.innerHTML = `
    <div class="ludo-status${st.status !== 'playing' ? ' solved-status' : ''}">${text}</div>
    <div class="live-chess-hint">You're playing ${myColor === 'w' ? 'White ♔' : 'Black ♚'}</div>`;
}

// ── Candy Crush duel ─────────────────────────────────────────
// Not a shared board — a timed duel on two INDEPENDENT boards that start
// identical (same PRNG seed, chosen by the host and sent along with the
// invite acceptance) so it's a fair "who scores more" race. Nothing about
// moves needs to cross the wire, only each side's live score, which is
// why this is so much simpler to keep in sync than Ludo.

const CANDY_EMOJI = ['🍬', '🍭', '🍫', '🍪', '🍩', '🍡'];
const CANDY_GRID = 8;
const CANDY_DURATION_MS = 90_000;

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function findCandyMatches(grid) {
  const n = CANDY_GRID;
  const toClear = new Set();
  for (let r = 0; r < n; r++) {
    let start = 0;
    for (let c = 1; c <= n; c++) {
      const same = c < n && grid[r * n + c] === grid[r * n + start] && grid[r * n + c] !== -1;
      if (!same) {
        if (c - start >= 3) for (let k = start; k < c; k++) toClear.add(r * n + k);
        start = c;
      }
    }
  }
  for (let c = 0; c < n; c++) {
    let start = 0;
    for (let r = 1; r <= n; r++) {
      const same = r < n && grid[r * n + c] === grid[start * n + c] && grid[r * n + c] !== -1;
      if (!same) {
        if (r - start >= 3) for (let k = start; k < r; k++) toClear.add(k * n + c);
        start = r;
      }
    }
  }
  return toClear;
}

function applyCandyGravity(grid, rand) {
  const n = CANDY_GRID;
  for (let c = 0; c < n; c++) {
    let write = n - 1;
    for (let r = n - 1; r >= 0; r--) {
      if (grid[r * n + c] !== -1) { grid[write * n + c] = grid[r * n + c]; write--; }
    }
    for (let r = write; r >= 0; r--) grid[r * n + c] = Math.floor(rand() * CANDY_EMOJI.length);
  }
}

function startCandyCrushGame() {
  const g = state.liveGame;
  // The host picks the seed (so both boards match) and sends it as part of
  // accepting isn't right — host already sent the invite, so instead the
  // host generates it now and includes it in the FIRST move message; the
  // guest, who received 'accept'-less (they sent accept), waits for it.
  const seed = g.role === 'host' ? Math.floor(Math.random() * 2 ** 31) : null;

  g.candy = {
    seed,
    rand: null,
    grid: null,
    score: 0,
    peerScore: 0,
    selected: null,
    startAt: null,
    ended: false,
    myFinal: null,
    peerFinal: null,
  };

  openLiveGameModal('🍬 Candy Crush', 'candy-board', 'candy-controls');

  if (g.role === 'host') {
    const startAt = Date.now() + 1500;
    g.candy.startAt = startAt;
    initCandyBoard(seed);
    sendGameSignal({ kind: 'move', move: { type: 'candy-init', seed, startAt } });
    renderCandy();
    scheduleCandyEnd();
  } else {
    renderCandy(); // shows "waiting for board…" until candy-init arrives
  }
}

function initCandyBoard(seed) {
  const c = state.liveGame.candy;
  c.rand = mulberry32(seed);
  c.grid = Array.from({ length: CANDY_GRID * CANDY_GRID }, () => Math.floor(c.rand() * CANDY_EMOJI.length));
}

function scheduleCandyEnd() {
  const c = state.liveGame.candy;
  const delay = Math.max(0, c.startAt + CANDY_DURATION_MS - Date.now());
  setTimeout(() => finishCandyRound(), delay);
  // Redraw once a second so the countdown visibly ticks.
  const tick = setInterval(() => {
    if (!state.liveGame?.candy || state.liveGame.candy.ended) { clearInterval(tick); return; }
    renderCandy();
  }, 1000);
}

function finishCandyRound() {
  const c = state.liveGame?.candy;
  if (!c || c.ended) return;
  c.ended = true;
  c.myFinal = c.score;
  sendGameSignal({ kind: 'end', result: { score: c.score } });
  renderCandy();
}

/** Guest-side only — the host generates the shared seed (so both boards
 *  start identical) and a synced start time, then sends both here. */
function onCandyRemoteInit(seed, startAt) {
  const g = state.liveGame;
  if (!g || g.game !== 'candy-crush') return;
  g.candy.seed = seed;
  g.candy.startAt = startAt;
  initCandyBoard(seed);
  renderCandy();
  scheduleCandyEnd();
}

function onCandyRemoteScore(value) {
  const c = state.liveGame?.candy;
  if (!c) return;
  c.peerScore = value;
  renderCandy();
}

function onCandyRemoteEnd(result) {
  const c = state.liveGame?.candy;
  if (!c) return;
  c.peerFinal = result.score;
  c.peerScore = result.score;
  if (!c.ended) finishCandyRound();
  else renderCandy();
}

function candyTrySwap(i, j) {
  const c = state.liveGame.candy;
  if (c.ended || !c.grid) return;
  [c.grid[i], c.grid[j]] = [c.grid[j], c.grid[i]];
  let matches = findCandyMatches(c.grid);
  if (matches.size === 0) {
    [c.grid[i], c.grid[j]] = [c.grid[j], c.grid[i]];
    return;
  }
  let cleared = 0;
  let chain = 0;
  while (matches.size > 0) {
    cleared += matches.size;
    chain++;
    for (const idx of matches) c.grid[idx] = -1;
    applyCandyGravity(c.grid, c.rand);
    matches = findCandyMatches(c.grid);
  }
  c.score += cleared * 10 + (chain - 1) * 15; // small bonus for chain reactions
  sendGameSignal({ kind: 'move', move: { type: 'score', value: c.score } });
  renderCandy();
}

function renderCandy() {
  const g = state.liveGame;
  if (!g || g.game !== 'candy-crush') return;
  const board = $('candy-board');
  const controls = $('candy-controls');
  if (!board || !controls) return;
  const c = g.candy;

  if (!c.grid) {
    board.innerHTML = `<div class="empty-hint">Setting up the board…</div>`;
  } else {
    board.innerHTML = c.grid.map((v, i) => `
      <button type="button" class="candy-cell${c.selected === i ? ' selected' : ''}" data-i="${i}" ${c.ended ? 'disabled' : ''}>
        ${v === -1 ? '' : CANDY_EMOJI[v]}
      </button>`).join('');
    board.querySelectorAll('.candy-cell').forEach((btn) => {
      btn.addEventListener('click', () => onCandyCellClick(Number(btn.dataset.i)));
    });
  }

  const remainingSec = c.startAt ? Math.max(0, Math.ceil((c.startAt + CANDY_DURATION_MS - Date.now()) / 1000)) : 0;
  const timerLabel = c.startAt
    ? `${Math.floor(remainingSec / 60)}:${String(remainingSec % 60).padStart(2, '0')}`
    : '—';

  let resultLine = '';
  if (c.ended) {
    if (c.myFinal != null && c.peerFinal != null) {
      resultLine = c.myFinal === c.peerFinal ? "🤝 It's a tie!"
        : c.myFinal > c.peerFinal ? '🎉 You won!' : `${escapeHtml(g.peerName)} won.`;
    } else {
      resultLine = 'Waiting for final score…';
    }
  }

  controls.innerHTML = `
    <div class="candy-scores">
      <div class="candy-score you">You<br><b>${c.score}</b></div>
      <div class="candy-timer">${c.ended ? '⏱️ 0:00' : `⏱️ ${timerLabel}`}</div>
      <div class="candy-score them">${escapeHtml(g.peerName)}<br><b>${c.peerScore}</b></div>
    </div>
    ${resultLine ? `<div class="ludo-status solved-status">${resultLine}</div>` : ''}`;
}

function onCandyCellClick(i) {
  const c = state.liveGame.candy;
  if (c.ended) return;
  if (c.selected == null) { c.selected = i; renderCandy(); return; }
  if (c.selected === i) { c.selected = null; renderCandy(); return; }

  const n = CANDY_GRID;
  const a = c.selected, b = i;
  const adjacent = (Math.abs(Math.floor(a / n) - Math.floor(b / n)) + Math.abs(a % n - b % n)) === 1;
  c.selected = null;
  if (adjacent) candyTrySwap(a, b);
  else renderCandy();
}

// ── Pong ──────────────────────────────────────────────────────
// Host-authoritative (see the "Live games" comment above). Physics run in
// a fixed, height-normalized coordinate system — y is a 0..1 fraction of
// court height, x is 0..PONG_ASPECT (so 1 unit means the same physical
// size on both axes, keeping collision math and the drawn circle/paddles
// consistent) — completely independent of the canvas's actual on-screen
// pixel size. That's what makes this "responsive for free": the host
// might be a wide desktop window and the guest a narrow phone, and the
// exact same ball/paddle numbers are still correct on both, because
// drawing just multiplies by whatever this device's own canvas height is
// at that moment (see resizePongCanvas, driven by a ResizeObserver so
// rotating a phone or resizing a window reflows it immediately).

const PONG_ASPECT = 16 / 9;
const PONG_WIN_SCORE = 7;
const PONG_PADDLE_HALF_H = 0.11;
const PONG_PADDLE_HALF_W = 0.018;
const PONG_PADDLE_X_INSET = 0.09;
const PONG_BALL_R = 0.02;
const PONG_BASE_SPEED = 1;      // court-heights per second
const PONG_SPEED_UP = 1.05;     // per paddle hit
const PONG_MAX_SPEED = 2.4;     // cap, so long rallies don't get unplayable
const PONG_BROADCAST_MS = 50;   // ~20Hz for both host->guest state and guest->host paddle
const PONG_SERVE_DELAY_MS = 900;

function startPongGame() {
  const g = state.liveGame;
  g.pong = {
    myY: 0.5, peerY: 0.5,
    ball: { x: PONG_ASPECT / 2, y: 0.5, vx: 0, vy: 0 },
    renderBall: { x: PONG_ASPECT / 2, y: 0.5 }, // guest-side smoothed position
    hostScore: 0, guestScore: 0,
    phase: 'countdown',   // 'countdown' | 'playing' | 'ended'
    winner: null,
    startAt: g.role === 'host' ? Date.now() + PONG_SERVE_DELAY_MS : null,
    lastFrameTime: 0, lastBroadcast: 0, lastPaddleSend: 0,
    rafId: null, resizeObserver: null,
    canvas: null, ctx: null, cssW: 0, cssH: 0,
    keys: { up: false, down: false },
    onKeyDown: null, onKeyUp: null,
  };

  openLiveGameModal('🏓 Pong', 'pong-board', 'pong-controls', 'pong-board');
  initPongCanvas();

  if (g.role === 'host') {
    sendGameSignal({ kind: 'move', move: { type: 'pong-init', startAt: g.pong.startAt } });
    g.pong.rafId = requestAnimationFrame(pongHostTick);
  } else {
    g.pong.rafId = requestAnimationFrame(pongGuestTick);
  }
  renderPong();
}

function initPongCanvas() {
  const p = state.liveGame.pong;
  const board = $('pong-board');
  board.innerHTML = '<canvas id="pong-canvas"></canvas>';
  const canvas = $('pong-canvas');
  p.canvas = canvas;
  p.ctx = canvas.getContext('2d');

  resizePongCanvas();
  p.resizeObserver = new ResizeObserver(() => resizePongCanvas());
  p.resizeObserver.observe(board);

  // pointermove alone (no pointerdown needed) covers both input styles at
  // once: mouse just needs to hover, and touch only ever fires move while
  // an actual finger is down, which is exactly "drag to move the paddle".
  const onPointer = (e) => {
    const g2 = state.liveGame;
    if (!g2 || g2.game !== 'pong' || g2.pong.phase === 'ended') return;
    const rect = canvas.getBoundingClientRect();
    if (!rect.height) return;
    const frac = (e.clientY - rect.top) / rect.height;
    g2.pong.myY = Math.min(1 - PONG_PADDLE_HALF_H, Math.max(PONG_PADDLE_HALF_H, frac));
  };
  canvas.addEventListener('pointermove', onPointer);
  canvas.addEventListener('pointerdown', onPointer);

  p.onKeyDown = (e) => {
    if (state.liveGame?.game !== 'pong') return;
    if (e.key === 'ArrowUp') { p.keys.up = true; e.preventDefault(); }
    else if (e.key === 'ArrowDown') { p.keys.down = true; e.preventDefault(); }
  };
  p.onKeyUp = (e) => {
    if (e.key === 'ArrowUp') p.keys.up = false;
    else if (e.key === 'ArrowDown') p.keys.down = false;
  };
  window.addEventListener('keydown', p.onKeyDown);
  window.addEventListener('keyup', p.onKeyUp);
}

/** Backing-store resolution follows the canvas's actual CSS box (via
 *  ResizeObserver) × devicePixelRatio, so it stays crisp and correctly
 *  sized on any screen without ever forcing a fixed pixel width — the
 *  same class of bug fixed today in the composer/message layout. */
function resizePongCanvas() {
  const p = state.liveGame?.pong;
  if (!p || !p.canvas) return;
  const rect = p.canvas.getBoundingClientRect();
  if (!rect.width || !rect.height) return;
  const dpr = window.devicePixelRatio || 1;
  p.canvas.width = Math.round(rect.width * dpr);
  p.canvas.height = Math.round(rect.height * dpr);
  p.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  p.cssW = rect.width;
  p.cssH = rect.height;
  renderPong();
}

function pongApplyKeyboard(p, dt) {
  const speed = 0.9; // court-heights per second
  if (p.keys.up) p.myY -= speed * dt;
  if (p.keys.down) p.myY += speed * dt;
  p.myY = Math.min(1 - PONG_PADDLE_HALF_H, Math.max(PONG_PADDLE_HALF_H, p.myY));
}

function pongHostTick(ts) {
  const g = state.liveGame;
  const p = g?.pong;
  if (!p || !$('pong-board')) return;
  if (p.phase === 'ended') { renderPong(); return; }

  if (!p.lastFrameTime) p.lastFrameTime = ts;
  const dt = Math.min(0.05, (ts - p.lastFrameTime) / 1000);
  p.lastFrameTime = ts;

  pongApplyKeyboard(p, dt);

  if (p.phase === 'countdown') {
    if (Date.now() >= p.startAt) { p.phase = 'playing'; pongResetBall(p); }
  } else {
    pongStepPhysics(p, dt);
  }

  renderPong();
  if (p.phase === 'ended') return;

  if (ts - p.lastBroadcast >= PONG_BROADCAST_MS) {
    p.lastBroadcast = ts;
    sendGameSignal({
      kind: 'move',
      move: { type: 'pong-state', state: {
        ballX: p.ball.x, ballY: p.ball.y,
        hostY: p.myY, hostScore: p.hostScore, guestScore: p.guestScore,
      } },
    });
  }
  p.rafId = requestAnimationFrame(pongHostTick);
}

function pongGuestTick(ts) {
  const g = state.liveGame;
  const p = g?.pong;
  if (!p || !$('pong-board')) return;
  if (p.phase === 'ended') { renderPong(); return; }

  if (!p.lastFrameTime) p.lastFrameTime = ts;
  const dt = Math.min(0.05, (ts - p.lastFrameTime) / 1000);
  p.lastFrameTime = ts;

  pongApplyKeyboard(p, dt);

  if (p.phase === 'countdown') {
    if (p.startAt && Date.now() >= p.startAt) p.phase = 'playing';
  } else {
    // Host only broadcasts ~20x/second — lerp toward the latest known
    // position each rendered frame instead of snapping, so the ball still
    // reads as smooth 60fps motion on the guest's screen. The exponential
    // factor (rather than a flat multiplier) keeps the smoothing feel the
    // same regardless of the guest's actual display refresh rate.
    const t = 1 - Math.pow(0.7, dt * 60);
    p.renderBall.x += (p.ball.x - p.renderBall.x) * t;
    p.renderBall.y += (p.ball.y - p.renderBall.y) * t;
  }

  renderPong();
  if (p.phase === 'ended') return;

  if (ts - p.lastPaddleSend >= PONG_BROADCAST_MS) {
    p.lastPaddleSend = ts;
    sendGameSignal({ kind: 'move', move: { type: 'pong-paddle', y: p.myY } });
  }
  p.rafId = requestAnimationFrame(pongGuestTick);
}

function pongStepPhysics(p, dt) {
  const b = p.ball;
  const prevX = b.x;
  b.x += b.vx * dt;
  b.y += b.vy * dt;

  if (b.y - PONG_BALL_R <= 0 || b.y + PONG_BALL_R >= 1) {
    b.vy *= -1;
    b.y = Math.min(1 - PONG_BALL_R, Math.max(PONG_BALL_R, b.y));
  }

  // Checking for a plane CROSSING (prevX vs. new x), not just "is x within
  // the paddle's band right now" — a fast ball can move further than the
  // paddle's own thickness in a single frame and would otherwise tunnel
  // straight through without ever registering a hit.
  const leftPlane = PONG_PADDLE_X_INSET + PONG_PADDLE_HALF_W + PONG_BALL_R;
  const rightPlane = PONG_ASPECT - PONG_PADDLE_X_INSET - PONG_PADDLE_HALF_W - PONG_BALL_R;

  if (b.vx < 0 && prevX > leftPlane && b.x <= leftPlane && Math.abs(b.y - p.myY) <= PONG_PADDLE_HALF_H) {
    b.x = leftPlane;
    pongBounceOffPaddle(p, p.myY, 1);
  } else if (b.vx > 0 && prevX < rightPlane && b.x >= rightPlane && Math.abs(b.y - p.peerY) <= PONG_PADDLE_HALF_H) {
    b.x = rightPlane;
    pongBounceOffPaddle(p, p.peerY, -1);
  } else if (b.x < -0.1) {
    p.guestScore++;
    pongOnScore(p);
  } else if (b.x > PONG_ASPECT + 0.1) {
    p.hostScore++;
    pongOnScore(p);
  }
}

function pongBounceOffPaddle(p, paddleY, dirSign) {
  const b = p.ball;
  const offset = Math.max(-1, Math.min(1, (b.y - paddleY) / PONG_PADDLE_HALF_H));
  const speed = Math.min(PONG_MAX_SPEED, Math.hypot(b.vx, b.vy) * PONG_SPEED_UP);
  const angle = offset * 0.9; // steeper hits nearer the paddle's edge
  b.vx = Math.cos(angle) * speed * dirSign;
  b.vy = Math.sin(angle) * speed;
}

function pongResetBall(p) {
  p.ball.x = PONG_ASPECT / 2;
  p.ball.y = 0.5;
  const angle = Math.random() * 0.6 - 0.3;
  const dir = Math.random() < 0.5 ? -1 : 1;
  p.ball.vx = Math.cos(angle) * PONG_BASE_SPEED * dir;
  p.ball.vy = Math.sin(angle) * PONG_BASE_SPEED;
}

function pongOnScore(p) {
  if (pongCheckWin(p)) return;
  pongResetBall(p);
}

function pongCheckWin(p) {
  if (p.hostScore < PONG_WIN_SCORE && p.guestScore < PONG_WIN_SCORE) return false;
  p.phase = 'ended';
  p.winner = p.hostScore > p.guestScore ? 'host' : 'guest';
  p.ball.vx = 0;
  p.ball.vy = 0;
  sendGameSignal({ kind: 'end', result: { winner: p.winner, hostScore: p.hostScore, guestScore: p.guestScore } });
  return true;
}

function onPongRemoteInit(startAt) {
  const p = state.liveGame?.pong;
  if (!p) return;
  p.startAt = startAt;
}

function onPongRemoteState(s) {
  const p = state.liveGame?.pong;
  if (!p) return;
  p.ball.x = s.ballX;
  p.ball.y = s.ballY;
  p.peerY = s.hostY;
  p.hostScore = s.hostScore;
  p.guestScore = s.guestScore;
}

function onPongRemotePaddle(y) {
  const p = state.liveGame?.pong;
  if (!p) return;
  p.peerY = y;
}

function onPongRemoteEnd(result) {
  const p = state.liveGame?.pong;
  if (!p) return;
  p.phase = 'ended';
  p.winner = result.winner;
  p.hostScore = result.hostScore;
  p.guestScore = result.guestScore;
  renderPong();
}

function renderPong() {
  const g = state.liveGame;
  if (!g || g.game !== 'pong') return;
  const p = g.pong;
  const ctx = p.ctx;
  const controls = $('pong-controls');
  if (!ctx || !controls || !p.canvas) return;
  const w = p.cssW || p.canvas.clientWidth;
  const h = p.cssH || p.canvas.clientHeight;
  if (!w || !h) return;

  ctx.clearRect(0, 0, w, h);

  ctx.strokeStyle = 'rgba(255,255,255,0.18)';
  ctx.lineWidth = 2;
  ctx.setLineDash([6, 8]);
  ctx.beginPath();
  ctx.moveTo(w / 2, 0);
  ctx.lineTo(w / 2, h);
  ctx.stroke();
  ctx.setLineDash([]);

  const isHost = g.role === 'host';
  // Host is always simulated on the left, guest on the right — each side
  // just draws "my paddle" on whichever edge that role owns; the ball's
  // x,y arrive already correct for both since they're absolute in that
  // same shared frame.
  const myXUnits = isHost ? PONG_PADDLE_X_INSET : PONG_ASPECT - PONG_PADDLE_X_INSET;
  const peerXUnits = isHost ? PONG_ASPECT - PONG_PADDLE_X_INSET : PONG_PADDLE_X_INSET;

  pongDrawPaddle(ctx, h, myXUnits, p.myY, '#A76BC9');
  pongDrawPaddle(ctx, h, peerXUnits, p.peerY, '#7EE8C0');

  const ballPos = isHost ? p.ball : p.renderBall;
  ctx.fillStyle = '#F3ECFA';
  ctx.beginPath();
  ctx.arc(ballPos.x * h, ballPos.y * h, PONG_BALL_R * h, 0, Math.PI * 2);
  ctx.fill();

  const myScore = isHost ? p.hostScore : p.guestScore;
  const peerScore = isHost ? p.guestScore : p.hostScore;

  let statusLine = '';
  if (p.phase === 'countdown') {
    const secs = Math.max(0, Math.ceil(((p.startAt ?? Date.now()) - Date.now()) / 1000));
    statusLine = secs > 0 ? `Get ready… ${secs}` : 'Go!';
  } else if (p.phase === 'ended') {
    const iWon = (isHost && p.winner === 'host') || (!isHost && p.winner === 'guest');
    statusLine = iWon ? '🎉 You won!' : `${escapeHtml(g.peerName)} won.`;
  }

  controls.innerHTML = `
    <div class="candy-scores">
      <div class="candy-score you">You<br><b>${myScore}</b></div>
      <div class="candy-timer">🏓</div>
      <div class="candy-score them">${escapeHtml(g.peerName)}<br><b>${peerScore}</b></div>
    </div>
    ${statusLine ? `<div class="ludo-status${p.phase === 'ended' ? ' solved-status' : ''}">${statusLine}</div>` : ''}`;
}

function pongDrawPaddle(ctx, h, xUnits, yFrac, color) {
  const pw = PONG_PADDLE_HALF_W * 2 * h;
  const ph = PONG_PADDLE_HALF_H * 2 * h;
  const x = xUnits * h - pw / 2;
  const y = yFrac * h - ph / 2;
  ctx.fillStyle = color;
  ctx.beginPath();
  if (ctx.roundRect) ctx.roundRect(x, y, pw, ph, Math.min(6, pw / 2));
  else ctx.rect(x, y, pw, ph);
  ctx.fill();
}

// ── Shared modal shell ──────────────────────────────────────

function openLiveGameModal(title, boardId, controlsId, boardClass = boardId) {
  $('live-game-modal')?.remove();
  const g = state.liveGame;
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.id = 'live-game-modal';
  box.innerHTML = `
    <div class="modal-card live-game-card">
      <h3>${title} — you vs ${escapeHtml(g.peerName)}</h3>
      <div class="${boardClass}" id="${boardId}"></div>
      <div class="${controlsId}" id="${controlsId}"></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="live-game-leave">Leave game</button>
      </div>
    </div>`;
  document.body.appendChild(box);
  box.querySelector('#live-game-leave').addEventListener('click', leaveLiveGame);
}

// ═══════════════════════════════════════════════════════════
// Chat management — contact info, mute, favourite, labels, close/clear/
// delete chat, block, mark-all-read, bulk-select (chats & messages)
// ═══════════════════════════════════════════════════════════

/** Refreshes the per-chat menu's dynamic labels (mute/favourite/block) to
 *  match the currently-open conversation — called right before the menu
 *  becomes visible, so it can't show a stale state. */
function updateChatMenuLabels() {
  const archBtn = $('chat-menu')?.querySelector('[data-action="archive"] span');
  if (archBtn) archBtn.textContent = state.conversations.get(state.activeId)?.archived ? 'Unarchive chat' : 'Archive chat';
  const lockBtn = $('chat-menu')?.querySelector('[data-action="lock-chat"] span');
  const lockConvo = state.conversations.get(state.activeId);
  if (lockBtn) {
    lockBtn.textContent = lockConvo?.kind === 'direct' && state.me?.privateLock ? 'Private chats PIN (on)'
      : lockConvo?.locked ? 'Remove chat lock' : 'Lock chat';
  }
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;
  const muteLabel = $('chat-menu-mute-label');
  if (muteLabel) muteLabel.textContent = convo.muted ? 'Unmute notifications' : 'Mute notifications';
  const favLabel = $('chat-menu-favorite-label');
  if (favLabel) favLabel.textContent = convo.favorite ? 'Remove from favourites' : 'Add to favourites';
  const blockLabel = $('chat-menu-block-label');
  const blockBtn = $('chat-menu')?.querySelector('[data-action="block"]');
  if (blockLabel && convo.kind === 'direct') {
    const blocked = state.blockedIds.has(convo.peer.id);
    blockLabel.textContent = blocked ? `Unblock ${convo.peer.displayName}` : `Block ${convo.peer.displayName}`;
    if (blockBtn) blockBtn.classList.toggle('hidden', false);
  } else if (blockBtn) {
    blockBtn.classList.toggle('hidden', true); // groups can't be blocked
  }
}

function closeActiveChat() {
  state.activeId = null;
  $('app-screen').classList.remove('viewing-chat');
  $('chat-pane').classList.add('hidden');
  $('no-chat').classList.remove('hidden');
  renderChatList();
}

async function clearActiveChat() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;
  if (!confirm('Clear all messages in this chat? This only clears your own view — nothing changes for the other side.')) return;

  try {
    await api(`/api/conversations/${convo.id}/clear`, { method: 'POST' });
    state.messages.set(convo.id, []);
    convo.lastMessage = null;
    renderMessages();
    renderChatList();
    toast('Chat cleared.');
  } catch (err) {
    toast(err.message, true);
  }
}

async function deleteActiveChat() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;
  const name = convo.kind === 'group' ? convo.title : convo.peer?.displayName;
  if (!confirm(`Delete your chat with ${name}? It'll disappear from your list until they message you again.`)) return;

  try {
    await api(`/api/conversations/${convo.id}`, { method: 'DELETE' });
    state.conversations.delete(convo.id);
    state.messages.delete(convo.id);
    state.keys.delete(convo.id);
    closeActiveChat();
    toast('Chat deleted.');
  } catch (err) {
    toast(err.message, true);
  }
}

async function toggleMute() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;
  const next = !convo.muted;
  convo.muted = next; // optimistic
  try {
    await api(`/api/conversations/${convo.id}/mute`, { method: 'PATCH', body: JSON.stringify({ muted: next }) });
    toast(next ? 'Notifications muted for this chat.' : 'Notifications unmuted.');
  } catch (err) {
    convo.muted = !next;
    toast(err.message, true);
  }
}

async function toggleBlockActiveChatPeer() {
  const convo = state.conversations.get(state.activeId);
  if (!convo || convo.kind !== 'direct') return;
  const peer = convo.peer;
  const currentlyBlocked = state.blockedIds.has(peer.id);

  const confirmMsg = currentlyBlocked
    ? `Unblock ${peer.displayName}?`
    : `Block ${peer.displayName}? They won't be able to message or call you, and you won't be able to message or call them.`;
  if (!confirm(confirmMsg)) return;

  try {
    if (currentlyBlocked) {
      await api(`/api/users/${peer.id}/block`, { method: 'DELETE' });
      state.blockedIds.delete(peer.id);
      toast(`${peer.displayName} unblocked.`);
    } else {
      await api(`/api/users/${peer.id}/block`, { method: 'POST' });
      state.blockedIds.add(peer.id);
      toast(`${peer.displayName} blocked.`);
    }
    updateRequestBar(convo);
  } catch (err) {
    toast(err.message, true);
  }
}

async function openBlockedUsersPanel() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Blocked contacts</h3>
      <div class="reminder-list" id="blocked-list" style="margin-top:0; padding-top:0; border-top:none;"></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="blocked-close">Close</button>
      </div>
    </div>`;
  document.body.appendChild(box);
  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#blocked-close').addEventListener('click', close);

  async function load() {
    const list = box.querySelector('#blocked-list');
    list.innerHTML = '<div class="empty-hint">Loading…</div>';
    try {
      const { users } = await api('/api/users/me/blocked');
      if (users.length === 0) {
        list.innerHTML = '<div class="empty-hint">Nobody blocked.</div>';
        return;
      }
      list.innerHTML = users.map((u) => `
        <div class="reminder-item">
          <div class="avatar sm" style="background:${escapeAttr(u.avatarColor)}">${avatarInner(u)}</div>
          <div class="reminder-item-body">
            <div class="reminder-item-content">${escapeHtml(u.displayName)}</div>
            <div class="reminder-item-when">@${escapeHtml(u.username)}</div>
          </div>
          <button type="button" class="btn-secondary" data-unblock="${escapeAttr(u.id)}">Unblock</button>
        </div>`).join('');
      list.querySelectorAll('[data-unblock]').forEach((btn) => {
        btn.addEventListener('click', async () => {
          btn.disabled = true;
          try {
            await api(`/api/users/${btn.dataset.unblock}/block`, { method: 'DELETE' });
            state.blockedIds.delete(btn.dataset.unblock);
            const activeConvo = state.conversations.get(state.activeId);
            if (activeConvo) updateRequestBar(activeConvo);
            load();
          } catch (err) {
            btn.disabled = false;
            toast(err.message, true);
          }
        });
      });
    } catch (err) {
      list.innerHTML = `<div class="empty-hint">${escapeHtml(err.message)}</div>`;
    }
  }

  load();
}

/** Contact info — the direct-chat equivalent of group info (openGroupInfo),
 *  which already exists; this fills the gap for 1:1 chats. */
function openContactInfo() {
  const convo = state.conversations.get(state.activeId);
  if (!convo || convo.kind !== 'direct') return;
  const peer = convo.peer;

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  const row = (icon, label, cls = '') =>
    `<button type="button" class="contact-info-row ${cls}" data-act="${label}">
       <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${icon}</svg>
       <span></span>
     </button>`;

  box.innerHTML = `
    <div class="modal-card contact-info-card">
      <div class="contact-info-hero">
        <div class="avatar" style="width:96px;height:96px;font-size:34px;background:${escapeAttr(peer.avatarColor)}">${avatarInner(peer)}</div>
        <div class="contact-info-name">${escapeHtml(peer.displayName)}</div>
        <div class="contact-info-handle">@${escapeHtml(peer.username)}</div>
      </div>

      <div class="contact-info-block">
        <div class="contact-info-label">About</div>
        <div class="contact-info-about">${escapeHtml(peer.about || 'Available')}</div>
      </div>
      <div id="contact-business"></div>

      <div class="contact-info-list">
        ${row('<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>', 'fav')}
        ${row('<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>', 'mute')}
        ${row('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>', 'search')}
        ${row('<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>', 'ringtone')}
        ${row('<path d="M3 6h18"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/>', 'clear', 'danger')}
        ${row('<circle cx="12" cy="12" r="10"/><line x1="4.9" y1="4.9" x2="19.1" y2="19.1"/>', 'block', 'danger')}
      </div>

      <div class="modal-actions">
        <button type="button" class="btn-primary" id="contact-info-close" style="width:auto;margin-top:0;padding:10px 22px;">Done</button>
      </div>
    </div>`;
  document.body.appendChild(box);
  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#contact-info-close').addEventListener('click', close);
  F.businessBlockFor(peer.id).then((html) => {
    const slot = box.querySelector('#contact-business');
    if (slot) slot.outerHTML = html || '';
  });

  const label = (act, text) => {
    const el = box.querySelector(`[data-act="${act}"] span`);
    if (el) el.textContent = text;
  };
  const refresh = () => {
    label('fav', convo.favorite ? 'Remove from favourites' : 'Add to favourites');
    label('mute', convo.muted ? 'Unmute notifications' : 'Mute notifications');
    label('search', 'Search in chat');
    label('ringtone', `Ringtone: ${F.RINGTONES[F.ringtoneFor(peer.id)].name}${F.ringtoneOverride(peer.id) ? '' : ' (default)'}`);
    label('clear', 'Clear chat');
    label('block', state.blockedIds.has(peer.id) ? `Unblock ${peer.displayName}` : `Block ${peer.displayName}`);
  };
  refresh();

  box.querySelectorAll('.contact-info-row').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const act = btn.dataset.act;
      if (act === 'fav') { await toggleFavorite(convo.id); refresh(); }
      else if (act === 'mute') { await toggleMute(); refresh(); }
      else if (act === 'search') { close(); openChatSearch(); }
      else if (act === 'ringtone') { close(); F.openRingtonePicker(peer.id, peer.displayName); }
      else if (act === 'clear') { close(); clearActiveChat(); }
      else if (act === 'block') { await toggleBlockActiveChatPeer(); refresh(); }
    });
  });
}

// ── Storage & data (on-device cache — see localstore.js) ────

async function openStoragePanel() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Storage &amp; data</h3>
      <p class="appearance-note" style="margin:-4px 0 16px">
        Messages and media you've opened are kept on this device, so chats load
        instantly and work offline. The server keeps only the encrypted copy.
      </p>
      <div class="storage-stat"><span>On this device</span><b id="storage-used">…</b></div>
      <div class="storage-stat"><span>Cached messages</span><b id="storage-msgs">…</b></div>
      <div class="modal-actions" style="justify-content:space-between">
        <button type="button" class="btn-danger" id="storage-clear">Clear downloaded data</button>
        <button type="button" class="btn-primary" id="storage-close" style="width:auto;margin-top:0;padding:10px 22px">Done</button>
      </div>
    </div>`;
  document.body.appendChild(box);
  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#storage-close').addEventListener('click', close);

  const fill = async () => {
    const [usage, counts] = await Promise.all([localStore.usage(), localStore.counts()]);
    box.querySelector('#storage-used').textContent =
      usage?.usage != null ? formatBytes(usage.usage) : 'n/a';
    box.querySelector('#storage-msgs').textContent = String(counts.messages ?? 0);
  };
  fill();

  box.querySelector('#storage-clear').addEventListener('click', async () => {
    if (!confirm('Clear all downloaded messages and media from this device? They stay on the server and re-download as you open chats.')) return;
    const btn = box.querySelector('#storage-clear');
    btn.disabled = true;
    await localStore.clear();
    inlineMediaUrls.clear();
    toast('On-device data cleared.');
    fill();
    btn.disabled = false;
  });
}

// ── Mark all as read ─────────────────────────────────────────

function markAllRead() {
  let n = 0;
  for (const convo of state.conversations.values()) {
    if (convo.unread > 0) {
      sendSocket({ type: 'read', conversationId: convo.id });
      convo.unread = 0;
      n++;
    }
  }
  renderChatList();
  toast(n ? 'All chats marked as read.' : 'Nothing to mark as read.');
}

// ── Select chats (bulk mode in the sidebar) ──────────────────

function enterChatSelectMode() {
  state.chatSelectMode = true;
  state.selectedChatIds.clear();
  $('search-wrap')?.classList.add('hidden');
  $('chat-select-bar').classList.remove('hidden');
  updateChatSelectBar();
  renderChatList();
}

function exitChatSelectMode() {
  state.chatSelectMode = false;
  state.selectedChatIds.clear();
  $('search-wrap')?.classList.remove('hidden');
  $('chat-select-bar').classList.add('hidden');
  renderChatList();
}

function updateChatSelectBar() {
  $('chat-select-count').textContent = `${state.selectedChatIds.size} selected`;
}

$('chat-select-cancel').addEventListener('click', exitChatSelectMode);

$('chat-select-read').addEventListener('click', () => {
  for (const id of state.selectedChatIds) {
    const convo = state.conversations.get(id);
    if (convo?.unread > 0) {
      sendSocket({ type: 'read', conversationId: id });
      convo.unread = 0;
    }
  }
  toast('Marked as read.');
  exitChatSelectMode();
});

$('chat-select-delete').addEventListener('click', async () => {
  const ids = [...state.selectedChatIds];
  if (ids.length === 0) return;
  if (!confirm(`Delete ${ids.length} chat${ids.length === 1 ? '' : 's'}? Each disappears from your list until they message you again.`)) return;

  await Promise.all(ids.map(async (id) => {
    try {
      await api(`/api/conversations/${id}`, { method: 'DELETE' });
      state.conversations.delete(id);
      state.messages.delete(id);
      state.keys.delete(id);
      if (state.activeId === id) closeActiveChat();
    } catch (err) {
      toast(err.message, true);
    }
  }));
  exitChatSelectMode();
});

function toggleChatSelected(id) {
  if (state.selectedChatIds.has(id)) state.selectedChatIds.delete(id);
  else state.selectedChatIds.add(id);
  updateChatSelectBar();
  renderChatList();
}

// ── Select messages (bulk mode inside a chat) ────────────────

function enterMessageSelectMode() {
  if (!state.activeId) return;
  state.msgSelectMode = true;
  state.selectedMessageIds.clear();
  $('composer-normal').classList.add('hidden');
  $('reply-bar').classList.add('hidden');
  $('edit-bar').classList.add('hidden');
  $('msg-select-bar').classList.remove('hidden');
  updateMsgSelectBar();
  renderMessages();
}

function exitMessageSelectMode() {
  state.msgSelectMode = false;
  state.selectedMessageIds.clear();
  $('msg-select-bar').classList.add('hidden');
  $('composer-normal').classList.remove('hidden');
  renderMessages();
}

function updateMsgSelectBar() {
  $('msg-select-count').textContent = `${state.selectedMessageIds.size} selected`;
}

$('msg-select-cancel').addEventListener('click', exitMessageSelectMode);

$('msg-select-star').addEventListener('click', async () => {
  const ids = [...state.selectedMessageIds];
  await Promise.all(ids.map((id) => toggleStarMessage(id).catch(() => {})));
  exitMessageSelectMode();
});

$('msg-select-delete').addEventListener('click', async () => {
  const ids = [...state.selectedMessageIds];
  if (ids.length === 0) return;
  const list = state.messages.get(state.activeId) || [];
  const ownIds = ids.filter((id) => list.find((m) => m.id === id)?.senderId === state.me.id);
  if (ownIds.length === 0) {
    toast('You can only delete your own messages.', true);
    return;
  }
  if (!confirm(`Delete ${ownIds.length} message${ownIds.length === 1 ? '' : 's'}?`)) return;
  for (const id of ownIds) {
    sendSocket({ type: 'delete-message', conversationId: state.activeId, messageId: id });
  }
  exitMessageSelectMode();
});

function toggleMessageSelected(id) {
  if (state.selectedMessageIds.has(id)) state.selectedMessageIds.delete(id);
  else state.selectedMessageIds.add(id);
  updateMsgSelectBar();
  renderMessages();
}

// ── Custom labels/lists ───────────────────────────────────────

function openAddToListPanel() {
  const convo = state.conversations.get(state.activeId);
  if (!convo) return;

  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card">
      <h3>Add to list</h3>
      <div class="picker-list" id="label-picker-list"></div>
      <div class="field">
        <label>New list</label>
        <input type="text" id="new-label-name" placeholder="e.g. Work, Family…" maxlength="40">
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" id="label-panel-close">Close</button>
        <button type="button" class="btn-primary" id="new-label-create" style="width:auto;margin-top:0;padding:10px 20px;">Create</button>
      </div>
    </div>`;
  document.body.appendChild(box);
  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#label-panel-close').addEventListener('click', close);

  function renderLabelList() {
    const listEl = box.querySelector('#label-picker-list');
    if (state.labels.length === 0) {
      listEl.innerHTML = '<div class="empty-hint">No lists yet — create one below.</div>';
      return;
    }
    listEl.innerHTML = state.labels.map((l) => `
      <label class="picker-row">
        <input type="checkbox" data-label="${escapeAttr(l.id)}" ${l.conversationIds.includes(convo.id) ? 'checked' : ''}>
        <span class="name"><span class="chat-label-chip" style="background:${escapeAttr(l.color)}">${escapeHtml(l.name)}</span></span>
      </label>`).join('');
    listEl.querySelectorAll('input[type="checkbox"]').forEach((cb) => {
      cb.addEventListener('change', async () => {
        try {
          const { applied } = await api(`/api/labels/${cb.dataset.label}/toggle`, {
            method: 'POST', body: JSON.stringify({ conversationId: convo.id }),
          });
          const label = state.labels.find((l) => l.id === cb.dataset.label);
          if (label) {
            if (applied && !label.conversationIds.includes(convo.id)) label.conversationIds.push(convo.id);
            else if (!applied) label.conversationIds = label.conversationIds.filter((id) => id !== convo.id);
          }
          renderChatFilterTabs();
          renderChatList();
        } catch (err) {
          cb.checked = !cb.checked;
          toast(err.message, true);
        }
      });
    });
  }
  renderLabelList();

  box.querySelector('#new-label-create').addEventListener('click', async () => {
    const name = box.querySelector('#new-label-name').value.trim();
    if (!name) { toast('Give this list a name.', true); return; }
    try {
      const { label } = await api('/api/labels', { method: 'POST', body: JSON.stringify({ name }) });
      state.labels.push(label);
      box.querySelector('#new-label-name').value = '';
      renderLabelList();
      renderChatFilterTabs();
    } catch (err) {
      toast(err.message, true);
    }
  });
}

// ── Voice commands ("Hey ARM") ───────────────────────────────
// A wake-word assistant, same idea as "Hey Siri" / "OK Google": once
// turned on, the browser's SpeechRecognition (same Web Speech API the
// live voice-recording transcription already uses — see speechToTextSupported()
// above) listens continuously. Whatever comes after the phrase "hey arm"
// is parsed as a command and acted on immediately, using the exact same
// functions the UI buttons call (startCall, sendMessage, openConversation)
// so a voice command behaves identically to clicking through by hand.
//
// This is plain pattern-matching, not a language model — "call X" / "say
// Y to X" / "message X Y" / "open X" cover the requested cases without
// needing a network round-trip or an API key. Chrome's SpeechRecognition
// itself does send audio to Google's servers to do the actual transcribing
// (same as it always has for the recording feature) — this doesn't change
// that, it just decides what to do with the resulting text, entirely
// on-device.

// "Arm" is a short, low-information syllable — real-world speech
// recognition regularly mishears it as a filler word instead ("hey umm",
// "hey am", "hey I'm", "hey on"), which is exactly the kind of thing that
// makes a wake phrase silently never fire with a strict exact-string match.
// Matching any of these after "hey" is deliberately loose: a rare false
// trigger just shows the "go ahead…" badge and times out on its own if
// nothing sensible follows, which is a much cheaper mistake than the
// command never firing at all.
//
// Speech engines also often drop "arm" altogether and hand back just "he"
// or "hey" before the command ("he say hello to manju"), so a hey-like word
// directly followed by a command verb counts as the wake phrase too.
const VOICE_HEY = '(?:hey|hay|hei|he|hi|hii|ok|okay|a)';
const VOICE_ARM = "(?:arm|arms|aarm|harm|ram|alarm|army|am|aam|aum|umm?|uhm|ahm|erm|i'?m|on|ah|art|arn|alm|ma'?am)";
const VOICE_VERBS = '(?:call|video|say|send|tell|message|msg|open|start|make|please|text)';
const VOICE_WAKE_REGEX = new RegExp(
  `\\b(?:${VOICE_HEY}\\s+${VOICE_ARM}|harm|hey\\s*arm|(?:hey|hay|hei|he|hi|hii)(?=\\s+${VOICE_VERBS}\\b))\\b`);
const VOICE_COMMANDS_PREF_KEY = 'vesper-voice-commands-enabled';
// 'off' = turned off by hand. Anything else (including never set) = on.
const voiceCommandsWanted = () => localStorage.getItem(VOICE_COMMANDS_PREF_KEY) !== 'off';
// Indian English hears Indian names and accents far better than the
// browser's default US English; other English locales keep their own.
const VOICE_LANG = /^en-(IN|GB|AU|CA|NZ|IE|ZA|SG)$/i.test(navigator.language) ? navigator.language : 'en-IN';

/** Returns the index right after a recognized wake phrase, or -1. */
function findWakePhraseEnd(transcript) {
  const m = transcript.match(VOICE_WAKE_REGEX);
  return m ? m.index + m[0].length : -1;
}

function toggleVoiceCommands() {
  if (state.voiceCommands.active) stopVoiceCommandListener();
  else startVoiceCommandListener();
}

function startVoiceCommandListener({ quiet = false } = {}) {
  if (!speechToTextSupported()) {
    if (!quiet) toast('Voice commands need a browser with speech recognition (Chrome or Edge).', true);
    updateVoiceCommandsMenuLabel();
    return;
  }
  if (state.voiceCommands.active) return;
  state.voiceCommands.active = true;
  state.voiceCommands.quiet = quiet;   // started automatically: no error toast if the mic is blocked
  localStorage.setItem(VOICE_COMMANDS_PREF_KEY, 'on');
  updateVoiceCommandsMenuLabel();
  showVoiceCommandIdle();
  if (!quiet) toast('Voice commands on — say "Hey ARM, call Manju".');
  armVoiceRecognizer();
}

function stopVoiceCommandListener({ remember = true } = {}) {
  state.voiceCommands.active = false;
  if (remember) localStorage.setItem(VOICE_COMMANDS_PREF_KEY, 'off');
  updateVoiceCommandsMenuLabel();
  state.voiceCommands.recognizer?.stop();
  state.voiceCommands.recognizer = null;
  hideVoiceCommandBadge();
}

function updateVoiceCommandsMenuLabel() {
  const label = $('voice-commands-label');
  if (label) {
    label.textContent = state.voiceCommands.active
      ? 'Turn off voice commands ("Hey ARM")'
      : 'Turn on voice commands ("Hey ARM")';
  }
}

/** Loosens exact-string wake-phrase matching just enough to survive the
 *  transcription noise real speech recognition produces — stray commas
 *  ("hey, arm"), doubled spaces, that kind of thing — without trying to
 *  guess at genuine mishearings like "hey arnold". */
function normalizeForWakeMatch(s) {
  return s.toLowerCase().replace(/[.,!?]/g, '').replace(/\s+/g, ' ').trim();
}

/** (Re)starts a fresh recognition session — called on first enable and
 *  again every time one session ends, either from a command firing (so the
 *  next "hey arm" isn't drowned out by an ever-growing transcript) or from
 *  the engine's own silence timeout. */
function armVoiceRecognizer() {
  if (!state.voiceCommands.active) return;

  const rec = new SpeechRecognitionCtor();
  rec.lang = VOICE_LANG;
  rec.continuous = true;
  rec.interimResults = true;
  rec.maxAlternatives = 5;   // the engine's runner-up guesses often contain the wake phrase
  state.voiceCommands.recognizer = rec;

  let silenceTimer = null;
  let pending = '';   // the command heard so far, waiting for the speaker to pause

  // Runs the waiting command exactly once — from the pause timer, or from
  // onend if the browser closes the session first (Edge/Chrome often do,
  // right after the final words; dropping it there is what lost commands).
  const fire = () => {
    clearTimeout(silenceTimer);
    const command = pending;
    pending = '';
    if (command) executeVoiceCommand(command);
  };

  rec.onresult = (e) => {
    // Build the transcript from each phrase's best guess, but for the latest
    // phrase also try every alternative: whichever one contains the wake
    // phrase wins, so a near-miss on "hey arm" in guess #1 doesn't lose it.
    let before = '';
    for (let i = 0; i < e.results.length - 1; i++) before += e.results[i][0].transcript + ' ';
    const last = e.results[e.results.length - 1];
    const options = [...Array(last.length).keys()].map((k) => normalizeForWakeMatch(before + last[k].transcript));
    const transcript = options.find((t) => findWakePhraseEnd(t) !== -1) || options[0];

    const wakeEnd = findWakePhraseEnd(transcript);
    // Not for us — ordinary talk near the mic. Stay quiet (but keep any
    // command already heard; the engine sometimes rewrites its guess).
    if (wakeEnd === -1) return;

    const command = cleanVoiceCommand(transcript.slice(wakeEnd));
    pending = command;
    showVoiceCommandBadge(command ? `"${command}"` : 'Listening — go ahead…');

    // A command is "done" once speech pauses for a bit, or straight away
    // once the engine marks the phrase final.
    clearTimeout(silenceTimer);
    silenceTimer = setTimeout(() => {
      fire();
      rec.stop(); // -> onend below re-arms with a clean transcript buffer
    }, last.isFinal ? 700 : 1800);
  };

  rec.onerror = (e) => {
    // 'no-speech' fires constantly during ordinary silence — not an error
    // worth surfacing, onend below just re-arms. The other two mean voice
    // commands flat-out CAN'T work right now, so say so instead of leaving
    // the badge stuck on "listening" forever with no explanation.
    if (e.error === 'no-speech') return;
    if (e.error === 'not-allowed' || e.error === 'service-not-allowed') {
      if (!state.voiceCommands.quiet) {
        toast('Voice commands need microphone access — allow the mic for this site, then turn them on from ⋮.', true);
      }
      stopVoiceCommandListener({ remember: false });
    } else if (e.error === 'network') {
      showVoiceCommandBadge('no connection — retrying…');
    }
  };
  rec.onend = () => {
    if (state.voiceCommands.active) fire();
    else pending = '';
    if (state.voiceCommands.active) {
      showVoiceCommandIdle();
      armVoiceRecognizer();
    }
  };

  try { rec.start(); } catch { /* already starting — ignore */ }
}

function showVoiceCommandBadge(text) {
  let badge = $('voice-command-badge');
  if (!badge) {
    badge = document.createElement('div');
    badge.id = 'voice-command-badge';
    badge.className = 'voice-command-badge';
    document.body.appendChild(badge);
  }
  badge.classList.remove('idle');
  badge.textContent = `🎙️ ${text}`;
}

/** While just waiting for "Hey ARM": a small mic dot, not a banner. */
function showVoiceCommandIdle() {
  showVoiceCommandBadge('');
  const badge = $('voice-command-badge');
  badge.classList.add('idle');
  badge.textContent = '🎙️';
  badge.title = 'Voice commands are on — say "Hey ARM". Turn off from ⋮.';
}

/** Drops leading filler a speech engine adds between the wake phrase and
 *  the command ("hey arm, can you please call manju"). */
function cleanVoiceCommand(text) {
  return text.trim()
    .replace(/^(?:arm|um+|uh|so|and|ok|okay)\s+/i, '')
    .replace(/^(?:can you|could you|will you|would you|please|kindly)\s+/i, '')
    .replace(/^please\s+/i, '')
    .trim();
}

/** Edit distance, for names the engine spells a little differently. */
function editDistance(a, b) {
  const row = [...Array(b.length + 1).keys()];
  for (let i = 1; i <= a.length; i++) {
    let prev = row[0];
    row[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = row[j];
      row[j] = Math.min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1));
      prev = tmp;
    }
  }
  return row[b.length];
}

function hideVoiceCommandBadge() {
  $('voice-command-badge')?.remove();
}

/** Finds the best-matching direct-chat contact for a spoken name — exact
 *  match first, then "starts with", then "contains anywhere", since a
 *  transcribed name is rarely spelled/cased exactly like the display name. */
function findContactByName(name) {
  const target = name.toLowerCase().trim().replace(/[.,!?]+$/, '').replace(/^(?:to|with)\s+/, '');
  if (!target) return null;
  const directChats = [...state.conversations.values()].filter((c) => c.kind === 'direct' && c.peer);
  const names = (c) => [c.peer.displayName, c.peer.username].filter(Boolean).map((n) => n.toLowerCase());
  const exact = directChats.find((c) => names(c).includes(target))
    || directChats.find((c) => names(c).some((n) => n.startsWith(target) || n.split(/\s+/)[0] === target))
    || directChats.find((c) => names(c).some((n) => n.includes(target)));
  if (exact) return exact;
  // Close enough: "manjoo" → Manju, "abhi" → Abi. Compare by sound (see
  // soundKey) against the full and first name, allowing about one wrong
  // letter in three.
  const spoken = soundKey(target);
  let best = null;
  let bestScore = Infinity;
  for (const c of directChats) {
    for (const n of names(c).flatMap((n) => [n, n.split(/\s+/)[0]])) {
      const key = soundKey(n);
      const d = editDistance(spoken, key);
      if (d <= Math.max(1, Math.round(key.length / 3)) && d < bestScore) { best = c; bestScore = d; }
    }
  }
  return best;
}

/** A rough "sounds like" spelling, so the way a speech engine writes an
 *  Indian name ("manjoo", "preeti", "abhi") lines up with how it's saved
 *  ("Manju", "Priti", "Abi"). */
function soundKey(name) {
  return name.toLowerCase()
    .replace(/[^a-z]/g, '')
    .replace(/oo|ou/g, 'u').replace(/ee|ea|ie/g, 'i').replace(/aa/g, 'a')
    .replace(/(?<=[kgcjtdpb])h/g, '').replace(/ph/g, 'f').replace(/w/g, 'v').replace(/z/g, 's')
    .replace(/(.)\1+/g, '$1');
}

async function executeVoiceCommand(command) {
  const text = command.trim().replace(/[.,!?]+$/, '');

  let m = text.match(/^(?:please\s+)?(?:make a |start a )?(video\s*)?call(?:\s+to)?\s+(.+)$/i);
  if (m) return voiceCallContact(m[2], m[1] ? 'video' : 'audio');

  m = text.match(/^(?:please\s+)?say\s+(.+?)\s+to\s+(.+)$/i);
  if (m) return voiceSendMessage(m[2], m[1]);

  m = text.match(/^(?:please\s+)?send\s+(.+?)\s+to\s+(.+)$/i);
  if (m) return voiceSendMessage(m[2], m[1]);

  m = text.match(/^(?:please\s+)?(?:tell|message)\s+(.+?)\s+(?:that\s+|to\s+say\s+)?(.+)$/i);
  if (m) return voiceSendMessage(m[1], m[2]);

  m = text.match(/^(?:please\s+)?open(?:\s+(?:the\s+)?chat)?(?:\s+with)?\s+(.+)$/i);
  if (m) return voiceOpenChat(m[1]);

  toast(`Heard "${command}" — didn't recognize that as a command.`, true);
}

async function voiceCallContact(name, callType) {
  const convo = findContactByName(name);
  if (!convo) { toast(`Couldn't find a contact named "${name.trim()}".`, true); return; }
  await openConversation(convo.id);
  toast(`${callType === 'video' ? 'Video calling' : 'Calling'} ${convo.peer.displayName}…`);
  startCall(callType);
}

async function voiceSendMessage(name, text) {
  const convo = findContactByName(name);
  if (!convo) { toast(`Couldn't find a contact named "${name.trim()}".`, true); return; }
  await openConversation(convo.id);
  input.value = text.trim();
  await sendMessage();
  toast(`Sent to ${convo.peer.displayName}: "${text.trim()}"`);
}

async function voiceOpenChat(name) {
  const convo = findContactByName(name);
  if (!convo) { toast(`Couldn't find a contact named "${name.trim()}".`, true); return; }
  await openConversation(convo.id);
  toast(`Opened chat with ${convo.peer.displayName}.`);
}

// ── App lock (PIN / pattern / biometric) ────────────────────
// A local privacy screen, not real security: the gate is pure client-side
// JS, and the encrypted-session key it would need to bypass already lives
// in this same browser's IndexedDB regardless (see crypto.js's
// saveSessionKey) — anyone with real access to the device and dev tools
// can already get past this. What it actually protects against is the
// ordinary case of someone picking up an unlocked device and seeing your
// chats at a glance — the same threat model WhatsApp's own app lock
// targets, whichever of the three methods below is used.
//
// PIN and pattern both just hash a secret (typed digits, or a dot
// sequence like "0-4-8-7-6") and compare against a stored hash — same
// check, different input widget. Biometric instead registers a WebAuthn
// *platform* authenticator (Windows Hello / Touch ID / Android biometrics)
// and asks for it again to unlock; there's no server relying-party half to
// this because there's nothing server-side to authenticate against — a
// successful navigator.credentials.get() already means the OS itself
// verified the fingerprint/face on this device, which is all this screen
// needs to know.

async function sha256Hex(text) {
  const bytes = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function getAppLockMethod() {
  return localStorage.getItem('vesper-applock-method'); // 'pin' | 'pattern' | 'biometric' | null
}

async function saveAppLockSecret(method, secret) {
  localStorage.setItem('vesper-applock-method', method);
  localStorage.setItem('vesper-applock-hash', await sha256Hex(secret));
}

function clearAppLock() {
  localStorage.removeItem('vesper-applock-method');
  localStorage.removeItem('vesper-applock-hash');
  localStorage.removeItem('vesper-applock-credential-id');
}

async function biometricAvailable() {
  return !!(window.PublicKeyCredential
    && await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().catch(() => false));
}

async function registerBiometricAppLock() {
  const cred = await navigator.credentials.create({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rp: { name: 'Veyon Chat' },
      user: {
        id: crypto.getRandomValues(new Uint8Array(16)),
        name: state.me?.username || 'veyon-user',
        displayName: state.me?.displayName || 'Veyon user',
      },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
      authenticatorSelection: { authenticatorAttachment: 'platform', userVerification: 'required' },
      timeout: 60_000,
    },
  });
  localStorage.setItem('vesper-applock-method', 'biometric');
  localStorage.setItem('vesper-applock-credential-id', bufToB64(cred.rawId));
}

async function verifyBiometricAppLock() {
  const credentialId = localStorage.getItem('vesper-applock-credential-id');
  if (!credentialId) throw new Error('Not set up');
  await navigator.credentials.get({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      allowCredentials: [{ id: b64ToBuf(credentialId), type: 'public-key' }],
      userVerification: 'required',
      timeout: 60_000,
    },
  });
  // navigator.credentials.get() only resolves after the OS itself confirms
  // the fingerprint/face matched — if it didn't, this throws instead.
}

/**
 * A 3×3 dot grid you drag across to draw a pattern — lines are redrawn on
 * an SVG overlay as you go. `onSequence` fires once per completed drag with
 * the array of dot indices (0–8) in the order they were connected; the
 * caller decides what counts as a long-enough / matching pattern.
 */
function createPatternGrid(onSequence) {
  const wrap = document.createElement('div');
  wrap.className = 'pattern-grid';
  wrap.innerHTML = Array.from({ length: 9 }, (_, i) => `<div class="pattern-dot" data-idx="${i}"></div>`).join('')
    + '<svg class="pattern-lines"></svg>';

  let sequence = [];
  let dragging = false;

  function dotCenter(idx) {
    const dotRect = wrap.querySelector(`.pattern-dot[data-idx="${idx}"]`).getBoundingClientRect();
    const wrapRect = wrap.getBoundingClientRect();
    return { x: dotRect.left + dotRect.width / 2 - wrapRect.left, y: dotRect.top + dotRect.height / 2 - wrapRect.top };
  }

  function redraw() {
    wrap.querySelectorAll('.pattern-dot').forEach((d) => d.classList.toggle('on', sequence.includes(Number(d.dataset.idx))));
    wrap.querySelector('.pattern-lines').innerHTML = sequence.slice(1).map((idx, i) => {
      const a = dotCenter(sequence[i]), b = dotCenter(idx);
      return `<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}"/>`;
    }).join('');
  }

  function dotAt(x, y) {
    const el = document.elementFromPoint(x, y)?.closest('.pattern-dot');
    return el ? Number(el.dataset.idx) : null;
  }

  function onDown(e) {
    dragging = true;
    sequence = [];
    const idx = dotAt(e.clientX, e.clientY);
    if (idx !== null) sequence.push(idx);
    redraw();
  }
  function onMove(e) {
    if (!dragging) return;
    const idx = dotAt(e.clientX, e.clientY);
    if (idx !== null && !sequence.includes(idx)) { sequence.push(idx); redraw(); }
  }
  function onUp() {
    if (!dragging) return;
    dragging = false;
    const finished = sequence;
    sequence = [];
    redraw();
    onSequence(finished);
  }

  wrap.addEventListener('pointerdown', onDown);
  window.addEventListener('pointermove', onMove);
  window.addEventListener('pointerup', onUp);
  return wrap;
}

// Holds the boot-time gate's resolve() while a lock screen is showing, so
// the static #applock-reset button (wired once, below) can unblock it —
// there's exactly one gate per page load, so one module-level slot is fine.
let appLockGateResolve = null;

/** Gates the ENTIRE app behind PIN/pattern/biometric if one is set —
 *  called once at boot, before tryResume(). Resolves immediately if no
 *  lock method is configured at all. */
function gateAppLock() {
  return new Promise((resolve) => {
    const method = getAppLockMethod();
    if (!method) return resolve();

    appLockGateResolve = resolve;
    $('applock-screen').classList.remove('hidden');
    renderAppLockUnlockUI(method, () => {
      $('applock-screen').classList.add('hidden');
      appLockGateResolve = null;
      resolve();
    });
  });
}

function renderAppLockUnlockUI(method, unlocked) {
  const body = $('applock-body');
  const errorEl = $('applock-error');
  const subEl = $('applock-sub');
  errorEl.classList.add('hidden');
  body.innerHTML = '';

  if (method === 'pin') {
    subEl.textContent = 'Enter your PIN to continue.';
    body.innerHTML = `
      <input type="password" id="applock-input" inputmode="numeric" autocomplete="off"
             maxlength="12" placeholder="PIN" class="applock-input" aria-label="PIN">
      <button type="button" class="btn-primary" id="applock-submit">Unlock</button>`;
    const input = body.querySelector('#applock-input');
    input.focus();
    async function tryUnlock() {
      const hash = await sha256Hex(input.value);
      if (hash === localStorage.getItem('vesper-applock-hash')) { unlocked(); return; }
      errorEl.textContent = 'Wrong PIN.';
      errorEl.classList.remove('hidden');
      input.value = '';
      input.focus();
    }
    body.querySelector('#applock-submit').addEventListener('click', tryUnlock);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') tryUnlock(); });
  } else if (method === 'pattern') {
    subEl.textContent = 'Draw your pattern to continue.';
    const grid = createPatternGrid(async (seq) => {
      if (seq.length === 0) return;
      const hash = await sha256Hex(seq.join('-'));
      if (hash === localStorage.getItem('vesper-applock-hash')) { unlocked(); return; }
      errorEl.textContent = 'Wrong pattern.';
      errorEl.classList.remove('hidden');
    });
    body.appendChild(grid);
  } else if (method === 'biometric') {
    subEl.textContent = 'Use your fingerprint or face to continue.';
    body.innerHTML = `
      <button type="button" class="applock-biometric-btn" id="applock-bio-unlock">
        ${iconFingerprint()}
        Unlock
      </button>`;
    async function tryBiometric() {
      try {
        await verifyBiometricAppLock();
        unlocked();
      } catch {
        errorEl.textContent = 'Biometric check failed or was cancelled.';
        errorEl.classList.remove('hidden');
      }
    }
    body.querySelector('#applock-bio-unlock').addEventListener('click', tryBiometric);
    tryBiometric(); // prompt immediately — most OS biometric gates don't wait for a click first
  }
}

function iconFingerprint() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round">
            <path d="M12 2a5 5 0 0 0-5 5v3a5 5 0 0 0 10 0V7a5 5 0 0 0-5-5z"/>
            <path d="M8 11v1a4 4 0 0 0 8 0v-1"/><path d="M12 17v5"/></svg>`;
}

// The reset link lives in static HTML (always present once #applock-screen
// exists), wired once here rather than per-gate — see appLockGateResolve.
$('applock-reset').addEventListener('click', () => {
  if (!appLockGateResolve) return;
  if (!confirm("Reset app lock? This removes the PIN/pattern/biometric requirement on this device. It doesn't affect your messages — those were never protected by this screen in the first place, only your device's own storage was.")) return;
  clearAppLock();
  $('applock-screen').classList.add('hidden');
  const resolve = appLockGateResolve;
  appLockGateResolve = null;
  resolve();
});

async function openAppLockSettings() {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  const method = getAppLockMethod();
  const canUseBiometric = await biometricAvailable();

  const methodLabel = { pin: 'A PIN', pattern: 'A pattern', biometric: 'Biometric unlock' };
  box.innerHTML = `
    <div class="modal-card">
      <h3>App lock</h3>
      ${method ? `
        <p class="auth-sub" style="margin-bottom:18px;">${methodLabel[method]} is set on this device.</p>
        <div class="modal-actions">
          <button type="button" class="btn-secondary" id="applock-close">Close</button>
          <button type="button" class="btn-primary" id="applock-remove" style="width:auto;margin-top:0;padding:10px 20px;background:var(--danger)">Turn off</button>
        </div>
      ` : `
        <div class="applock-method-tabs" id="applock-method-tabs">
          <button type="button" class="chat-filter-tab active" data-method="pin">PIN</button>
          <button type="button" class="chat-filter-tab" data-method="pattern">Pattern</button>
          ${canUseBiometric ? '<button type="button" class="chat-filter-tab" data-method="biometric">Biometric</button>' : ''}
        </div>
        <div id="applock-setup-body"></div>
        <div class="auth-error hidden" id="applock-set-error"></div>
        <div class="modal-actions">
          <button type="button" class="btn-secondary" id="applock-close">Close</button>
        </div>
      `}
    </div>`;
  document.body.appendChild(box);
  const close = () => box.remove();
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  box.querySelector('#applock-close').addEventListener('click', close);

  box.querySelector('#applock-remove')?.addEventListener('click', () => {
    clearAppLock();
    toast('App lock turned off.');
    close();
  });

  if (method) return; // nothing further to wire — already set, just showing the "turn off" state

  const setupBody = box.querySelector('#applock-setup-body');
  const errEl = box.querySelector('#applock-set-error');
  const showErr = (msg) => { errEl.textContent = msg; errEl.classList.remove('hidden'); };

  function showSetupFor(m) {
    errEl.classList.add('hidden');
    if (m === 'pin') {
      setupBody.innerHTML = `
        <div class="field"><label>New PIN</label><input type="password" id="applock-new-pin" inputmode="numeric" maxlength="12" placeholder="4+ digits"></div>
        <div class="field"><label>Confirm PIN</label><input type="password" id="applock-confirm-pin" inputmode="numeric" maxlength="12" placeholder="Repeat it"></div>
        <button type="button" class="btn-primary" id="applock-save">Set PIN</button>`;
      setupBody.querySelector('#applock-save').addEventListener('click', async () => {
        const pin = setupBody.querySelector('#applock-new-pin').value;
        const confirmPin = setupBody.querySelector('#applock-confirm-pin').value;
        if (pin.length < 4) return showErr('PIN must be at least 4 digits.');
        if (pin !== confirmPin) return showErr("PINs don't match.");
        await saveAppLockSecret('pin', pin);
        toast('App lock enabled.');
        close();
      });
    } else if (m === 'pattern') {
      setupBody.innerHTML = '<div class="pattern-hint">Draw a pattern connecting at least 4 dots.</div>';
      let firstSeq = null;
      const grid = createPatternGrid(async (seq) => {
        if (seq.length < 4) { showErr('Connect at least 4 dots.'); return; }
        if (!firstSeq) {
          firstSeq = seq;
          setupBody.querySelector('.pattern-hint').textContent = 'Draw it again to confirm.';
          return;
        }
        if (seq.join(',') !== firstSeq.join(',')) {
          showErr("Patterns didn't match — try again.");
          firstSeq = null;
          setupBody.querySelector('.pattern-hint').textContent = 'Draw a pattern connecting at least 4 dots.';
          return;
        }
        await saveAppLockSecret('pattern', seq.join('-'));
        toast('App lock enabled.');
        close();
      });
      setupBody.appendChild(grid);
    } else if (m === 'biometric') {
      setupBody.innerHTML = `<button type="button" class="applock-biometric-btn" id="applock-bio-setup">${iconFingerprint()}Set up with fingerprint / face</button>`;
      setupBody.querySelector('#applock-bio-setup').addEventListener('click', async () => {
        try {
          await registerBiometricAppLock();
          toast('App lock enabled.');
          close();
        } catch (err) {
          showErr('Could not set up biometric unlock: ' + err.message);
        }
      });
    }
  }

  box.querySelector('#applock-method-tabs').querySelectorAll('.chat-filter-tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      box.querySelectorAll('#applock-method-tabs .chat-filter-tab').forEach((t) => t.classList.remove('active'));
      tab.classList.add('active');
      showSetupFor(tab.dataset.method);
    });
  });
  showSetupFor('pin');
}

// ── Search in chat ──────────────────────────────────────────
// Searches whatever's already loaded/decrypted immediately, then — since
// only the most recent 50 messages are loaded by default — pages backward
// through this conversation's history (decrypting as it goes) up to a
// bounded depth so search actually covers more than just what's on screen,
// without needing full infinite-scroll pagination built out first.

const SEARCH_HISTORY_BATCH_CAP = 10; // 10 * 50 = up to 500 messages back

let searchState = { results: [], index: -1, extending: false };

function drawSearchFilters() {
  const row = $('chat-search-filters');
  row.innerHTML = F.searchFiltersHtml(state.conversations.get(state.activeId));
  row.classList.remove('hidden');
  row.querySelectorAll('.search-chip').forEach((b) => b.addEventListener('click', () => {
    F.searchFilter.kind = b.dataset.kind;
    drawSearchFilters();
    runSearch($('chat-search-input').value);
  }));
  row.querySelector('#search-from')?.addEventListener('change', (e) => {
    F.searchFilter.from = e.target.value;
    runSearch($('chat-search-input').value);
  });
  row.querySelector('#search-date')?.addEventListener('change', (e) => jumpToDate(e.target.value));
}

/** Jumps to the first message on or after a date, loading older history as needed. */
async function jumpToDate(value) {
  if (!value) return;
  const target = new Date(`${value}T00:00:00`);
  const conversationId = state.activeId;
  for (let i = 0; i < 20; i++) {
    const list = state.messages.get(conversationId) || [];
    if (list.length && new Date(list[0].createdAt) <= target) break;
    if (!(await loadOlderMessages(conversationId))) break;
  }
  const hit = (state.messages.get(conversationId) || []).find((m) => new Date(m.createdAt) >= target);
  if (hit) jumpToMessage(hit.id);
  else toast('No messages from that day on.', true);
}

function closeChatSearch() {
  $('chat-pane')?.classList.remove('search-open');
  $('chat-search-filters')?.classList.add('hidden');
  $('chat-search-bar').classList.add('hidden');
  $('chat-search-input').value = '';
  $('chat-search-count').textContent = '';
  searchState = { results: [], index: -1, extending: false };
}

function openChatSearch() {
  if (!state.activeId) return;
  $('chat-search-bar').classList.remove('hidden');
  F.searchFilter.kind = 'all';
  F.searchFilter.from = '';
  drawSearchFilters();
  $('chat-pane').classList.add('search-open');   // messages move down, clear of the bars
  const input = $('chat-search-input');
  input.value = '';
  input.focus();
  extendSearchHistory(state.activeId); // kick off in the background, don't block typing
}

$('chat-search-close').addEventListener('click', closeChatSearch);

async function extendSearchHistory(conversationId) {
  if (searchState.extending) return;
  searchState.extending = true;
  try {
    const convo = state.conversations.get(conversationId);
    if (!convo) return;
    const key = await keyFor(convo);

    for (let batch = 0; batch < SEARCH_HISTORY_BATCH_CAP; batch++) {
      const list = state.messages.get(conversationId) || [];
      const oldest = list[0];
      if (!oldest) break;

      const { messages } = await api(
        `/api/conversations/${conversationId}/messages?before=${encodeURIComponent(oldest.createdAt)}`
      );
      if (messages.length === 0) break; // reached the start of the conversation

      for (const m of messages) {
        if (!state.plaintext.has(m.id)) {
          try { state.plaintext.set(m.id, await decryptBody(key, m)); } catch { state.plaintext.set(m.id, null); }
        }
      }
      state.messages.set(conversationId, [...messages, ...(state.messages.get(conversationId) || [])]);

      if (conversationId === state.activeId) runSearch($('chat-search-input').value);
      if (messages.length < 50) break; // short page — that was the last one
    }
  } catch {
    // History extension is a best-effort background enhancement — a failed
    // page just means search stays scoped to whatever's already loaded.
  } finally {
    searchState.extending = false;
  }
}

/** Loads one older page of a chat's history in front of what's loaded.
 *  Returns how many messages came back (0 = start of the chat reached). */
async function loadOlderMessages(conversationId) {
  const convo = state.conversations.get(conversationId);
  const list = state.messages.get(conversationId) || [];
  const oldest = list.find((m) => !m.pending);
  if (!convo || !oldest) return 0;
  const { messages } = await api(
    `/api/conversations/${conversationId}/messages?before=${encodeURIComponent(oldest.createdAt)}`
  );
  if (!messages.length) return 0;
  const key = await keyFor(convo);
  for (const m of messages) {
    if (!state.plaintext.has(m.id)) {
      try { state.plaintext.set(m.id, await decryptBody(key, m)); } catch { state.plaintext.set(m.id, null); }
    }
  }
  await decryptReactionsFor(key, messages);
  const known = new Set((state.messages.get(conversationId) || []).map((m) => m.id));
  state.messages.set(conversationId, [...messages.filter((m) => !known.has(m.id)), ...(state.messages.get(conversationId) || [])]);
  if (conversationId === state.activeId) renderMessages();
  return messages.length;
}

function runSearch(term) {
  const q = term.trim().toLowerCase();
  const filtered = F.searchFilter.kind !== 'all' || F.searchFilter.from;
  if (!q && !filtered) {
    searchState.results = [];
    searchState.index = -1;
    $('chat-search-count').textContent = '';
    return;
  }

  const list = state.messages.get(state.activeId) || [];
  searchState.results = list
    .filter((m) => {
      const plain = state.plaintext.get(m.id);
      if (!F.passesSearchFilter(m, plain)) return false;
      if (!q) return true;
      const text = typeof plain === 'string' ? F.textOf(plain) : (plain?.name || '');
      return text.toLowerCase().includes(q);
    })
    .map((m) => m.id);

  searchState.index = searchState.results.length ? searchState.results.length - 1 : -1;
  updateSearchCount();
  if (searchState.index >= 0) jumpToMessage(searchState.results[searchState.index]);
}

function updateSearchCount() {
  $('chat-search-count').textContent = searchState.results.length
    ? `${searchState.index + 1} / ${searchState.results.length}`
    : ($('chat-search-input').value.trim() ? 'No results' : '');
}

function stepSearch(dir) {
  if (!searchState.results.length) return;
  searchState.index = (searchState.index + dir + searchState.results.length) % searchState.results.length;
  updateSearchCount();
  jumpToMessage(searchState.results[searchState.index]);
}

let chatSearchTimer;
$('chat-search-input').addEventListener('input', (e) => {
  clearTimeout(chatSearchTimer);
  const value = e.target.value;
  chatSearchTimer = setTimeout(() => runSearch(value), 200);
});
$('chat-search-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); stepSearch(e.shiftKey ? -1 : 1); }
  else if (e.key === 'Escape') closeChatSearch();
});
$('chat-search-prev').addEventListener('click', () => stepSearch(-1));
$('chat-search-next').addEventListener('click', () => stepSearch(1));

function notify(convo, message) {
  const plain = state.plaintext.get(message.id);
  let body;
  switch (message.kind) {
    case 'file':     body = 'Sent an attachment'; break;
    case 'voice':    body = 'Sent a voice message'; break;
    case 'location': body = 'Shared a location'; break;
    case 'contact':  body = 'Shared a contact'; break;
    default:         body = typeof plain === 'string' ? F.textOf(plain) : 'New message';
  }

  if (!('Notification' in window) || Notification.permission !== 'granted') return;
  // Locked chats never show who or what in a notification.
  const title = convo.locked ? 'Veyon Chat' : convo.kind === 'group' ? convo.title : convo.peer.displayName;
  new Notification(title, { body: convo.locked ? 'New message' : body.slice(0, 120) });
}

if ('Notification' in window && Notification.permission === 'default') {
  // Ask only after a real interaction — browsers reject an immediate prompt.
  document.addEventListener('click', function ask() {
    Notification.requestPermission();
    document.removeEventListener('click', ask);
  }, { once: true });
}

function showLightbox(url) {
  const box = document.createElement('div');
  box.className = 'lightbox';
  box.innerHTML = `<img src="${escapeAttr(url)}" alt="">`;
  box.addEventListener('click', () => {
    box.remove();
    URL.revokeObjectURL(url);
  });
  document.body.appendChild(box);
}

let toastTimer;
function toast(message, isError = false) {
  const el = $('toast');
  el.textContent = message;
  el.className = 'toast show' + (isError ? ' error' : '');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.className = 'toast'; }, 3800);
}

// ═══════════════════════════════════════════════════════════
// Formatting helpers
// ═══════════════════════════════════════════════════════════

function initials(name) {
  return (name || '?')
    .trim().split(/\s+/).slice(0, 2)
    .map((w) => w[0]).join('').toUpperCase();
}

/**
 * The inner content of an avatar div: a real photo if the entity has one,
 * colored initials otherwise. `entity` needs `.displayName` and, for the
 * photo branch, `.photoUrl` — every user/peer/member/poster object returned
 * by the server carries both. `dot`, if true, appends the online-presence
 * dot span some avatar sites also need.
 */
function avatarInner(entity, { dot = false, online = false } = {}) {
  const dotHtml = dot ? `<span class="dot ${online ? 'online' : ''}"></span>` : '';
  return entity?.photoUrl
    ? `<img src="${escapeAttr(apiUrl(entity.photoUrl))}" alt="">${dotHtml}`
    : `${escapeHtml(initials(entity?.displayName))}${dotHtml}`;
}

/** Same as avatarInner(), but for the handful of sites that build an avatar
 *  by querying an existing DOM element rather than a template string. */
function setAvatar(el, entity, opts) {
  if (!el) return;
  el.style.background = entity?.avatarColor || '#6C5CE7';
  el.innerHTML = avatarInner(entity, opts);
}

function shortTime(iso) {
  return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function dayKey(iso) {
  return new Date(iso).toDateString();
}

function dayLabel(iso) {
  const d = new Date(iso);
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);

  if (d.toDateString() === today.toDateString()) return 'Today';
  if (d.toDateString() === yesterday.toDateString()) return 'Yesterday';

  return d.toLocaleDateString([], {
    weekday: 'short', day: 'numeric', month: 'short',
    year: d.getFullYear() === today.getFullYear() ? undefined : 'numeric',
  });
}

function relativeTime(iso) {
  const seconds = Math.floor((Date.now() - new Date(iso)) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h ago`;
  return dayLabel(iso).toLowerCase() + ' at ' + shortTime(iso);
}

function formatDuration(seconds) {
  if (!isFinite(seconds) || seconds < 0) return '0:00';
  const s = Math.floor(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function formatBytes(n) {
  if (!n) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function escapeAttr(s) {
  return escapeHtml(s);
}

/** Turns bare URLs into links. Runs AFTER escapeHtml, so the input is already safe. */
function linkify(escaped) {
  return escaped.replace(
    /(https?:\/\/[^\s<]+)/g,
    '<a href="$1" target="_blank" rel="noopener noreferrer" style="color:inherit">$1</a>'
  );
}

// ═══════════════════════════════════════════════════════════

// Registered unconditionally (not gated behind the Reminders panel like
// ensurePushSubscription's registration) — an active service worker
// controlling the page is one of the criteria browsers check before
// offering "Install app" at all, so this needs to happen on every load.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(() => {});
}

// ═══════════════════════════════════════════════════════════
// Self-update — new versions of the site apply on their own
// ═══════════════════════════════════════════════════════════
// The frontend server publishes /version.json, a fingerprint of the site's
// files. When it changes, this page reloads itself at a moment it won't be
// noticed: the tab is in the background, or nobody's touched it for two
// minutes — never mid-call, mid-game, or with a half-typed message. The
// login survives the reload (see tryResume), so updating is invisible.

const UPDATE_CHECK_MS = 60_000;
const UPDATE_IDLE_MS = 2 * 60_000;
let loadedSiteVersion = null;
let siteUpdatePending = false;
let lastUserActivity = Date.now();

for (const evt of ['pointerdown', 'keydown', 'touchstart', 'wheel']) {
  addEventListener(evt, () => { lastUserActivity = Date.now(); }, { passive: true, capture: true });
}

async function fetchSiteVersion() {
  try {
    const res = await fetch('/version.json', { cache: 'no-store' });
    if (!res.ok) return null;
    return (await res.json()).version || null;
  } catch { return null; } // offline — try again later
}

function busyForUpdate() {
  const composer = $('composer-input');
  return Boolean(
    state.call || state.groupCall || state.liveGame || state.editingId ||
    (composer && composer.value.trim()) ||
    document.querySelector('.modal-backdrop')
  );
}

function applySiteUpdateIfQuiet() {
  if (!siteUpdatePending || busyForUpdate()) return;
  if (document.hidden || Date.now() - lastUserActivity > UPDATE_IDLE_MS) location.reload();
}

async function checkSiteVersion() {
  const v = await fetchSiteVersion();
  if (!v) return;
  if (!loadedSiteVersion) { loadedSiteVersion = v; return; }
  if (v !== loadedSiteVersion) siteUpdatePending = true;
  applySiteUpdateIfQuiet();
}

checkSiteVersion();
setInterval(checkSiteVersion, UPDATE_CHECK_MS);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) applySiteUpdateIfQuiet();
  else checkSiteVersion();
});

// Escape closes the top-most dialog — every dialog already closes when its
// backdrop is clicked, so this simply does that for the last one opened.
// The live-game window is skipped: leaving a game should be deliberate.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || e.defaultPrevented) return;
  const dialogs = [...document.querySelectorAll('.modal-backdrop')].filter((d) => d.id !== 'live-game-modal');
  const top = dialogs[dialogs.length - 1];
  if (top) top.dispatchEvent(new MouseEvent('click', { bubbles: true }));
});

// The feature modules (js/features/) get exactly what they use, nothing more.
F.bindFeatures({
  state, $, api, apiUrl, toast, escapeHtml, escapeAttr, avatarInner, linkify, shortTime,
  keyFor, decryptBody, encryptText, decryptFileBytes, sendSocket, canSendTo,
  renderMessages, renderChatList, refreshComposerSuggestions, pushMessage, previewFor, senderInfo,
  sendJsonMessage, sendMediaFile, jumpToMessage, loadOlderMessages, directContacts,
  openLinkedDevicesPanel, openLiveGameModal, sendGameSignal, signOut,
  openAddMember, startChatWith, openConversation, createGroup, loadConversations,
  iconPlay, iconPause, closeActiveChat,
  startCall, startOrJoinGroupCall, renderGroupCallTiles,
});

// An invite link opened in a tab where the app is already running only
// changes the #hash — no reload — so watch for it.
window.addEventListener('hashchange', () => { if (state.me) F.checkInviteHash(); });

$('calls-btn').addEventListener('click', () => F.openCallsPanel());

// "Forgot password?" — finishes by signing in with the new password.
$('forgot-password').addEventListener('click', () => F.openForgotPassword((username, password) => {
  setAuthMode('login');
  $('f-username').value = username;
  $('f-password').value = password;
  $('auth-form').requestSubmit();
}));

// Sign-up form: mobile number + Gmail + emailed code.
$('field-contact').innerHTML = F.birthFieldHtml() + F.contactFieldsHtml();
const readSignupContact = F.wireContactFields($('field-contact'), '/api/auth/otp', showAuthError);

setAuthMode('login');
gateAppLock().then(tryResume);
