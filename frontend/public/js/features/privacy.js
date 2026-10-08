// Age (only private 1-to-1 chats and calls are 18+), the private-chats PIN,
// and Archive.

import { app, icon } from './core.js';

const today = () => new Date().toISOString().slice(0, 10);
const UNDER_18 = 'Private chats are for people 18 and over. Groups and everything else work for you.';

/** Sign-up form field — optional; only private chats need it. */
export function birthFieldHtml() {
  return `
    <div class="field">
      <label for="f-birth">Date of birth <span style="opacity:.55;font-weight:500">optional</span></label>
      <input id="f-birth" type="date" max="${today()}" min="1900-01-01">
      <div class="field-hint">Only needed for private (1-to-1) chats, which are 18+. You can add it later.</div>
    </div>`;
}

/** Asks for a date of birth (once — it can't be changed). Resolves true
 *  when saved, false when the person chose "Not now". */
function askBirthDate() {
  return new Promise((resolve) => {
    const box = document.createElement('div');
    box.className = 'modal-backdrop';
    box.innerHTML = `
      <div class="modal-card feature-card birth-card">
        <div class="feature-hero">
          <div class="feature-hero-icon">${icon('shield')}</div>
          <h3>Private chats are 18+</h3>
          <p>Add your date of birth once to use private chats and calls. Groups, status and everything else don't need it.</p>
        </div>
        <div class="auth-error hidden" id="birth-error"></div>
        <div class="field"><label>Date of birth</label><input id="birth-input" type="date" max="${today()}" min="1900-01-01"></div>
        <p class="join-note">You can set this once, so please check it's correct.</p>
        <div class="modal-actions">
          <button type="button" class="btn-secondary" id="birth-later">Not now</button>
          <button type="button" class="btn-primary" id="birth-save">Save</button>
        </div>
      </div>`;
    document.body.appendChild(box);
    const done = (saved) => { box.remove(); resolve(saved); };
    const err = box.querySelector('#birth-error');
    box.querySelector('#birth-later').addEventListener('click', () => done(false));
    box.addEventListener('click', (e) => { if (e.target === box) done(false); });
    box.querySelector('#birth-save').addEventListener('click', async () => {
      const value = box.querySelector('#birth-input').value;
      if (!value) { err.textContent = 'Pick your date of birth.'; err.classList.remove('hidden'); return; }
      if (!confirm(`Save ${new Date(`${value}T00:00`).toLocaleDateString()} as your date of birth? It can't be changed later.`)) return;
      try {
        const res = await app.api('/api/auth/birth-date', { method: 'POST', body: JSON.stringify({ birthDate: value }) });
        Object.assign(app.state.me, res);
        done(true);
      } catch (e) {
        err.textContent = e.message;
        err.classList.remove('hidden');
      }
    });
  });
}

/** The door to private chats: asks for a date of birth the first time,
 *  then lets 18+ through. Resolves true when the private chat may open. */
export async function privateChatGate() {
  const me = app.state.me;
  if (!me) return false;
  if (!me.birthDate && !(await askBirthDate())) return false;
  if (!me.isAdult) { app.toast(UNDER_18, true); return false; }
  return true;
}

// ── Private-chats PIN (every 1-to-1 chat behind the chat-lock PIN) ──

export async function setPrivateLock(enabled, pin) {
  const res = await app.api('/api/chat-lock/private', { method: 'PATCH', body: JSON.stringify({ enabled, pin }) });
  app.state.me.privateLock = res.enabled;
  await app.loadConversations();
  return res.enabled;
}

// ── Archive ──────────────────────────────────────────────────

let showingArchived = false;
export const viewingArchived = () => showingArchived;

/** Chat list: archived chats stay out of the main list. */
export function archiveFilter(convos) {
  return convos.filter((c) => !!c.archived === showingArchived);
}

export function archivedRowHtml() {
  const archived = [...app.state.conversations.values()].filter((c) => c.archived);
  if (showingArchived) {
    return `<button type="button" class="archived-row open" id="archived-back">
      <span class="locked-icon">${icon('close')}</span><span class="locked-title">Archived chats</span>
      <span class="locked-sub">Back to chats</span></button>`;
  }
  if (!archived.length) return '';
  const unread = archived.filter((c) => c.unread > 0).length;
  return `<button type="button" class="archived-row" id="archived-row">
    <span class="locked-icon">${icon('archive')}</span>
    <span class="locked-title">Archived</span>
    <span class="locked-sub">${unread ? `${unread} unread` : archived.length}</span></button>`;
}

export function wireArchivedRow(listEl) {
  listEl.querySelector('#archived-row')?.addEventListener('click', () => { showingArchived = true; app.renderChatList(); });
  listEl.querySelector('#archived-back')?.addEventListener('click', () => { showingArchived = false; app.renderChatList(); });
}

export async function toggleArchive(convo) {
  if (!convo) return;
  const next = !convo.archived;
  convo.archived = next;
  app.renderChatList();
  try {
    await app.api(`/api/conversations/${convo.id}/archive`, { method: 'PATCH', body: JSON.stringify({ archived: next }) });
    app.toast(next ? 'Chat archived. It stays there quietly — find it under “Archived”.' : 'Chat unarchived.');
    if (next && app.state.activeId === convo.id) app.closeActiveChat();
  } catch (e) {
    convo.archived = !next;
    app.renderChatList();
    app.toast(e.message, true);
  }
}
