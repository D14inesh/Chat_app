// Calls: history with missed-call badge, ringtones (one per contact, made
// with the Web Audio API — no sound files), and screen sharing in group calls.

import { app, icon, openModal, whenText } from './core.js';

// ── Call history ─────────────────────────────────────────────

function durationText(s) {
  if (s == null) return '';
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m}:${String(s % 60).padStart(2, '0')}` : `${Math.floor(m / 60)} h ${m % 60} min`;
}

const ARROW_OUT = '<path d="M7 17 17 7"/><path d="M8 7h9v9"/>';
const ARROW_IN = '<path d="M17 7 7 17"/><path d="M16 17H7V8"/>';

export async function refreshMissedCalls() {
  try {
    const { missed } = await app.api('/api/calls/missed');
    const badge = app.$('calls-badge');
    if (badge) {
      badge.textContent = missed > 9 ? '9+' : String(missed);
      badge.classList.toggle('hidden', !missed);
    }
  } catch { /* offline */ }
}

export function onCallLog() { refreshMissedCalls(); }

export async function openCallsPanel() {
  const { box, close } = openModal(`
    <div class="calls-head">
      <h3>${icon('call')} Calls</h3>
      <button type="button" class="link-btn" id="calls-ringtone">${icon('bell')} Ringtone</button>
      <button type="button" class="link-btn" id="calls-clear">Clear</button>
    </div>
    <div class="calls-tabs">
      <button type="button" class="calls-tab active" data-f="all">All</button>
      <button type="button" class="calls-tab" data-f="missed">Missed</button>
    </div>
    <div class="calls-list" id="calls-list"><div class="ai-loading"><span></span><span></span><span></span> Loading…</div></div>
    <div class="modal-actions"><button type="button" class="btn-primary" data-close>Done</button></div>`, { cardClass: 'feature-card calls-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  const list = box.querySelector('#calls-list');
  let calls = [];
  let filter = 'all';

  const draw = () => {
    const shown = filter === 'missed' ? calls.filter((c) => c.status === 'missed' && c.direction === 'incoming') : calls;
    if (!shown.length) {
      list.innerHTML = `<div class="calls-empty">${icon('call')}<div>${filter === 'missed' ? 'No missed calls.' : 'No calls yet.'}</div>
        <small>Start a voice or video call from any chat.</small></div>`;
      return;
    }
    list.innerHTML = shown.map((c) => {
      const missed = c.status === 'missed' && c.direction === 'incoming';
      const what = c.isGroup ? 'Group call'
        : c.status === 'missed' ? (c.direction === 'incoming' ? 'Missed' : 'No answer')
        : c.status === 'declined' ? (c.direction === 'incoming' ? 'Declined' : 'Declined by them')
        : c.direction === 'incoming' ? 'Incoming' : 'Outgoing';
      const entity = c.isGroup ? { displayName: c.title } : c.peer;
      return `
        <div class="call-row ${missed ? 'missed' : ''}" data-id="${c.id}">
          <div class="avatar" style="background:${app.escapeAttr(c.avatarColor || '#6C5CE7')}">${app.avatarInner(entity)}</div>
          <div class="call-row-main">
            <div class="call-row-name">${app.escapeHtml(c.title || 'Unknown')}</div>
            <div class="call-row-sub">
              <svg class="call-arrow ${c.direction} ${c.status}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">${c.direction === 'outgoing' ? ARROW_OUT : ARROW_IN}</svg>
              ${what}${c.callType === 'video' ? ' · video' : ''} · ${whenText(c.startedAt)}${c.duration ? ` · ${durationText(c.duration)}` : ''}
            </div>
          </div>
          <button type="button" class="icon-btn call-again" data-type="audio" title="Voice call">${icon('call')}</button>
          <button type="button" class="icon-btn call-again" data-type="video" title="Video call">${icon('video')}</button>
        </div>`;
    }).join('');
    list.querySelectorAll('.call-row').forEach((row) => {
      const c = shown.find((x) => String(x.id) === row.dataset.id);
      row.querySelectorAll('.call-again').forEach((b) => b.addEventListener('click', async (e) => {
        e.stopPropagation();
        close();
        await app.openConversation(c.conversationId);
        if (c.isGroup) app.startOrJoinGroupCall(b.dataset.type);
        else app.startCall(b.dataset.type);
      }));
      row.addEventListener('click', () => { close(); app.openConversation(c.conversationId); });
    });
  };

  box.querySelectorAll('.calls-tab').forEach((t) => t.addEventListener('click', () => {
    filter = t.dataset.f;
    box.querySelectorAll('.calls-tab').forEach((x) => x.classList.toggle('active', x === t));
    draw();
  }));
  box.querySelector('#calls-ringtone').addEventListener('click', () => { close(); openRingtonePicker(); });
  box.querySelector('#calls-clear').addEventListener('click', async () => {
    if (!confirm('Clear your call history? (The other people keep theirs.)')) return;
    await app.api('/api/calls', { method: 'DELETE' }).catch((e) => app.toast(e.message, true));
    calls = [];
    draw();
    refreshMissedCalls();
  });

  try {
    ({ calls } = await app.api('/api/calls'));
    draw();
    await app.api('/api/calls/seen', { method: 'POST' });
    refreshMissedCalls();
  } catch (err) {
    list.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`;
  }
}

