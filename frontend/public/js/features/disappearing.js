// Disappearing messages — a per-chat timer everyone in the chat shares.
// New messages get an expiry from the server; this module hides them here
// the moment they expire (the server deletes them for good shortly after).

import { app, icon, nameOf, openModal } from './core.js';

export const DISAPPEAR_OPTIONS = [
  { seconds: 0, label: 'Off', short: '' },
  { seconds: 86400, label: '24 hours', short: '24h' },
  { seconds: 604800, label: '7 days', short: '7d' },
  { seconds: 7776000, label: '90 days', short: '90d' },
];

export function disappearLabel(seconds) {
  return DISAPPEAR_OPTIONS.find((o) => o.seconds === seconds)?.label || 'Off';
}

function shortLabel(seconds) {
  return DISAPPEAR_OPTIONS.find((o) => o.seconds === seconds)?.short || '';
}

/** Small timer mark in a bubble's meta row for a message that will vanish. */
export function expiryMark(m) {
  if (!m.expiresAt) return '';
  const left = new Date(m.expiresAt) - Date.now();
  const hours = Math.max(0, Math.round(left / 3600000));
  const title = hours >= 48 ? `Disappears in ${Math.round(hours / 24)} days` : `Disappears in ${hours} hours`;
  return `<span class="expiry-mark" title="${title}">${icon('timer')}</span>`;
}

/** Header chip + the note shown at the top of the chat while it's on. */
export function renderDisappearingChip() {
  const chip = app.$('disappear-chip');
  if (!chip) return;
  const convo = app.state.conversations.get(app.state.activeId);
  const seconds = convo?.disappearSeconds || 0;
  chip.classList.toggle('hidden', !seconds);
  chip.innerHTML = seconds ? `${icon('timer')}<span>${shortLabel(seconds)}</span>` : '';
  chip.title = seconds ? `Disappearing messages: ${disappearLabel(seconds)}` : '';
}

export function disappearingNoteHtml(convo) {
  const seconds = convo?.disappearSeconds || 0;
  if (!seconds) return '';
  return `<div class="chat-system-note">${icon('timer')}
    <span>Disappearing messages are on. New messages vanish from this chat ${disappearLabel(seconds).toLowerCase()} after they're sent.</span></div>`;
}

export function openDisappearingPicker() {
  const convo = app.state.conversations.get(app.state.activeId);
  if (!convo || !app.canSendTo(convo)) return;
  const current = convo.disappearSeconds || 0;

  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('timer')}</div>
      <h3>Disappearing messages</h3>
      <p>Make new messages in this chat vanish after a set time — for everyone in it.
         Messages already sent stay as they are.</p>
    </div>
    <div class="choice-list" role="radiogroup">
      ${DISAPPEAR_OPTIONS.map((o) => `
        <button type="button" class="choice-row${o.seconds === current ? ' selected' : ''}" role="radio"
                aria-checked="${o.seconds === current}" data-seconds="${o.seconds}">
          <span class="choice-radio"></span>
          <span class="choice-label">${o.label}</span>
        </button>`).join('')}
    </div>
    <p class="feature-footnote">${icon('info')} Anyone in the chat can still copy, forward or screenshot a message before it disappears.</p>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="dm-save">Save</button>
    </div>`, { cardClass: 'feature-card' });

  let picked = current;
  box.querySelectorAll('.choice-row').forEach((row) => {
    row.addEventListener('click', () => {
      picked = Number(row.dataset.seconds);
      box.querySelectorAll('.choice-row').forEach((r) => {
        r.classList.toggle('selected', r === row);
        r.setAttribute('aria-checked', String(r === row));
      });
    });
  });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#dm-save').addEventListener('click', () => {
    if (picked !== current) {
      app.sendSocket({ type: 'set-disappearing', conversationId: convo.id, seconds: picked });
    }
    close();
  });
}

export function onDisappearingChanged(frame) {
  const convo = app.state.conversations.get(frame.conversationId);
  if (!convo) return;
  convo.disappearSeconds = frame.seconds;
  if (frame.conversationId === app.state.activeId) {
    renderDisappearingChip();
    app.renderMessages();
    const who = nameOf(convo, frame.byUserId);
    app.toast(frame.seconds
      ? `${who} turned on disappearing messages (${disappearLabel(frame.seconds)}).`
      : `${who} turned off disappearing messages.`);
  }
}

/** Removes expired messages from every loaded chat; re-renders if needed. */
export function pruneExpired() {
  const now = Date.now();
  let activeChanged = false;
  for (const [conversationId, list] of app.state.messages) {
    const keep = list.filter((m) => !m.expiresAt || new Date(m.expiresAt).getTime() > now);
    if (keep.length !== list.length) {
      app.state.messages.set(conversationId, keep);
      if (conversationId === app.state.activeId) activeChanged = true;
      const convo = app.state.conversations.get(conversationId);
      if (convo?.lastMessage?.expiresAt && new Date(convo.lastMessage.expiresAt).getTime() <= now) {
        convo.lastMessage = keep[keep.length - 1] || null;
      }
      if (convo?.pinnedMessage?.expiresAt && new Date(convo.pinnedMessage.expiresAt).getTime() <= now) {
        convo.pinnedMessage = null;
      }
    }
  }
  if (activeChanged) app.renderMessages();
}

let pruneTimer = null;
export function startExpiryWatcher() {
  clearInterval(pruneTimer);
  pruneTimer = setInterval(pruneExpired, 30_000);
}
