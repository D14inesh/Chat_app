// Voice player with speed + mini-player, edit history, chat lock,
// stickers from your photos, and search filters.

import { app, icon, openModal, whenText } from './core.js';
import { decryptText } from '../crypto.js';
import { setPrivateLock } from './privacy.js';

// ── Voice messages: one player for the whole app ─────────────
// Keeps playing while you scroll or switch chats; a mini-player bar shows
// what's playing with speed and stop. Speed is remembered.

const SPEEDS = [1, 1.5, 2];
let speed = (() => { try { return Number(localStorage.getItem('veyon.voiceSpeed')) || 1; } catch { return 1; } })();
let current = null; // {msgId, audio, title, conversationId, url}

const fmt = (s) => {
  if (!Number.isFinite(s)) return '0:00';
  const m = Math.floor(s / 60);
  return `${m}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
};

export const voiceSpeedLabel = () => `${speed}×`;

function bubbleFor(msgId) {
  return document.querySelector(`.voice-player[data-msg="${CSS.escape(msgId)}"]`);
}

function paint() {
  document.querySelectorAll('.voice-player').forEach((el) => {
    const playing = current && el.dataset.msg === current.msgId && !current.audio.paused;
    const btn = el.querySelector('.voice-play-btn');
    if (btn) btn.innerHTML = playing ? app.iconPause() : app.iconPlay();
    el.classList.toggle('is-playing', !!(current && el.dataset.msg === current.msgId));
    const sp = el.querySelector('.voice-speed-btn');
    if (sp) sp.textContent = voiceSpeedLabel();
    if (current && el.dataset.msg === current.msgId) {
      const a = current.audio;
      const t = el.querySelector('.voice-time');
      if (t && Number.isFinite(a.duration)) t.textContent = fmt(Math.max(0, a.duration - a.currentTime));
      el.style.setProperty('--voice-progress', a.duration ? `${(a.currentTime / a.duration) * 100}%` : '0%');
    } else {
      el.style.removeProperty('--voice-progress');
    }
  });
  drawMiniPlayer();
}

function drawMiniPlayer() {
  let bar = document.getElementById('voice-mini');
  if (!current) { bar?.remove(); return; }
  if (!bar) {
    bar = document.createElement('div');
    bar.id = 'voice-mini';
    bar.className = 'voice-mini';
    bar.innerHTML = `
      <button type="button" class="icon-btn vm-play" aria-label="Play or pause"></button>
      <div class="vm-main">
        <div class="vm-title"></div>
        <div class="vm-track"><i></i></div>
      </div>
      <span class="vm-time"></span>
      <button type="button" class="vm-speed" aria-label="Playback speed"></button>
      <button type="button" class="icon-btn vm-close" aria-label="Stop">${icon('close')}</button>`;
    document.body.appendChild(bar);
    bar.querySelector('.vm-play').addEventListener('click', () => (current.audio.paused ? current.audio.play() : current.audio.pause()));
    bar.querySelector('.vm-speed').addEventListener('click', cycleSpeed);
    bar.querySelector('.vm-close').addEventListener('click', stopVoice);
    bar.querySelector('.vm-main').addEventListener('click', () => {
      if (current.conversationId !== app.state.activeId) app.openConversation(current.conversationId);
      setTimeout(() => app.jumpToMessage(current.msgId), 300);
    });
    bar.querySelector('.vm-track').addEventListener('click', (e) => {
      e.stopPropagation();
      const r = e.currentTarget.getBoundingClientRect();
      const a = current.audio;
      if (a.duration) a.currentTime = ((e.clientX - r.left) / r.width) * a.duration;
    });
  }
  const a = current.audio;
  bar.querySelector('.vm-play').innerHTML = a.paused ? app.iconPlay() : app.iconPause();
  bar.querySelector('.vm-title').textContent = current.title;
  bar.querySelector('.vm-track i').style.width = a.duration ? `${(a.currentTime / a.duration) * 100}%` : '0%';
  bar.querySelector('.vm-time').textContent = `${fmt(a.currentTime)} / ${fmt(a.duration)}`;
  bar.querySelector('.vm-speed').textContent = voiceSpeedLabel();
}

export function cycleSpeed() {
  speed = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.length] || 1;
  try { localStorage.setItem('veyon.voiceSpeed', String(speed)); } catch { /* ignore */ }
  if (current) current.audio.playbackRate = speed;
  paint();
}

export function stopVoice() {
  if (!current) return;
  current.audio.pause();
  current = null;
  paint();
}

/** Play/pause a voice message. `getUrl()` decrypts it (first time only). */
export async function toggleVoice({ msgId, title, conversationId, getUrl }) {
  if (current?.msgId === msgId) {
    if (current.audio.paused) current.audio.play(); else current.audio.pause();
    return;
  }
  stopVoice();
  const url = await getUrl();
  const audio = new Audio(url);
  audio.playbackRate = speed;
  current = { msgId, audio, title, conversationId };
  ['play', 'pause', 'timeupdate', 'loadedmetadata'].forEach((ev) => audio.addEventListener(ev, paint));
  audio.addEventListener('ratechange', () => { if (audio.playbackRate !== speed) audio.playbackRate = speed; });
  audio.addEventListener('ended', () => {
    // Plays the next voice message in the chat, like WhatsApp.
    const list = app.state.messages.get(conversationId) || [];
    const i = list.findIndex((m) => m.id === msgId);
    const next = list.slice(i + 1).find((m) => m.kind === 'voice' && !m.deleted);
    current = null;
    paint();
    if (next && conversationId === app.state.activeId) bubbleFor(next.id)?.querySelector('.voice-play-btn')?.click();
  });
  await audio.play();
}

/** After a re-render: put the playing state back on the new bubbles. */
export const repaintVoice = paint;

// ── Edit history ─────────────────────────────────────────────

export async function openEditHistory(msgId) {
  const convo = app.state.conversations.get(app.state.activeId);
  let versions;
  try {
    ({ versions } = await app.api(`/api/messages/${msgId}/edits`));
  } catch (err) { app.toast(err.message, true); return; }
  const key = await app.keyFor(convo);
  const texts = await Promise.all(versions.map((v) => decryptText(key, v.ciphertext, v.iv).catch(() => null)));
  const items = versions.map((v, i) => ({ ...v, text: texts[i] })).reverse();
  const { box, close } = openModal(`
    <h3>${icon('edit', 'class="modal-title-icon"')} Edit history</h3>
    <div class="edit-history">
      ${items.map((v, i) => `
        <div class="edit-version ${v.current ? 'current' : ''}">
          <div class="edit-version-head">
            <span>${v.current ? 'Now' : i === items.length - 1 ? 'Original' : 'Edited'}</span>
            <span class="edit-version-when">${whenText(v.at)}</span>
          </div>
          <div class="edit-version-text">${v.text == null ? '<i>Couldn’t decrypt</i>' : app.linkify(app.escapeHtml(v.text))}</div>
        </div>`).join('')}
    </div>
    <div class="modal-actions"><button type="button" class="btn-primary" data-close>Done</button></div>`, { cardClass: 'feature-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
}

// ── Chat lock ────────────────────────────────────────────────
// Locked chats hide behind a "Locked chats" row; one PIN (per account,
// checked by the server) opens them for 5 minutes or until the tab hides.

let hasPin = null;
let unlockedUntil = 0;
const UNLOCK_MS = 5 * 60 * 1000;

export const lockedOpen = () => Date.now() < unlockedUntil;
document.addEventListener('visibilitychange', () => {
  if (document.hidden && unlockedUntil) { unlockedUntil = 0; setTimeout(() => app.renderChatList(), 0); }
});

async function loadPinState() {
  if (hasPin === null) {
    try { hasPin = (await app.api('/api/chat-lock')).hasPin; } catch { hasPin = false; }
  }
  return hasPin;
}

function pinDialog({ title, sub, confirm = false, current = false }) {
  return new Promise((resolve) => {
    const { box, close } = openModal(`
      <div class="feature-hero">
        <div class="feature-hero-icon">${icon('lock')}</div>
        <h3>${title}</h3>
        <p>${sub}</p>
      </div>
      <div class="auth-error hidden" id="pin-err"></div>
      ${current ? '<div class="field"><label>Current PIN</label><input id="pin-cur" class="pin-input" type="password" inputmode="numeric" maxlength="8" autocomplete="off"></div>' : ''}
      <div class="field"><label>${confirm ? 'New PIN (4–8 digits)' : 'PIN'}</label><input id="pin-1" class="pin-input" type="password" inputmode="numeric" maxlength="8" autocomplete="off"></div>
      ${confirm ? '<div class="field"><label>Type it again</label><input id="pin-2" class="pin-input" type="password" inputmode="numeric" maxlength="8" autocomplete="off"></div>' : ''}
      <div class="modal-actions">
        <button type="button" class="btn-secondary" data-close>Cancel</button>
        <button type="button" class="btn-primary" id="pin-ok">${confirm ? 'Save PIN' : 'Unlock'}</button>
      </div>`, { cardClass: 'feature-card pin-card', onClose: () => resolve(null) });
    const err = box.querySelector('#pin-err');
    const fail = (m) => { err.textContent = m; err.classList.remove('hidden'); };
    box.querySelector('[data-close]').addEventListener('click', close);
    box.querySelectorAll('.pin-input').forEach((i) => i.addEventListener('input', () => { i.value = i.value.replace(/\D/g, ''); }));
    (box.querySelector('#pin-cur') || box.querySelector('#pin-1')).focus();
    const ok = async () => {
      const p1 = box.querySelector('#pin-1').value;
      if (confirm && p1 !== box.querySelector('#pin-2').value) return fail('The two PINs don’t match.');
      if (!/^\d{4,8}$/.test(p1)) return fail('The PIN must be 4–8 digits.');
      const result = { pin: p1, currentPin: box.querySelector('#pin-cur')?.value, fail };
      const done = await resolveCheck(result);
      if (done) { box.remove(); resolve(result); }
    };
    let resolveCheck = async () => true;
    box.setCheck = (fn) => { resolveCheck = fn; };
    box.querySelector('#pin-ok').addEventListener('click', ok);
    box.addEventListener('keydown', (e) => { if (e.key === 'Enter') ok(); });
    pinDialog.last = box;
  });
}

async function askPin(title = 'Locked chats', sub = 'Enter your chat lock PIN.') {
  const p = pinDialog({ title, sub });
  pinDialog.last.setCheck(async ({ pin, fail }) => {
    try {
      await app.api('/api/chat-lock/verify', { method: 'POST', body: JSON.stringify({ pin }) });
      return true;
    } catch (e) { fail(e.message); return false; }
  });
  return p;
}

async function setUpPin() {
  const p = pinDialog({ title: 'Set a chat lock PIN', sub: 'Locked chats stay hidden until this PIN is entered — on every device you use.', confirm: true });
  pinDialog.last.setCheck(async ({ pin, fail }) => {
    try {
      await app.api('/api/chat-lock/pin', { method: 'POST', body: JSON.stringify({ pin }) });
      hasPin = true;
      return true;
    } catch (e) { fail(e.message); return false; }
  });
  return p;
}

export async function unlockLockedChats() {
  if (!(await askPin())) return false;
  unlockedUntil = Date.now() + UNLOCK_MS;
  setTimeout(() => app.renderChatList(), UNLOCK_MS + 500);
  app.renderChatList();
  return true;
}

export function relockChats() {
  unlockedUntil = 0;
  const active = app.state.conversations.get(app.state.activeId);
  if (active?.locked) app.closeActiveChat();
  app.renderChatList();
}

/** Chat list: locked chats are left out unless unlocked. */
export function hideLocked(convos) {
  return lockedOpen() ? convos : convos.filter((c) => !c.locked);
}

/** The "Locked chats" row (or header, when open) above the chat list. */
export function lockedRowHtml() {
  const locked = [...app.state.conversations.values()].filter((c) => c.locked);
  if (!locked.length) return '';
  const unread = locked.reduce((n, c) => n + (c.unread || 0), 0);
  if (lockedOpen()) {
    return `<div class="locked-row open"><span class="locked-icon">${icon('lock')}</span>
      <span class="locked-title">Locked chats are showing</span>
      <button type="button" class="link-btn" id="relock-btn">Lock</button></div>`;
  }
  return `<button type="button" class="locked-row" id="locked-row">
    <span class="locked-icon">${icon('lock')}</span>
    <span class="locked-title">Locked chats</span>
    <span class="locked-sub">${locked.length}</span>
    ${unread ? `<span class="badge">${unread}</span>` : ''}</button>`;
}

export function wireLockedRow(listEl) {
  listEl.querySelector('#locked-row')?.addEventListener('click', unlockLockedChats);
  listEl.querySelector('#relock-btn')?.addEventListener('click', relockChats);
}

/** Opening a locked chat (from a notification, search…) needs the PIN. */
export async function canOpenChat(convo) {
  if (!convo?.locked || lockedOpen()) return true;
  return unlockLockedChats();
}

export async function toggleChatLock(convo) {
  if (!convo) return;
  // All 1-to-1 chats are already behind the PIN — manage that setting instead.
  if (convo.kind === 'direct' && app.state.me.privateLock) { openChatLockSettings(); return; }
  if (!convo.locked) {
    if (!(await loadPinState())) {
      if (!(await setUpPin())) return;
    }
    await app.api(`/api/conversations/${convo.id}/lock`, { method: 'PATCH', body: JSON.stringify({ locked: true }) });
    convo.locked = true;
    app.toast('Chat locked. Find it under “Locked chats” at the top of your chat list.');
    if (!lockedOpen()) app.closeActiveChat();
  } else {
    const p = pinDialog({ title: 'Remove from locked chats', sub: 'Enter your PIN to unlock this chat.' });
    pinDialog.last.setCheck(async ({ pin, fail }) => {
      try {
        await app.api(`/api/conversations/${convo.id}/lock`, { method: 'PATCH', body: JSON.stringify({ locked: false, pin }) });
        return true;
      } catch (e) { fail(e.message); return false; }
    });
    if (!(await p)) return;
    convo.locked = false;
    app.toast('Chat unlocked.');
  }
  app.renderChatList();
}

/** Security & logins: change PIN / turn chat lock off. */
export async function openChatLockSettings() {
  if (!(await loadPinState())) {
    if (!(await setUpPin())) return;
    app.toast('Chat lock PIN saved.');
  }
  const privateOn = !!app.state.me.privateLock;
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('lock')}</div>
      <h3>Chat lock</h3>
      <p>Locked chats hide behind “Locked chats” and your PIN, on every device. Lock one chat from its ⋮ menu — or all of your 1-to-1 chats at once:</p>
    </div>
    <label class="toggle-row">
      <span><span class="toggle-title">Private chats PIN</span>
      <span class="toggle-sub">Every 1-to-1 chat needs your PIN to open</span></span>
      <input type="checkbox" class="switch" id="cl-private" ${privateOn ? 'checked' : ''}>
    </label>
    <div class="modal-actions">
      <button type="button" class="btn-danger-soft" id="cl-off">Turn off</button>
      <button type="button" class="btn-secondary" id="cl-change">Change PIN</button>
      <button type="button" class="btn-primary" data-close>Done</button>
    </div>`, { cardClass: 'feature-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#cl-private').addEventListener('change', async (e) => {
    const on = e.target.checked;
    try {
      if (on) {
        await setPrivateLock(true);
        unlockedUntil = 0;
        app.closeActiveChat();
        app.toast('Your 1-to-1 chats are now behind your PIN.');
      } else {
        const p = pinDialog({ title: 'Turn off private chats PIN', sub: 'Enter your PIN.' });
        pinDialog.last.setCheck(async ({ pin, fail }) => {
          try { await setPrivateLock(false, pin); return true; } catch (err) { fail(err.message); return false; }
        });
        if (!(await p)) { e.target.checked = true; return; }
        app.toast('Private chats PIN is off.');
      }
    } catch (err) {
      e.target.checked = !on;
      app.toast(err.message, true);
    }
  });
  box.querySelector('#cl-change').addEventListener('click', async () => {
    close();
    const p = pinDialog({ title: 'Change PIN', sub: 'Enter your current PIN, then the new one.', confirm: true, current: true });
    pinDialog.last.setCheck(async ({ pin, currentPin, fail }) => {
      try {
        await app.api('/api/chat-lock/pin', { method: 'POST', body: JSON.stringify({ pin, currentPin }) });
        return true;
      } catch (e) { fail(e.message); return false; }
    });
    if (await p) app.toast('PIN changed.');
  });
  box.querySelector('#cl-off').addEventListener('click', async () => {
    close();
    const p = pinDialog({ title: 'Turn off chat lock', sub: 'Every locked chat goes back to your normal list.' });
    pinDialog.last.setCheck(async ({ pin, fail }) => {
      try {
        await app.api('/api/chat-lock/pin', { method: 'DELETE', body: JSON.stringify({ pin }) });
        return true;
      } catch (e) { fail(e.message); return false; }
    });
    if (!(await p)) return;
    hasPin = false;
    app.state.conversations.forEach((c) => { c.locked = false; });
    app.renderChatList();
    app.toast('Chat lock is off.');
  });
}