// ── Ringtones ────────────────────────────────────────────────
// Each tone is a short pattern of notes [frequency Hz, start s, length s],
// repeated every `every` seconds while the phone rings.

export const RINGTONES = {
  classic: { name: 'Classic ring', every: 3, notes: [[480, 0, 0.4], [620, 0, 0.4], [480, 0.5, 0.4], [620, 0.5, 0.4]] },
  chime: { name: 'Chime', every: 2.6, notes: [[1046.5, 0, 0.35], [1318.5, 0.18, 0.35], [1568, 0.36, 0.6]] },
  marimba: { name: 'Marimba', every: 2.2, notes: [[523.25, 0, 0.18], [659.25, 0.15, 0.18], [783.99, 0.3, 0.18], [659.25, 0.45, 0.18], [1046.5, 0.6, 0.3]] },
  pulse: { name: 'Pulse', every: 1.6, notes: [[880, 0, 0.12], [880, 0.2, 0.12], [880, 0.4, 0.12]] },
  retro: { name: 'Retro', every: 2.4, notes: [[1200, 0, 0.08], [900, 0.1, 0.08], [1200, 0.2, 0.08], [900, 0.3, 0.08], [1200, 0.4, 0.08], [900, 0.5, 0.08]] },
  calm: { name: 'Calm', every: 4, notes: [[392, 0, 1.2], [523.25, 0.6, 1.2], [659.25, 1.2, 1.6]] },
  silent: { name: 'Silent', every: 10, notes: [] },
};

const RT_DEFAULT = 'veyon.ringtone.default';
const rtKey = (userId) => `veyon.ringtone.${userId}`;
const read = (k) => { try { return localStorage.getItem(k); } catch { return null; } };
const write = (k, v) => { try { if (v) localStorage.setItem(k, v); else localStorage.removeItem(k); } catch { /* ignore */ } };

export const defaultRingtone = () => (RINGTONES[read(RT_DEFAULT)] ? read(RT_DEFAULT) : 'classic');
export const ringtoneFor = (userId) => (RINGTONES[read(rtKey(userId))] ? read(rtKey(userId)) : defaultRingtone());
export const ringtoneOverride = (userId) => (RINGTONES[read(rtKey(userId))] ? read(rtKey(userId)) : null);

let audioCtx = null;
let ringTimer = null;

function playOnce(id, volume = 0.18) {
  const tone = RINGTONES[id];
  if (!tone?.notes.length) return;
  audioCtx ||= new (window.AudioContext || window.webkitAudioContext)();
  const t0 = audioCtx.currentTime + 0.02;
  for (const [freq, at, len] of tone.notes) {
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.type = id === 'retro' ? 'square' : id === 'calm' ? 'sine' : 'triangle';
    osc.frequency.value = freq;
    gain.gain.setValueAtTime(0, t0 + at);
    gain.gain.linearRampToValueAtTime(volume, t0 + at + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, t0 + at + len);
    osc.connect(gain).connect(audioCtx.destination);
    osc.start(t0 + at);
    osc.stop(t0 + at + len + 0.05);
  }
}

/** Rings until stopRinging(). `id` = a ringtone, or 'ringback' (my outgoing call). */
export function startRinging(id) {
  stopRinging();
  if (id === 'ringback') {
    const beep = () => playOnce('classic', 0.06);
    beep();
    ringTimer = setInterval(beep, 3000);
    return;
  }
  const tone = RINGTONES[id] || RINGTONES.classic;
  playOnce(id);
  ringTimer = setInterval(() => playOnce(id), tone.every * 1000);
  navigator.vibrate?.([400, 200, 400]);
}

