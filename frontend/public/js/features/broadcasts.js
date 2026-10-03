// Broadcast lists — send one message to many people privately. Each person
// gets it as a normal 1:1 message, encrypted for them alone, and their
// replies come back to your own chat with them (nobody sees the list).

import { app, icon, openModal } from './core.js';

let lists = [];

async function loadLists() {
  ({ lists } = await app.api('/api/broadcasts'));
}

function contactById(id) {
  return app.directContacts().find((c) => c.id === id);
}

function directConvoWith(userId) {
  return [...app.state.conversations.values()]
    .find((c) => c.kind === 'direct' && c.peer?.id === userId && c.status === 'accepted');
}

export async function openBroadcastsPanel() {
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('broadcast')}</div>
      <h3>Broadcast lists</h3>
      <p>Send one message to many people at once — each gets it privately, like a normal message from you.</p>
    </div>
    <div class="bc-lists" id="bc-lists"><div class="ai-loading"><span></span><span></span><span></span> Loading…</div></div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" id="bc-new">${icon('plus')} New list</button>
      <button type="button" class="btn-primary" data-close>Done</button>
    </div>`, { cardClass: 'feature-card' });

  const listsEl = box.querySelector('#bc-lists');
  const render = () => {
    const { escapeHtml, escapeAttr } = app;
    listsEl.innerHTML = lists.length ? lists.map((l) => {
      const names = l.memberIds.map((id) => contactById(id)?.displayName).filter(Boolean);
      return `
        <div class="bc-row">
          <div class="bc-row-icon">${icon('broadcast')}</div>
          <div class="bc-row-body">
            <div class="bc-row-name">${escapeHtml(l.name)}</div>
            <div class="bc-row-sub">${l.memberIds.length} recipient${l.memberIds.length === 1 ? '' : 's'} · ${escapeHtml(names.slice(0, 4).join(', '))}${names.length > 4 ? '…' : ''}</div>
          </div>
          <button type="button" class="btn-primary bc-send" data-send="${escapeAttr(l.id)}">${icon('send')} Send</button>
          <button type="button" class="icon-btn" data-edit="${escapeAttr(l.id)}" title="Edit">${icon('edit')}</button>
          <button type="button" class="icon-btn danger" data-del="${escapeAttr(l.id)}" title="Delete">${icon('trash')}</button>
        </div>`;
    }).join('') : '<div class="ai-empty">No broadcast lists yet. Create one to message a group of contacts privately.</div>';

    listsEl.querySelectorAll('[data-send]').forEach((b) => b.addEventListener('click', () => {
      openBroadcastComposer(lists.find((l) => l.id === b.dataset.send));
    }));
    listsEl.querySelectorAll('[data-edit]').forEach((b) => b.addEventListener('click', () => {
      openListEditor(lists.find((l) => l.id === b.dataset.edit), render);
    }));
    listsEl.querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', async () => {
      const l = lists.find((x) => x.id === b.dataset.del);
      if (!confirm(`Delete the broadcast list "${l.name}"? Messages already sent stay in each chat.`)) return;
      try {
        await app.api(`/api/broadcasts/${l.id}`, { method: 'DELETE' });
        lists = lists.filter((x) => x.id !== l.id);
        render();
      } catch (err) { app.toast(err.message, true); }
    }));
  };

  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#bc-new').addEventListener('click', () => openListEditor(null, render));
  try { await loadLists(); render(); } catch (err) {
    listsEl.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`;
  }
}

