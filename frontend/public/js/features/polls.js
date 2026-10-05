// Polls — the question and options are encrypted like any message; only
// the votes (option numbers) travel in the clear, via the poll-vote frame.

import { app, icon, nameOf, openModal } from './core.js';

const MAX_OPTIONS = 12;

export function pollPreview(plain) {
  return `📊 ${typeof plain === 'object' && plain?.question ? plain.question : 'Poll'}`;
}

function tally(m, optionCount) {
  const counts = new Array(optionCount).fill(0);
  const voters = new Array(optionCount).fill(0).map(() => []);
  for (const v of m.votes || []) {
    for (const c of v.choices) {
      if (c >= 0 && c < optionCount) { counts[c]++; voters[c].push(v.userId); }
    }
  }
  return { counts, voters, total: (m.votes || []).length };
}

const isClosed = (m) => !!m.pollClosesAt && new Date(m.pollClosesAt) <= new Date();

function closesText(m) {
  if (!m.pollClosesAt) return '';
  const ms = new Date(m.pollClosesAt) - Date.now();
  if (ms <= 0) return 'Closed · final results';
  const min = Math.round(ms / 60000);
  if (min < 60) return `Closes in ${Math.max(1, min)} min`;
  const h = Math.round(min / 60);
  if (h < 48) return `Closes in ${h} h`;
  return `Closes ${new Date(m.pollClosesAt).toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' })}`;
}

// Re-draw the open chat when a poll in it reaches its closing time.
const closeTimers = new Map();
function scheduleClose(m) {
  if (!m.pollClosesAt || isClosed(m) || closeTimers.has(m.id)) return;
  const ms = new Date(m.pollClosesAt) - Date.now();
  if (ms > 2 ** 31 - 1) return;
  closeTimers.set(m.id, setTimeout(() => { closeTimers.delete(m.id); app.renderMessages(); }, ms + 500));
}

function canClose(m) {
  if (isClosed(m) || m.pending) return false;
  const convo = app.state.conversations.get(app.state.activeId);
  return m.senderId === app.state.me.id || (convo?.kind === 'group' && ['owner', 'admin'].includes(convo.myRole));
}

function myChoices(m) {
  return (m.votes || []).find((v) => v.userId === app.state.me.id)?.choices || [];
}

/** The poll card inside a bubble. */
export function pollBody(m, plain) {
  const { escapeHtml, escapeAttr } = app;
  if (!plain || typeof plain !== 'object' || !Array.isArray(plain.options)) {
    return '<div class="text" style="opacity:.6;font-style:italic">Poll could not be read</div>';
  }
  const { counts, total } = tally(m, plain.options.length);
  const mine = new Set(myChoices(m));
  const max = Math.max(1, ...counts);
  const people = total === 1 ? '1 vote' : `${total} votes`;
  const closed = isClosed(m);
  scheduleClose(m);

  return `
    <div class="poll-card ${closed ? 'closed' : ''}" data-msg="${escapeAttr(m.id)}">
      <div class="poll-head">${icon('poll')}<span>${closed ? 'Poll · closed' : 'Poll'}</span>
        ${m.pollClosesAt ? `<span class="poll-deadline ${closed ? 'done' : ''}">${icon('clock')} ${closesText(m)}</span>` : ''}</div>
      <div class="poll-question">${escapeHtml(plain.question)}</div>
      <div class="poll-hint">${plain.multi ? 'Select one or more' : 'Select one'}</div>
      <div class="poll-options">
        ${plain.options.map((opt, i) => {
          const pct = total ? Math.round((counts[i] / total) * 100) : 0;
          const leading = counts[i] > 0 && counts[i] === max;
          return `
            <button type="button" class="poll-option${mine.has(i) ? ' chosen' : ''}${leading ? ' leading' : ''}"
                    data-idx="${i}" ${m.pending || closed ? 'disabled' : ''}>
              <span class="poll-check ${plain.multi ? 'square' : ''}">${mine.has(i) ? icon('check') : ''}</span>
              <span class="poll-option-body">
                <span class="poll-option-row">
                  <span class="poll-option-text">${escapeHtml(opt)}</span>
                  <span class="poll-option-count">${counts[i] || ''}</span>
                </span>
                <span class="poll-bar"><i style="width:${pct}%"></i></span>
              </span>
            </button>`;
        }).join('')}
      </div>
      <div class="poll-footer-row">
        <button type="button" class="poll-footer" data-msg="${escapeAttr(m.id)}" ${total ? '' : 'disabled'}>
          ${total ? `${people} · View votes` : 'No votes yet'}
        </button>
        ${canClose(m) ? `<button type="button" class="poll-close-btn" data-msg="${escapeAttr(m.id)}">Close poll</button>` : ''}
      </div>
    </div>`;
}

