// Pinned message — one per chat, shared by everyone in it, shown in a bar
// under the chat header. Tap the bar to jump to the message.

import { app, icon, nameOf } from './core.js';

export function isPinned(convo, msgId) {
  return convo?.pinnedMessage?.id === msgId;
}

export function pinButtonHtml(m) {
  const convo = app.state.conversations.get(app.state.activeId);
  const pinned = isPinned(convo, m.id);
  return `<button type="button" class="bubble-action-btn pin-btn${pinned ? ' active' : ''}"
                  data-msg="${app.escapeAttr(m.id)}" title="${pinned ? 'Unpin' : 'Pin'}">${icon('pin')}</button>`;
}

export function wirePinButtons(root = document) {
  root.querySelectorAll('.pin-btn').forEach((btn) => {
    if (btn.dataset.wired) return;
    btn.dataset.wired = '1';
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      togglePin(btn.dataset.msg);
    });
  });
}

export function togglePin(msgId) {
  const convo = app.state.conversations.get(app.state.activeId);
  if (!convo || !app.canSendTo(convo)) return;
  const unpin = isPinned(convo, msgId);
  app.sendSocket({ type: 'pin-message', conversationId: convo.id, messageId: unpin ? null : msgId });
}

async function pinnedText(convo) {
  const pm = convo.pinnedMessage;
  if (!pm) return '';
  if (!app.state.plaintext.has(pm.id)) {
    try {
      const key = await app.keyFor(convo);
      app.state.plaintext.set(pm.id, await app.decryptBody(key, pm));
    } catch {
      app.state.plaintext.set(pm.id, null);
    }
  }
  return app.previewFor(pm);
}

/** Paints the pinned bar for the open chat (or hides it). */
export async function renderPinnedBar() {
  const bar = app.$('pinned-bar');
  if (!bar) return;
  const convo = app.state.conversations.get(app.state.activeId);
  if (!convo?.pinnedMessage) { bar.classList.add('hidden'); bar.innerHTML = ''; return; }

  const forId = convo.id;
  const text = await pinnedText(convo);
  if (app.state.activeId !== forId) return;   // switched chats while decrypting

  const who = convo.pinnedBy ? nameOf(convo, convo.pinnedBy) : '';
  bar.innerHTML = `
    <span class="pinned-bar-icon">${icon('pin')}</span>
    <span class="pinned-bar-body">
      <span class="pinned-bar-label">Pinned message${who ? ` · by ${app.escapeHtml(who)}` : ''}</span>
      <span class="pinned-bar-text">${app.escapeHtml(text)}</span>
    </span>
    <button type="button" class="icon-btn pinned-bar-unpin" title="Unpin" aria-label="Unpin">${icon('close')}</button>`;
  bar.classList.remove('hidden');
  bar.onclick = (e) => {
    if (e.target.closest('.pinned-bar-unpin')) { togglePin(convo.pinnedMessage.id); return; }
    jumpToPinned(convo);
  };
}

async function jumpToPinned(convo) {
  const id = convo.pinnedMessage?.id;
  if (!id) return;
  const has = () => (app.state.messages.get(convo.id) || []).some((m) => m.id === id);
  // Older than what's loaded? Pull earlier history until it shows up.
  for (let i = 0; i < 20 && !has(); i++) {
    const more = await app.loadOlderMessages(convo.id);
    if (!more) break;
  }
  if (has()) app.jumpToMessage(id);
  else app.toast('That message is too far back to show.');
}

export async function onMessagePinned(frame) {
  const convo = app.state.conversations.get(frame.conversationId);
  if (!convo) return;
  const before = convo.pinnedMessage?.id;
  convo.pinnedMessage = frame.message;
  convo.pinnedBy = frame.pinnedBy;
  if (frame.conversationId !== app.state.activeId) return;
  await renderPinnedBar();
  app.renderMessages();
  if (frame.message && frame.message.id !== before) {
    app.toast(`${nameOf(convo, frame.pinnedBy)} pinned a message.`);
  } else if (!frame.message && before) {
    app.toast('Message unpinned.');
  }
}