export function stopRinging() {
  clearInterval(ringTimer);
  ringTimer = null;
}

/** Pick a ringtone: for one contact (userId), or the default (no userId). */
export function openRingtonePicker(userId, name) {
  const current = userId ? (ringtoneOverride(userId) || '') : defaultRingtone();
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('bell')}</div>
      <h3>${userId ? `Ringtone for ${app.escapeHtml(name)}` : 'Default ringtone'}</h3>
      <p>${userId ? 'Plays when they call you. Tap ▶ to listen.' : 'Plays for incoming calls, unless a contact has their own.'}</p>
    </div>
    <div class="ringtone-list">
      ${userId ? `<label class="ringtone-row"><input type="radio" name="rt" value="" ${current === '' ? 'checked' : ''}>
        <span class="ringtone-name">Default <small>(${RINGTONES[defaultRingtone()].name})</small></span></label>` : ''}
      ${Object.entries(RINGTONES).map(([id, t]) => `
        <label class="ringtone-row">
          <input type="radio" name="rt" value="${id}" ${current === id ? 'checked' : ''}>
          <span class="ringtone-name">${t.name}</span>
          ${id === 'silent' ? '' : `<button type="button" class="icon-btn rt-play" data-id="${id}" aria-label="Play">${icon('play')}</button>`}
        </label>`).join('')}
    </div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="rt-save">Save</button>
    </div>`, { cardClass: 'feature-card', onClose: stopRinging });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelectorAll('.rt-play').forEach((b) => b.addEventListener('click', (e) => {
    e.preventDefault();
    stopRinging();
    playOnce(b.dataset.id);
  }));
  box.querySelector('#rt-save').addEventListener('click', () => {
    const v = box.querySelector('input[name=rt]:checked')?.value ?? '';
    if (userId) write(rtKey(userId), v || null); else write(RT_DEFAULT, v || 'classic');
    stopRinging();
    close();
    app.toast('Ringtone saved.');
  });
}

// ── Screen sharing in group calls ────────────────────────────

let screenTrack = null;

export const groupScreenSharing = () => !!screenTrack;

function videoSender(pc) {
  return pc.getSenders().find((s) => s.track?.kind === 'video' || s.track === screenTrack);
}

/** New peer while sharing: send them the screen too. */
export function applyGroupScreenShare(pc) {
  if (screenTrack) videoSender(pc)?.replaceTrack(screenTrack);
}

export async function toggleGroupScreenShare() {
  const call = app.state.groupCall;
  if (!call) return;
  if (screenTrack) { stopGroupScreenShare(); return; }
  if (!navigator.mediaDevices?.getDisplayMedia) { app.toast('Screen sharing isn’t supported in this browser.', true); return; }
  if (!call.localStream?.getVideoTracks().length) { app.toast('Screen sharing works in video calls.', true); return; }
  let display;
  try { display = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false }); } catch { return; }
  screenTrack = display.getVideoTracks()[0];
  if (!screenTrack) return;
  screenTrack.addEventListener('ended', stopGroupScreenShare, { once: true });
  for (const [, peer] of call.peers) videoSender(peer.pc)?.replaceTrack(screenTrack);
  call.cameraStream = call.localStream;
  call.localStream = new MediaStream([screenTrack, ...call.cameraStream.getAudioTracks()]);
  app.$('group-call-screen-btn')?.classList.add('active');
  app.renderGroupCallTiles();
  app.toast('You’re sharing your screen.');
}

export function stopGroupScreenShare() {
  const call = app.state.groupCall;
  const t = screenTrack;
  screenTrack = null;
  try { t?.stop(); } catch { /* ended */ }
  app.$('group-call-screen-btn')?.classList.remove('active');
  if (!call?.cameraStream) return;
  const cam = call.cameraStream.getVideoTracks()[0];
  for (const [, peer] of call.peers) {
    const sender = peer.pc.getSenders().find((s) => s.track === t || s.track?.kind === 'video');
    sender?.replaceTrack(cam);
  }
  call.localStream = call.cameraStream;
  call.cameraStream = null;
  app.renderGroupCallTiles();
}
