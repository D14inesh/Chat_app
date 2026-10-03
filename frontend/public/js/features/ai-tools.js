// AI on chat text: summarize a chat, translate a message, suggest replies.
// Chats are end-to-end encrypted, so the browser decrypts the messages and
// sends only the text you asked about to your own server's AI. Nothing is
// stored; every screen here says so plainly.

import { app, icon, nameOf, openModal, prefs } from './core.js';

export const LANGUAGES = [
  ['en', 'English'], ['ta', 'Tamil'], ['hi', 'Hindi'], ['te', 'Telugu'], ['ml', 'Malayalam'], ['kn', 'Kannada'],
  ['ar', 'Arabic'], ['fr', 'French'], ['es', 'Spanish'], ['de', 'German'], ['zh', 'Chinese'], ['ja', 'Japanese'],
];

const langName = (code) => LANGUAGES.find(([c]) => c === code)?.[1] || 'English';

function lineFor(convo, m) {
  const plain = app.state.plaintext.get(m.id);
  if (m.deleted || plain == null) return null;
  let text;
  if (m.kind === 'text') text = plain;
  else if (m.kind === 'poll') text = `[poll] ${plain.question}: ${(plain.options || []).join(' / ')}`;
  else if (m.kind === 'location') text = '[shared a location]';
  else if (m.kind === 'voice') text = '[voice message]';
  else if (m.kind === 'contact') text = `[shared contact ${plain.name}]`;
  else if (m.kind === 'file') text = `[sent ${plain.gif ? 'a GIF' : plain.sticker ? 'a sticker' : `a file: ${plain.name}`}]`;
  if (!text) return null;
  const name = m.senderId === app.state.me.id ? app.state.me.displayName : nameOf(convo, m.senderId);
  return { name, text: String(text).slice(0, 600) };
}

function recentLines(convo, limit) {
  const list = app.state.messages.get(convo.id) || [];
  return list.slice(-limit).map((m) => lineFor(convo, m)).filter(Boolean);
}

const PRIVACY_NOTE = `${icon('info')} The text of these messages is decrypted on your device and sent to
  your server's AI to do this. It isn't stored — but it does leave end-to-end encryption.`;

// ── Summarize ───────────────────────────────────────────────

