// Export a chat — the whole history, decrypted here in the browser, saved
// as a .txt file or printed / saved as PDF. Nothing goes to the server.

import { app, icon, nameOf, openModal } from './core.js';

function lineText(m, plain) {
  if (m.deleted) return 'This message was deleted';
  if (plain == null) return '[could not decrypt]';
  switch (m.kind) {
    case 'file':
      if (m.viewOnce || plain.viewOnce) return '[view-once media]';
      return `[${plain.gif ? 'GIF' : plain.sticker ? 'Sticker' : 'File'}: ${plain.name || 'attachment'}]`;
    case 'voice': return '[Voice message]';
    case 'location': return `[Location: https://www.openstreetmap.org/?mlat=${plain.lat}&mlon=${plain.lng}]`;
    case 'contact': return `[Contact: ${plain.name} ${plain.phone}]`;
    case 'poll': return `[Poll] ${plain.question} — ${(plain.options || []).map((o, i) => `${i + 1}) ${o}`).join('  ')}`;
    default: return typeof plain === 'string' ? plain : '';
  }
}

function stamp(iso) {
  const d = new Date(iso);
  const date = d.toLocaleDateString([], { day: '2-digit', month: '2-digit', year: 'numeric' });
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return `${date}, ${time}`;
}

/** Loads the full history of a chat (all pages) and decrypts it. */
async function fullHistory(convo, onProgress) {
  const key = await app.keyFor(convo);
  let all = [];
  let before = null;
  for (let page = 0; page < 400; page++) {
    const qs = before ? `?before=${encodeURIComponent(before)}` : '';
    const { messages } = await app.api(`/api/conversations/${convo.id}/messages${qs}`);
    if (!messages.length) break;
    for (const m of messages) {
      if (!app.state.plaintext.has(m.id)) {
        try { app.state.plaintext.set(m.id, await app.decryptBody(key, m)); } catch { app.state.plaintext.set(m.id, null); }
      }
    }
    all = [...messages, ...all];
    onProgress(all.length);
    before = messages[0].createdAt;
    if (messages.length < 50) break;
  }
  return all;
}

export function openExportChat() {
  const convo = app.state.conversations.get(app.state.activeId);
  if (!convo) return;
  const title = convo.kind === 'group' ? convo.title : convo.peer.displayName;

  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('export')}</div>
      <h3>Export chat</h3>
      <p>Save your whole conversation with <b>${app.escapeHtml(title)}</b>. It's decrypted
         here on your device — the file is readable by anyone you share it with.</p>
    </div>
    <div class="choice-list">
      <button type="button" class="choice-row as-action" data-format="txt">
        <span class="choice-emoji">📄</span>
        <span class="choice-text"><span class="choice-label">Text file (.txt)</span>
          <span class="choice-sub">Works everywhere — like WhatsApp's export</span></span>
      </button>
      <button type="button" class="choice-row as-action" data-format="pdf">
        <span class="choice-emoji">🖨️</span>
        <span class="choice-text"><span class="choice-label">PDF / Print</span>
          <span class="choice-sub">Opens a print view — choose "Save as PDF"</span></span>
      </button>
    </div>
    <div class="export-progress hidden" id="export-progress"></div>
    <div class="modal-actions"><button type="button" class="btn-secondary" data-close>Close</button></div>`,
  { cardClass: 'feature-card' });

  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelectorAll('[data-format]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const progress = box.querySelector('#export-progress');
      box.querySelectorAll('[data-format]').forEach((b) => { b.disabled = true; });
      progress.classList.remove('hidden');
      progress.textContent = 'Loading messages…';
      try {
        if (convo.kind === 'group' && !app.state.groupMembers.has(convo.id)) {
          const { members } = await app.api(`/api/conversations/${convo.id}/members`);
          app.state.groupMembers.set(convo.id, members);
        }
        const messages = await fullHistory(convo, (n) => { progress.textContent = `Decrypting… ${n} messages`; });
        if (btn.dataset.format === 'txt') downloadTxt(convo, title, messages);
        else printPdf(convo, title, messages);
        progress.textContent = `Done — ${messages.length} messages exported.`;
      } catch (err) {
        progress.textContent = `Export failed: ${err.message}`;
      } finally {
        box.querySelectorAll('[data-format]').forEach((b) => { b.disabled = false; });
      }
    });
  });
}

function senderName(convo, m) {
  if (m.senderId === app.state.me.id) return app.state.me.displayName;
  return nameOf(convo, m.senderId);
}

function downloadTxt(convo, title, messages) {
  const lines = [
    `Chat with ${title} — exported ${stamp(new Date().toISOString())}`,
    'Messages were end-to-end encrypted and decrypted on this device for this export.',
    '',
    ...messages.map((m) => `[${stamp(m.createdAt)}] ${senderName(convo, m)}: ${lineText(m, app.state.plaintext.get(m.id))}`),
  ];
  const blob = new Blob([lines.join('\r\n')], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `Chat with ${title.replace(/[\\/:*?"<>|]/g, '_')}.txt`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

function printPdf(convo, title, messages) {
  const esc = app.escapeHtml;
  let lastDay = '';
  const rows = messages.map((m) => {
    const d = new Date(m.createdAt);
    const day = d.toDateString();
    const sep = day !== lastDay ? `<div class="day">${esc(d.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }))}</div>` : '';
    lastDay = day;
    const mine = m.senderId === app.state.me.id;
    return `${sep}<div class="msg ${mine ? 'me' : ''}">
      <div class="who">${esc(senderName(convo, m))} <span>${esc(d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }))}</span></div>
      <div class="txt">${esc(lineText(m, app.state.plaintext.get(m.id)))}</div></div>`;
  }).join('');

  const win = window.open('', '_blank');
  if (!win) { app.toast('Allow pop-ups for this site to print the chat.', true); return; }
  win.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Chat with ${esc(title)}</title>
    <style>
      body{font:13px/1.45 'Segoe UI',Roboto,Arial,sans-serif;color:#1d2433;margin:32px;}
      h1{font-size:20px;margin:0 0 4px} .sub{color:#6b7488;margin-bottom:22px;font-size:12px}
      .day{text-align:center;color:#6b7488;font-size:11px;margin:18px 0 8px;text-transform:uppercase;letter-spacing:.06em}
      .msg{max-width:72%;margin:6px 0;padding:8px 12px;border-radius:12px;background:#eef1f7;page-break-inside:avoid}
      .msg.me{margin-left:auto;background:#dbe7ff}
      .who{font-weight:700;font-size:12px;margin-bottom:2px} .who span{font-weight:400;color:#6b7488;margin-left:6px}
      .txt{white-space:pre-wrap;word-wrap:break-word}
    </style></head><body>
    <h1>Chat with ${esc(title)}</h1>
    <div class="sub">${messages.length} messages · exported ${esc(stamp(new Date().toISOString()))} · decrypted on this device</div>
    ${rows}
    <script>window.onload=()=>setTimeout(()=>window.print(),300)<\/script></body></html>`);
  win.document.close();
}