function openListEditor(existing, onSaved) {
  const contacts = app.directContacts().sort((a, b) => a.displayName.localeCompare(b.displayName));
  const picked = new Set(existing?.memberIds || []);
  const { escapeHtml, escapeAttr } = app;

  const { box, close } = openModal(`
    <h3>${existing ? 'Edit broadcast list' : 'New broadcast list'}</h3>
    <div class="field">
      <label>List name</label>
      <input type="text" id="bc-name" maxlength="60" placeholder="e.g. Customers, Family" value="${escapeAttr(existing?.name || '')}">
    </div>
    <div class="field">
      <label>Recipients <span class="bc-count" id="bc-count"></span></label>
      <div class="search-box bc-search">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
        <input id="bc-filter" placeholder="Search contacts" autocomplete="off">
      </div>
      <div class="pick-list" id="bc-pick">
        ${contacts.length ? contacts.map((c) => `
          <label class="pick-row" data-name="${escapeAttr(c.displayName.toLowerCase())}">
            <span class="avatar sm" style="background:${escapeAttr(c.avatarColor)}">${app.avatarInner(c)}</span>
            <span class="pick-name">${escapeHtml(c.displayName)}<span class="pick-handle">@${escapeHtml(c.username)}</span></span>
            <input type="checkbox" class="switch small" value="${escapeAttr(c.id)}" ${picked.has(c.id) ? 'checked' : ''}>
          </label>`).join('')
        : '<div class="ai-empty">You need accepted chats with people before you can add them.</div>'}
      </div>
    </div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="bc-save">Save</button>
    </div>`, { cardClass: 'feature-card' });

  const countEl = box.querySelector('#bc-count');
  const updateCount = () => { countEl.textContent = picked.size ? `· ${picked.size} selected` : ''; };
  box.querySelectorAll('#bc-pick input').forEach((cb) => cb.addEventListener('change', () => {
    if (cb.checked) picked.add(cb.value); else picked.delete(cb.value);
    updateCount();
  }));
  box.querySelector('#bc-filter').addEventListener('input', (e) => {
    const q = e.target.value.trim().toLowerCase();
    box.querySelectorAll('.pick-row').forEach((row) => { row.classList.toggle('hidden', !!q && !row.dataset.name.includes(q)); });
  });
  updateCount();
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#bc-save').addEventListener('click', async () => {
    const payload = JSON.stringify({ name: box.querySelector('#bc-name').value, memberIds: [...picked] });
    try {
      if (existing) {
        const { list } = await app.api(`/api/broadcasts/${existing.id}`, { method: 'PUT', body: payload });
        lists = lists.map((l) => (l.id === list.id ? list : l));
      } else {
        const { list } = await app.api('/api/broadcasts', { method: 'POST', body: payload });
        lists = [...lists, list];
      }
      close();
      onSaved();
    } catch (err) { app.toast(err.message, true); }
  });
  box.querySelector('#bc-name').focus();
}

function openBroadcastComposer(list) {
  const { escapeHtml } = app;
  const { box, close } = openModal(`
    <h3>${icon('broadcast', 'class="modal-title-icon"')} ${escapeHtml(list.name)}</h3>
    <p class="feature-sub">Goes to ${list.memberIds.length} people, each as a private message from you.</p>
    <div class="field">
      <textarea id="bc-text" rows="5" maxlength="4000" placeholder="Type your message…"></textarea>
    </div>
    <div class="export-progress hidden" id="bc-progress"></div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="bc-go" disabled>${icon('send')} Send to ${list.memberIds.length}</button>
    </div>`, { cardClass: 'feature-card' });

  const textEl = box.querySelector('#bc-text');
  const go = box.querySelector('#bc-go');
  textEl.addEventListener('input', () => { go.disabled = !textEl.value.trim(); });
  box.querySelector('[data-close]').addEventListener('click', close);
  go.addEventListener('click', async () => {
    const text = textEl.value.trim();
    if (!text) return;
    go.disabled = true;
    textEl.disabled = true;
    const progress = box.querySelector('#bc-progress');
    progress.classList.remove('hidden');
    let sent = 0;
    const failed = [];
    for (const userId of list.memberIds) {
      const convo = directConvoWith(userId);
      if (!convo) { failed.push(contactById(userId)?.displayName || 'someone'); continue; }
      try {
        await sendTextTo(convo, text);
        sent++;
        progress.textContent = `Sending… ${sent} of ${list.memberIds.length}`;
      } catch {
        failed.push(convo.peer.displayName);
      }
    }
    progress.textContent = failed.length
      ? `Sent to ${sent}. Couldn't send to: ${failed.join(', ')}`
      : `Sent to all ${sent} ✓`;
    app.renderChatList();
    if (!failed.length) setTimeout(close, 900);
  });
  textEl.focus();
}

/** One normal, individually encrypted 1:1 message (same path as the composer). */
async function sendTextTo(convo, text) {
  const tempId = 'temp-' + crypto.randomUUID();
  app.state.plaintext.set(tempId, text);
  if (app.state.messages.has(convo.id)) {
    app.pushMessage(convo.id, { id: tempId, senderId: app.state.me.id, kind: 'text', createdAt: new Date().toISOString(), pending: true });
  }
  const key = await app.keyFor(convo);
  const { ciphertext, iv } = await app.encryptText(key, text);
  app.sendSocket({ type: 'send', conversationId: convo.id, ciphertext, iv, kind: 'text', tempId });
  if (convo.id === app.state.activeId) app.renderMessages();
}