// ── Stickers from your photos ────────────────────────────────

const MY_STICKERS = 'veyon.myStickers';
const loadMine = () => { try { return JSON.parse(localStorage.getItem(MY_STICKERS) || '[]'); } catch { return []; } };
const saveMine = (list) => { try { localStorage.setItem(MY_STICKERS, JSON.stringify(list.slice(0, 40))); } catch { /* full */ } };

export function myStickersHtml() {
  const mine = loadMine();
  return `
    <div class="mp-section-title">My stickers</div>
    <div class="my-stickers">
      <button type="button" class="mp-make-sticker" title="Make a sticker from a photo">${icon('plus')}<span>Create</span></button>
      ${mine.map((s, i) => `<button type="button" class="mp-my-sticker" data-i="${i}"><img src="${s}" alt=""></button>`).join('')}
    </div>
    <div class="mp-section-title">Emoji stickers</div>`;
}

export function wireMyStickers(body, closePicker) {
  body.querySelector('.mp-make-sticker')?.addEventListener('click', () => { closePicker(); openStickerMaker(); });
  body.querySelectorAll('.mp-my-sticker').forEach((b) => {
    b.addEventListener('click', async () => {
      const data = loadMine()[Number(b.dataset.i)];
      if (!data) return;
      closePicker();
      const blob = await (await fetch(data)).blob();
      app.sendMediaFile(new File([blob], 'sticker.webp', { type: blob.type }), { sticker: true });
    });
    b.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      if (!confirm('Remove this sticker from My stickers?')) return;
      const list = loadMine();
      list.splice(Number(b.dataset.i), 1);
      saveMine(list);
      b.remove();
    });
  });
}