export function wirePolls(root = document) {
  root.querySelectorAll('.poll-card').forEach((card) => {
    if (card.dataset.wired) return;
    card.dataset.wired = '1';
    const msgId = card.dataset.msg;
    card.querySelectorAll('.poll-option').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        vote(msgId, Number(btn.dataset.idx));
      });
    });
    card.querySelector('.poll-footer')?.addEventListener('click', (e) => {
      e.stopPropagation();
      showVoters(msgId);
    });
    card.querySelector('.poll-close-btn')?.addEventListener('click', (e) => {
      e.stopPropagation();
      if (!confirm('Close this poll now? No one can vote after that.')) return;
      app.sendSocket({ type: 'close-poll', conversationId: app.state.activeId, messageId: msgId });
    });
  });
}

function findMessage(msgId) {
  return (app.state.messages.get(app.state.activeId) || []).find((x) => x.id === msgId);
}

function vote(msgId, idx) {
  const m = findMessage(msgId);
  const plain = app.state.plaintext.get(msgId);
  if (!m || m.pending || !plain || isClosed(m)) return;
  const convo = app.state.conversations.get(app.state.activeId);
  if (!app.canSendTo(convo)) return;

  const current = new Set(myChoices(m));
  let next;
  if (plain.multi) {
    if (current.has(idx)) current.delete(idx); else current.add(idx);
    next = [...current].sort((a, b) => a - b);
  } else {
    next = current.has(idx) ? [] : [idx];   // tap your own choice again to take the vote back
  }

  // Optimistic — the server's poll-votes echo replaces it a moment later.
  const others = (m.votes || []).filter((v) => v.userId !== app.state.me.id);
  m.votes = next.length ? [...others, { userId: app.state.me.id, choices: next }] : others;
  app.renderMessages();
  app.sendSocket({ type: 'poll-vote', conversationId: app.state.activeId, messageId: msgId, choices: next });
}

function showVoters(msgId) {
  const m = findMessage(msgId);
  const plain = app.state.plaintext.get(msgId);
  if (!m || !plain) return;
  const convo = app.state.conversations.get(app.state.activeId);
  const { counts, voters } = tally(m, plain.options.length);
  const { escapeHtml } = app;

  const { box, close } = openModal(`
    <h3>Poll results</h3>
    <div class="poll-results-q">${escapeHtml(plain.question)}</div>
    <div class="poll-results">
      ${plain.options.map((opt, i) => `
        <div class="poll-result">
          <div class="poll-result-head">
            <span>${escapeHtml(opt)}</span>
            <span class="poll-result-n">${counts[i]} ${counts[i] === 1 ? 'vote' : 'votes'}</span>
          </div>
          ${voters[i].length
            ? `<div class="poll-result-people">${voters[i].map((u) =>
                `<span class="poll-person">${escapeHtml(nameOf(convo, u))}</span>`).join('')}</div>`
            : '<div class="poll-result-none">No votes</div>'}
        </div>`).join('')}
    </div>
    <div class="modal-actions"><button type="button" class="btn-primary" data-close>Done</button></div>`);
  box.querySelector('[data-close]').addEventListener('click', close);
}

export function onPollClosed(frame) {
  const m = app.state.messages.get(frame.conversationId)?.find((x) => x.id === frame.messageId);
  if (!m) return;
  m.pollClosesAt = frame.closesAt;
  if (frame.conversationId === app.state.activeId) app.renderMessages();
}

/** Live update from the server. */
export function onPollVotes(frame) {
  const list = app.state.messages.get(frame.conversationId);
  const m = list?.find((x) => x.id === frame.messageId);
  if (!m) return;
  m.votes = frame.votes;
  if (frame.conversationId === app.state.activeId) app.renderMessages();
}