export async function openSummarize() {
  const convo = app.state.conversations.get(app.state.activeId);
  if (!convo) return;

  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon ai">${icon('sparkle')}</div>
      <h3>Summary</h3>
      <p class="summary-sub">The last messages in this chat, in a few lines.</p>
    </div>
    <div class="ai-result" id="sum-result"><div class="ai-loading"><span></span><span></span><span></span> Reading the chat…</div></div>
    <p class="feature-footnote">${PRIVACY_NOTE}</p>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" id="sum-copy" disabled>${icon('copy')} Copy</button>
      <button type="button" class="btn-primary" data-close>Done</button>
    </div>`, { cardClass: 'feature-card' });
  box.querySelector('[data-close]').addEventListener('click', close);

  // Up to 150 messages: what's loaded, topped up from older history.
  for (let i = 0; i < 2 && (app.state.messages.get(convo.id) || []).length < 150; i++) {
    if (!(await app.loadOlderMessages(convo.id))) break;
  }
  const lines = recentLines(convo, 150);
  const result = box.querySelector('#sum-result');
  if (!lines.length) { result.innerHTML = '<div class="ai-empty">Nothing to summarize yet.</div>'; return; }

  try {
    const { summary } = await app.api('/api/ai/summarize', { method: 'POST', body: JSON.stringify({ lines }) });
    const points = summary.split('\n').map((l) => l.trim()).filter(Boolean);
    result.innerHTML = `<ul class="ai-points">${points.map((p) =>
      `<li>${app.escapeHtml(p.replace(/^[•\-*]\s*/, ''))}</li>`).join('')}</ul>
      <div class="ai-meta">Based on the last ${lines.length} messages</div>`;
    const copy = box.querySelector('#sum-copy');
    copy.disabled = false;
    copy.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(summary); app.toast('Summary copied.'); } catch { app.toast('Could not copy.', true); }
    });
  } catch (err) {
    result.innerHTML = `<div class="ai-error">${icon('info')} ${app.escapeHtml(err.message)}</div>`;
  }
}

// ── Translate ───────────────────────────────────────────────

const translations = new Map(); // messageId -> { text, lang, loading, error }

export function translateButtonHtml(m) {
  if (m.kind !== 'text' || m.deleted) return '';
  return `<button type="button" class="bubble-action-btn translate-btn" data-msg="${app.escapeAttr(m.id)}"
                  title="Translate">${icon('translate')}</button>`;
}

export function translationHtml(m) {
  const t = translations.get(m.id);
  if (!t) return '';
  if (t.loading) return `<div class="translation loading"><span class="translation-label">${icon('translate')} Translating…</span></div>`;
  if (t.error) return `<div class="translation error"><span class="translation-label">${icon('translate')} ${app.escapeHtml(t.error)}</span></div>`;
  return `<div class="translation">
    <span class="translation-label">${icon('translate')} ${app.escapeHtml(langName(t.lang))}
      <button type="button" class="translation-change" data-msg="${app.escapeAttr(m.id)}">Change</button>
      <button type="button" class="translation-hide" data-msg="${app.escapeAttr(m.id)}">Hide</button></span>
    <span class="translation-text">${app.escapeHtml(t.text)}</span>
  </div>`;
}

export function wireTranslations(root = document) {
  root.querySelectorAll('.translate-btn').forEach((btn) => {
    if (btn.dataset.wired) return;
    btn.dataset.wired = '1';
    btn.addEventListener('click', (e) => { e.stopPropagation(); translate(btn.dataset.msg, prefs.get('translateTo')); });
  });
  root.querySelectorAll('.translation-hide').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); translations.delete(btn.dataset.msg); app.renderMessages(); });
  });
  root.querySelectorAll('.translation-change').forEach((btn) => {
    btn.addEventListener('click', (e) => { e.stopPropagation(); pickLanguage((code) => translate(btn.dataset.msg, code)); });
  });
}

async function translate(msgId, lang) {
  const text = app.state.plaintext.get(msgId);
  if (typeof text !== 'string') return;
  translations.set(msgId, { loading: true });
  app.renderMessages();
  try {
    const { translation } = await app.api('/api/ai/translate', { method: 'POST', body: JSON.stringify({ text, to: lang }) });
    translations.set(msgId, { text: translation, lang });
  } catch (err) {
    translations.set(msgId, { error: err.message });
  }
  if ((app.state.messages.get(app.state.activeId) || []).some((m) => m.id === msgId)) app.renderMessages();
}

export function pickLanguage(onPick) {
  const current = prefs.get('translateTo');
  const { box, close } = openModal(`
    <h3>Translate to</h3>
    <div class="lang-grid">
      ${LANGUAGES.map(([code, name]) => `
        <button type="button" class="lang-option${code === current ? ' selected' : ''}" data-code="${code}">${name}</button>`).join('')}
    </div>
    <div class="modal-actions"><button type="button" class="btn-secondary" data-close>Cancel</button></div>`);
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelectorAll('.lang-option').forEach((btn) => {
    btn.addEventListener('click', () => {
      prefs.set('translateTo', btn.dataset.code);
      close();
      onPick?.(btn.dataset.code);
    });
  });
}

// ── Smart replies ───────────────────────────────────────────

let aiReplies = null;          // { conversationId, items: [...] } once fetched
let aiRepliesFor = null;       // last message id the suggestions answer

/** Chips for the composer bar (empty composer only). */
export function smartReplyChips(bar, fillComposer) {
  const convo = app.state.conversations.get(app.state.activeId);
  const list = app.state.messages.get(app.state.activeId) || [];
  const last = list[list.length - 1];
  if (!convo || !last) return;

  if (aiReplies && aiReplies.conversationId === convo.id && aiRepliesFor === last.id) {
    for (const r of aiReplies.items) {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'suggest-chip ai';
      chip.innerHTML = `${icon('sparkle')}<span></span>`;
      chip.querySelector('span').textContent = r;
      chip.addEventListener('click', () => fillComposer(r));
      bar.appendChild(chip);
    }
    return;
  }

  const chip = document.createElement('button');
  chip.type = 'button';
  chip.className = 'suggest-chip ai ai-ask';
  chip.innerHTML = `${icon('sparkle')}<span>Smart replies</span>`;
  chip.title = 'Ask the AI for 3 replies (sends the last messages to your server\'s AI)';
  chip.addEventListener('click', async () => {
    chip.disabled = true;
    chip.querySelector('span').textContent = 'Thinking…';
    try {
      const lines = recentLines(convo, 15);
      const { replies } = await app.api('/api/ai/replies', {
        method: 'POST', body: JSON.stringify({ lines, me: app.state.me.displayName }),
      });
      aiReplies = { conversationId: convo.id, items: replies };
      aiRepliesFor = last.id;
      app.refreshComposerSuggestions();
    } catch (err) {
      app.toast(err.message, true);
      chip.disabled = false;
      chip.querySelector('span').textContent = 'Smart replies';
    }
  });
  bar.appendChild(chip);
}
