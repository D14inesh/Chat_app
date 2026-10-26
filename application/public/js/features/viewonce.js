// View-once photos & videos — the recipient can open it a single time.
// It's decrypted straight into a viewer and never saved on this device;
// after opening, the server refuses to hand the file out again.

import { app, icon, nameOf } from './core.js';

export function pickViewOnce() {
  const inputEl = document.createElement('input');
  inputEl.type = 'file';
  inputEl.accept = 'image/*,video/*';
  inputEl.addEventListener('change', () => {
    const file = inputEl.files[0];
    if (!file) return;
    if (!/^(image|video)\//.test(file.type)) { app.toast('View once works for photos and videos.', true); return; }
    app.sendMediaFile(file, { viewOnce: true });
    app.toast('Sent as view once — they can open it one time.');
  });
  inputEl.click();
}

function kindWord(plain) {
  return (plain?.mime || '').startsWith('video/') ? 'Video' : 'Photo';
}

export function viewOncePreview(plain) {
  return `${(plain?.mime || '').startsWith('video/') ? '🎥' : '📷'} ${kindWord(plain)} · view once`;
}

/** Bubble body for a view-once message (both sides). */
export function viewOnceBody(m, plain) {
  const mine = m.senderId === app.state.me.id;
  const opened = (m.openedBy || []).includes(app.state.me.id);
  const word = kindWord(plain);
  let state;
  let cls = '';
  if (mine) {
    const convo = app.state.conversations.get(app.state.activeId);
    const openers = (m.openedBy || []).map((u) => nameOf(convo, u));
    state = openers.length ? `Opened${convo?.kind === 'group' ? ` by ${openers.join(', ')}` : ''}` : 'Not opened yet';
    cls = 'is-sender';
  } else if (opened) {
    state = 'Opened';
    cls = 'is-opened';
  } else {
    state = 'Tap to view';
    cls = 'is-ready';
  }
  return `
    <button type="button" class="view-once ${cls}" data-msg="${app.escapeAttr(m.id)}"
            ${cls === 'is-ready' && !m.pending ? '' : 'disabled'}>
      <span class="view-once-badge">1</span>
      <span class="view-once-body">
        <span class="view-once-title">${word}</span>
        <span class="view-once-state">${state}</span>
      </span>
    </button>`;
}

export function wireViewOnce(root = document) {
  root.querySelectorAll('.view-once.is-ready').forEach((btn) => {
    if (btn.dataset.wired) return;
    btn.dataset.wired = '1';
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      openViewOnce(btn.dataset.msg, btn);
    });
  });
}

async function openViewOnce(msgId, btn) {
  const conversationId = app.state.activeId;
  const list = app.state.messages.get(conversationId) || [];
  const m = list.find((x) => x.id === msgId);
  const meta = app.state.plaintext.get(msgId);
  if (!m || !meta) return;

  const stateEl = btn.querySelector('.view-once-state');
  stateEl.textContent = 'Opening…';
  btn.disabled = true;

  let url;
  try {
    // Straight from the server, never from (or into) the on-device media cache.
    const res = await fetch(app.apiUrl(`/api/upload/${m.filePath}`), { credentials: 'include' });
    if (res.status === 410) throw new Error('already-opened');
    if (!res.ok) throw new Error('Could not download it.');
    const key = app.state.keys.get(conversationId);
    const bytes = await app.decryptFileBytes(key, await res.arrayBuffer(), meta.blobIv);
    url = URL.createObjectURL(new Blob([bytes], { type: meta.mime }));
  } catch (err) {
    if (err.message === 'already-opened') markOpened(m);
    else { app.toast(err.message, true); stateEl.textContent = 'Tap to view'; btn.disabled = false; }
    return;
  }

  // Counts as opened the moment it's on screen.
  markOpened(m);
  app.sendSocket({ type: 'view-once-opened', conversationId, messageId: msgId });
  showViewer(url, (meta.mime || '').startsWith('video/'));
}

function markOpened(m) {
  m.openedBy = [...new Set([...(m.openedBy || []), app.state.me.id])];
  app.renderMessages();
}

function showViewer(url, isVideo) {
  const box = document.createElement('div');
  box.className = 'view-once-viewer';
  box.innerHTML = `
    <div class="view-once-top">
      <span class="view-once-badge">1</span>
      <span>View once — this closes for good</span>
      <button type="button" class="icon-btn" aria-label="Close">${icon('close')}</button>
    </div>
    ${isVideo
      ? `<video src="${url}" autoplay playsinline controls controlslist="nodownload noplaybackrate" disablepictureinpicture></video>`
      : `<img src="${url}" alt="" draggable="false">`}`;
  document.body.appendChild(box);
  box.addEventListener('contextmenu', (e) => e.preventDefault());
  const close = () => {
    box.remove();
    URL.revokeObjectURL(url);
    document.removeEventListener('keydown', onKey);
  };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', onKey);
  box.querySelector('button').addEventListener('click', close);
}

export function onViewOnceOpened(frame) {
  const list = app.state.messages.get(frame.conversationId);
  const m = list?.find((x) => x.id === frame.messageId);
  if (!m) return;
  m.openedBy = [...new Set([...(m.openedBy || []), frame.userId])];
  if (frame.conversationId === app.state.activeId) app.renderMessages();
}