export function openStickerMaker() {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = 'image/*';
  input.onchange = () => { if (input.files[0]) editSticker(input.files[0]); };
  input.click();
}

function editSticker(file) {
  const img = new Image();
  img.onload = () => {
    const S = 512;
    const view = { x: 0, y: 0, zoom: 1, shape: 'rounded', text: '', textColor: '#ffffff', outline: true };
    const base = Math.max(S / img.width, S / img.height);
    const { box, close } = openModal(`
      <h3>${icon('sparkle', 'class="modal-title-icon"')} Make a sticker</h3>
      <div class="sticker-stage"><canvas id="st-canvas" width="${S}" height="${S}"></canvas></div>
      <div class="sticker-hint">Drag to move · use the slider to zoom</div>
      <div class="field"><label>Zoom</label><input type="range" id="st-zoom" min="1" max="3" step="0.01" value="1"></div>
      <div class="sticker-shapes" id="st-shapes">
        ${['square', 'rounded', 'circle'].map((s) => `<button type="button" data-shape="${s}" class="${s === view.shape ? 'active' : ''}"><span class="shape-${s}"></span>${s[0].toUpperCase() + s.slice(1)}</button>`).join('')}
      </div>
      <div class="field"><label>Caption (optional)</label>
        <div class="sticker-text-row"><input id="st-text" maxlength="24" placeholder="LOL!">
          <button type="button" class="st-color active" data-c="#ffffff" style="background:#fff"></button>
          <button type="button" class="st-color" data-c="#111111" style="background:#111"></button>
          <button type="button" class="st-color" data-c="#ffd43b" style="background:#ffd43b"></button>
        </div>
      </div>
      <label class="toggle-row"><span><span class="toggle-title">White outline</span><span class="toggle-sub">The classic sticker look</span></span>
        <input type="checkbox" class="switch" id="st-outline" checked></label>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" data-close>Cancel</button>
        <button type="button" class="btn-primary" id="st-send">${icon('send')} Send sticker</button>
      </div>`, { cardClass: 'feature-card sticker-card' });
    const canvas = box.querySelector('#st-canvas');
    const ctx = canvas.getContext('2d');

    const clip = (c, inset = 0) => {
      c.beginPath();
      const r = S / 2 - inset;
      if (view.shape === 'circle') c.arc(S / 2, S / 2, r, 0, Math.PI * 2);
      else if (view.shape === 'rounded') c.roundRect(inset, inset, S - inset * 2, S - inset * 2, 90 - inset);
      else c.rect(inset, inset, S - inset * 2, S - inset * 2);
    };
    const draw = () => {
      ctx.clearRect(0, 0, S, S);
      const pad = view.outline ? 14 : 0;
      if (view.outline) { ctx.save(); clip(ctx); ctx.fillStyle = '#fff'; ctx.fill(); ctx.restore(); }
      ctx.save();
      clip(ctx, pad);
      ctx.clip();
      const sc = base * view.zoom;
      const w = img.width * sc;
      const h = img.height * sc;
      ctx.drawImage(img, (S - w) / 2 + view.x, (S - h) / 2 + view.y, w, h);
      ctx.restore();
      if (view.text) {
        ctx.font = '900 64px Inter, system-ui, sans-serif';
        ctx.textAlign = 'center';
        ctx.lineJoin = 'round';
        ctx.lineWidth = 12;
        ctx.strokeStyle = view.textColor === '#111111' ? '#ffffff' : '#111111';
        ctx.strokeText(view.text, S / 2, S - 54);
        ctx.fillStyle = view.textColor;
        ctx.fillText(view.text, S / 2, S - 54);
      }
    };
    draw();

    let drag = null;
    canvas.addEventListener('pointerdown', (e) => { drag = { x: e.clientX, y: e.clientY, vx: view.x, vy: view.y }; canvas.setPointerCapture(e.pointerId); });
    canvas.addEventListener('pointermove', (e) => {
      if (!drag) return;
      const k = S / canvas.getBoundingClientRect().width;
      view.x = drag.vx + (e.clientX - drag.x) * k;
      view.y = drag.vy + (e.clientY - drag.y) * k;
      draw();
    });
    canvas.addEventListener('pointerup', () => { drag = null; });
    box.querySelector('#st-zoom').addEventListener('input', (e) => { view.zoom = Number(e.target.value); draw(); });
    box.querySelectorAll('#st-shapes button').forEach((b) => b.addEventListener('click', () => {
      view.shape = b.dataset.shape;
      box.querySelectorAll('#st-shapes button').forEach((x) => x.classList.toggle('active', x === b));
      draw();
    }));
    box.querySelector('#st-text').addEventListener('input', (e) => { view.text = e.target.value.toUpperCase(); draw(); });
    box.querySelectorAll('.st-color').forEach((b) => b.addEventListener('click', () => {
      view.textColor = b.dataset.c;
      box.querySelectorAll('.st-color').forEach((x) => x.classList.toggle('active', x === b));
      draw();
    }));
    box.querySelector('#st-outline').addEventListener('change', (e) => { view.outline = e.target.checked; draw(); });
    box.querySelector('[data-close]').addEventListener('click', close);
    box.querySelector('#st-send').addEventListener('click', () => {
      canvas.toBlob((blob) => {
        if (!blob) { app.toast('Couldn’t make the sticker.', true); return; }
        const reader = new FileReader();
        reader.onload = () => saveMine([reader.result, ...loadMine()]);
        reader.readAsDataURL(blob);
        app.sendMediaFile(new File([blob], 'sticker.webp', { type: blob.type || 'image/webp' }), { sticker: true });
        close();
      }, 'image/webp', 0.9);
    });
  };
  img.onerror = () => app.toast('That file isn’t a picture.', true);
  img.src = URL.createObjectURL(file);
}