export function openPollComposer() {
  if (!app.state.activeId) return;
  const convo = app.state.conversations.get(app.state.activeId);
  if (!app.canSendTo(convo)) return;

  const { box, close } = openModal(`
    <h3>${icon('poll', 'class="modal-title-icon"')} Create a poll</h3>
    <div class="field">
      <label>Question</label>
      <input type="text" id="poll-q" maxlength="200" placeholder="Ask something…" autocomplete="off">
    </div>
    <div class="field">
      <label>Options</label>
      <div class="poll-edit-options" id="poll-opts"></div>
      <button type="button" class="poll-add-option" id="poll-add">${icon('plus')} Add option</button>
    </div>
    <label class="toggle-row">
      <span>
        <span class="toggle-title">Allow multiple answers</span>
        <span class="toggle-sub">People can pick more than one option</span>
      </span>
      <input type="checkbox" id="poll-multi" class="switch">
    </label>
    <div class="field poll-deadline-field">
      <label for="poll-close">Close the poll</label>
      <select id="poll-close">
        <option value="">Never — stays open</option>
        <option value="3600">In 1 hour</option>
        <option value="86400">In 1 day</option>
        <option value="259200">In 3 days</option>
        <option value="604800">In 1 week</option>
        <option value="custom">On a date I pick…</option>
      </select>
      <input type="datetime-local" id="poll-close-at" class="hidden">
    </div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="poll-send" disabled>${icon('send')} Send poll</button>
    </div>`, { cardClass: 'poll-composer' });

  const optsEl = box.querySelector('#poll-opts');
  const sendBtn = box.querySelector('#poll-send');
  const qEl = box.querySelector('#poll-q');

  const values = () => [...optsEl.querySelectorAll('input')].map((i) => i.value.trim());
  const validate = () => {
    const filled = values().filter(Boolean);
    const unique = new Set(filled.map((v) => v.toLowerCase()));
    sendBtn.disabled = !qEl.value.trim() || filled.length < 2 || unique.size !== filled.length;
    box.querySelector('#poll-add').disabled = optsEl.children.length >= MAX_OPTIONS;
  };
  const addOption = (focus) => {
    if (optsEl.children.length >= MAX_OPTIONS) return;
    const row = document.createElement('div');
    row.className = 'poll-edit-option';
    row.innerHTML = `<span class="poll-edit-dot"></span>
      <input type="text" maxlength="100" placeholder="Option ${optsEl.children.length + 1}" autocomplete="off">
      <button type="button" class="icon-btn" aria-label="Remove option">${icon('close')}</button>`;
    const inputEl = row.querySelector('input');
    inputEl.addEventListener('input', validate);
    inputEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (row === optsEl.lastElementChild) addOption(true);
        else row.nextElementSibling?.querySelector('input')?.focus();
      }
    });
    row.querySelector('button').addEventListener('click', () => {
      if (optsEl.children.length <= 2) { inputEl.value = ''; validate(); return; }
      row.remove();
      optsEl.querySelectorAll('input').forEach((i, n) => { i.placeholder = `Option ${n + 1}`; });
      validate();
    });
    optsEl.appendChild(row);
    if (focus) inputEl.focus();
    validate();
  };

  addOption(false); addOption(false);
  qEl.addEventListener('input', validate);
  qEl.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); optsEl.querySelector('input')?.focus(); } });
  box.querySelector('#poll-add').addEventListener('click', () => addOption(true));
  box.querySelector('[data-close]').addEventListener('click', close);
  const closeSel = box.querySelector('#poll-close');
  const closeAt = box.querySelector('#poll-close-at');
  closeSel.addEventListener('change', () => {
    closeAt.classList.toggle('hidden', closeSel.value !== 'custom');
    if (closeSel.value === 'custom' && !closeAt.value) {
      const d = new Date(Date.now() + 86400000);
      d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
      closeAt.value = d.toISOString().slice(0, 16);
    }
  });
  sendBtn.addEventListener('click', () => {
    const options = values().filter(Boolean);
    let pollClosesAt;
    if (closeSel.value === 'custom') {
      const at = new Date(closeAt.value);
      if (!(at > new Date())) { app.toast('Pick a closing time in the future.', true); return; }
      pollClosesAt = at.toISOString();
    } else if (closeSel.value) {
      pollClosesAt = new Date(Date.now() + Number(closeSel.value) * 1000).toISOString();
    }
    app.sendJsonMessage('poll', {
      question: qEl.value.trim(),
      options,
      multi: box.querySelector('#poll-multi').checked,
    }, pollClosesAt ? { pollClosesAt } : {});
    close();
  });
  qEl.focus();
}
