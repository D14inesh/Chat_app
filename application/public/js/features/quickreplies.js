// Quick replies — saved answers. Type "/" in the composer to pick one;
// manage them from the sidebar menu. Synced to every device you use.

import { app, icon, openModal } from './core.js';

let replies = [];
let loaded = false;
let popup = null;
let activeIndex = 0;
let matches = [];

export async function loadQuickReplies() {
  try {
    ({ replies } = await app.api('/api/quick-replies'));
    loaded = true;
  } catch { /* offline — the "/" popup just stays empty for now */ }
}

// ── Composer "/" popup ─────────────────────────────────────

function slashQuery(value) {
  const m = /^\/([a-z0-9_-]*)$/i.exec(value);
  return m ? m[1].toLowerCase() : null;
}

export function onComposerInput(inputEl) {
  const q = slashQuery(inputEl.value);
  if (q === null) { hidePopup(); return; }
  if (!loaded) loadQuickReplies().then(() => onComposerInput(inputEl));
  matches = replies.filter((r) => r.shortcut.startsWith(q) || r.body.toLowerCase().includes(q)).slice(0, 8);
  activeIndex = 0;
  showPopup(inputEl);
}

/** Returns true when the key was handled by the popup. */
export function onComposerKeydown(e, inputEl) {
  if (!popup) return false;
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    if (!matches.length) return true;
    activeIndex = (activeIndex + (e.key === 'ArrowDown' ? 1 : -1) + matches.length) % matches.length;
    showPopup(inputEl);
    return true;
  }
  if ((e.key === 'Enter' || e.key === 'Tab') && matches.length) {
    e.preventDefault();
    insert(inputEl, matches[activeIndex]);
    return true;
  }
  if (e.key === 'Escape') { hidePopup(); return true; }
  return false;
}

function insert(inputEl, reply) {
  inputEl.value = reply.body;
  hidePopup();
  inputEl.focus();
  inputEl.dispatchEvent(new Event('input'));
}

function showPopup(inputEl) {
  const host = app.$('composer');
  if (!popup) {
    popup = document.createElement('div');
    popup.className = 'quick-reply-popup';
    host.appendChild(popup);
  }
  const { escapeHtml } = app;
  popup.innerHTML = `
    <div class="qr-popup-head">${icon('quick')} Quick replies
      <button type="button" class="qr-popup-manage">Manage</button></div>
    ${matches.length ? matches.map((r, i) => `
      <button type="button" class="qr-popup-item${i === activeIndex ? ' active' : ''}" data-i="${i}">
        <span class="qr-shortcut">/${escapeHtml(r.shortcut)}</span>
        <span class="qr-body">${escapeHtml(r.body)}</span>
      </button>`).join('')
    : `<div class="qr-popup-empty">${replies.length ? 'No match.' : 'No quick replies yet.'}
         <button type="button" class="qr-popup-create">Create one</button></div>`}`;
  popup.querySelectorAll('.qr-popup-item').forEach((el) => {
    el.addEventListener('mousedown', (e) => { e.preventDefault(); insert(inputEl, matches[Number(el.dataset.i)]); });
  });
  popup.querySelector('.qr-popup-manage')?.addEventListener('mousedown', (e) => { e.preventDefault(); hidePopup(); openQuickRepliesPanel(); });
  popup.querySelector('.qr-popup-create')?.addEventListener('mousedown', (e) => { e.preventDefault(); hidePopup(); openQuickRepliesPanel(true); });
}

export function hidePopup() {
  popup?.remove();
  popup = null;
}

// ── Manage panel ───────────────────────────────────────────

export async function openQuickRepliesPanel(startAdding = false) {
  if (!loaded) await loadQuickReplies();
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('quick')}</div>
      <h3>Quick replies</h3>
      <p>Save answers you send often. In any chat, type <kbd>/</kbd> and the shortcut to insert one.</p>
    </div>
    <div class="qr-list" id="qr-list"></div>
    <form class="qr-form hidden" id="qr-form" autocomplete="off">
      <div class="field">
        <label>Shortcut</label>
        <div class="qr-shortcut-input"><span>/</span><input id="qr-shortcut" maxlength="24" placeholder="hours"></div>
      </div>
      <div class="field">
        <label>Message</label>
        <textarea id="qr-body" rows="3" maxlength="2000" placeholder="Our office is open 9 am – 6 pm, Monday to Saturday."></textarea>
      </div>
      <div class="qr-form-actions">
        <button type="button" class="btn-secondary" id="qr-cancel">Cancel</button>
        <button type="submit" class="btn-primary" id="qr-save">Save</button>
      </div>
    </form>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" id="qr-add">${icon('plus')} New quick reply</button>
      <button type="button" class="btn-primary" data-close>Done</button>
    </div>`, { cardClass: 'feature-card' });

  const listEl = box.querySelector('#qr-list');
  const form = box.querySelector('#qr-form');
  const shortcutEl = box.querySelector('#qr-shortcut');
  const bodyEl = box.querySelector('#qr-body');
  let editingId = null;

  const render = () => {
    const { escapeHtml, escapeAttr } = app;
    listEl.innerHTML = replies.length ? replies.map((r) => `
      <div class="qr-row">
        <div class="qr-row-main">
          <span class="qr-shortcut">/${escapeHtml(r.shortcut)}</span>
          <span class="qr-row-body">${escapeHtml(r.body)}</span>
        </div>
        <button type="button" class="icon-btn" data-edit="${escapeAttr(r.id)}" title="Edit">${icon('edit')}</button>
        <button type="button" class="icon-btn danger" data-del="${escapeAttr(r.id)}" title="Delete">${icon('trash')}</button>
      </div>`).join('')
      : '<div class="ai-empty">No quick replies yet — add your first one.</div>';
    listEl.querySelectorAll('[data-edit]').forEach((b) => b.addEventListener('click', () => {
      const r = replies.find((x) => x.id === b.dataset.edit);
      editingId = r.id;
      shortcutEl.value = r.shortcut;
      bodyEl.value = r.body;
      form.classList.remove('hidden');
      bodyEl.focus();
    }));
    listEl.querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', async () => {
      try {
        await app.api(`/api/quick-replies/${b.dataset.del}`, { method: 'DELETE' });
        replies = replies.filter((x) => x.id !== b.dataset.del);
        render();
      } catch (err) { app.toast(err.message, true); }
    }));
  };

  const openForm = () => {
    editingId = null;
    shortcutEl.value = '';
    bodyEl.value = '';
    form.classList.remove('hidden');
    shortcutEl.focus();
  };

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const payload = JSON.stringify({ shortcut: shortcutEl.value, body: bodyEl.value });
    try {
      if (editingId) {
        const { reply } = await app.api(`/api/quick-replies/${editingId}`, { method: 'PATCH', body: payload });
        replies = replies.map((r) => (r.id === editingId ? reply : r));
      } else {
        const { reply } = await app.api('/api/quick-replies', { method: 'POST', body: payload });
        replies = [...replies, reply];
      }
      replies.sort((a, b) => a.shortcut.localeCompare(b.shortcut));
      form.classList.add('hidden');
      render();
    } catch (err) { app.toast(err.message, true); }
  });
  shortcutEl.addEventListener('input', () => { shortcutEl.value = shortcutEl.value.replace(/[^a-z0-9_-]/gi, '').toLowerCase(); });
  box.querySelector('#qr-cancel').addEventListener('click', () => form.classList.add('hidden'));
  box.querySelector('#qr-add').addEventListener('click', openForm);
  box.querySelector('[data-close]').addEventListener('click', close);
  render();
  if (startAdding) openForm();
}