// ── Search filters ───────────────────────────────────────────

export const searchFilter = { kind: 'all', from: '' };

const URL_RE = /https?:\/\/\S+/i;

/** Does message `m` (decrypted `plain`) pass the chosen filters? */
export function passesSearchFilter(m, plain) {
  if (searchFilter.from && m.senderId !== searchFilter.from) return false;
  if (m.deleted || plain == null) return false;
  const mime = typeof plain === 'object' ? plain.mime || '' : '';
  switch (searchFilter.kind) {
    case 'photos': return m.kind === 'file' && mime.startsWith('image/') && !plain.sticker && !plain.gif;
    case 'videos': return m.kind === 'file' && mime.startsWith('video/');
    case 'docs': return m.kind === 'file' && !mime.startsWith('image/') && !mime.startsWith('video/');
    case 'links': return typeof plain === 'string' && URL_RE.test(plain);
    case 'voice': return m.kind === 'voice';
    default: return true;
  }
}

export function searchFiltersHtml(convo) {
  const kinds = [['all', 'All'], ['photos', 'Photos'], ['videos', 'Videos'], ['links', 'Links'], ['docs', 'Docs'], ['voice', 'Voice']];
  const members = convo?.kind === 'group' ? (app.state.groupMembers.get(convo.id) || []) : [];
  return `
    ${kinds.map(([k, l]) => `<button type="button" class="search-chip ${searchFilter.kind === k ? 'active' : ''}" data-kind="${k}">${l}</button>`).join('')}
    ${members.length ? `<select class="search-from" id="search-from"><option value="">Anyone</option>
      ${members.map((m) => `<option value="${app.escapeAttr(m.id)}" ${searchFilter.from === m.id ? 'selected' : ''}>${app.escapeHtml(m.displayName)}</option>`).join('')}</select>` : ''}
    <label class="search-date" title="Jump to a date">${icon('clock')}<input type="date" id="search-date"></label>`;
}
