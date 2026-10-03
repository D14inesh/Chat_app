// Two more live games over the same game-signal relay as Ludo/Chess:
//   Tic-tac-toe   move {type:'ttt', cell}        / {type:'ttt-reset'}
//   Snake & Ladder move {type:'sl-roll', value}  / {type:'sl-reset'}
// The inviter (host) goes first. Both sides apply the same moves, so the
// boards never need to be sent whole — same approach as Ludo.

import { app } from './core.js';

// ── Tic-tac-toe ─────────────────────────────────────────────

const LINES = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]];

function tttFresh(starter = 'X') {
  return { board: Array(9).fill(null), turn: starter, starter, winner: null, line: null, score: { X: 0, O: 0, draw: 0 } };
}

const mySymbol = () => (app.state.liveGame.role === 'host' ? 'X' : 'O');

export function startTicTacToe() {
  app.state.liveGame.ttt = tttFresh('X');
  app.openLiveGameModal('❌⭕ Tic-tac-toe', 'ttt-board', 'ttt-controls', 'ttt-board');
  renderTicTacToe();
}

function tttApply(cell) {
  const t = app.state.liveGame?.ttt;
  if (!t || t.winner || t.board[cell]) return;
  t.board[cell] = t.turn;
  const line = LINES.find(([a, b, c]) => t.board[a] && t.board[a] === t.board[b] && t.board[a] === t.board[c]);
  if (line) { t.winner = t.turn; t.line = line; t.score[t.turn]++; }
  else if (t.board.every(Boolean)) { t.winner = 'draw'; t.score.draw++; }
  else t.turn = t.turn === 'X' ? 'O' : 'X';
  renderTicTacToe();
}

function tttReset() {
  const t = app.state.liveGame?.ttt;
  if (!t) return;
  const score = t.score;
  const next = tttFresh(t.starter === 'X' ? 'O' : 'X');   // take turns going first
  next.score = score;
  app.state.liveGame.ttt = next;
  renderTicTacToe();
}

export function applyTicTacToeMove(move) {
  if (move.type === 'ttt') tttApply(move.cell);
  else if (move.type === 'ttt-reset') tttReset();
}

function renderTicTacToe() {
  const g = app.state.liveGame;
  const board = app.$('ttt-board');
  const controls = app.$('ttt-controls');
  if (!g?.ttt || !board) return;
  const t = g.ttt;
  const me = mySymbol();
  const myTurn = !t.winner && t.turn === me;

  board.innerHTML = t.board.map((v, i) => `
    <button type="button" class="ttt-cell ${v ? `is-${v}` : ''} ${t.line?.includes(i) ? 'win' : ''}"
            data-cell="${i}" ${myTurn && !v ? '' : 'disabled'}>${v === 'X' ? '✕' : v === 'O' ? '◯' : ''}</button>`).join('');
  board.querySelectorAll('.ttt-cell:not([disabled])').forEach((btn) => {
    btn.addEventListener('click', () => {
      const cell = Number(btn.dataset.cell);
      tttApply(cell);
      app.sendGameSignal({ kind: 'move', move: { type: 'ttt', cell } });
    });
  });

  const peer = app.escapeHtml(g.peerName);
  const status = t.winner === 'draw' ? "🤝 It's a draw"
    : t.winner ? (t.winner === me ? '🎉 You won!' : `${peer} won`)
    : myTurn ? `Your turn — you're ${me === 'X' ? '✕' : '◯'}` : `Waiting for ${peer}…`;
  controls.innerHTML = `
    <div class="ludo-status${t.winner ? ' solved-status' : ''}">${status}</div>
    <div class="ttt-score">
      <span>You <b>${t.score[me]}</b></span><span>Draws <b>${t.score.draw}</b></span>
      <span>${peer} <b>${t.score[me === 'X' ? 'O' : 'X']}</b></span>
    </div>
    ${t.winner ? '<button type="button" class="btn-primary" id="ttt-again">Play again</button>' : ''}`;
  app.$('ttt-again')?.addEventListener('click', () => {
    tttReset();
    app.sendGameSignal({ kind: 'move', move: { type: 'ttt-reset' } });
  });
}

// ── Snake & Ladder ──────────────────────────────────────────

export const SNAKES = { 16: 6, 47: 26, 49: 11, 56: 53, 62: 19, 64: 60, 87: 24, 93: 73, 95: 75, 98: 78 };
export const LADDERS = { 1: 38, 4: 14, 9: 31, 21: 42, 28: 84, 36: 44, 51: 67, 71: 91, 80: 100 };

function slFresh() {
  return { pos: { host: 0, guest: 0 }, turn: 'host', winner: null, last: null };
}

export function startSnakes() {
  app.state.liveGame.sl = slFresh();
  app.openLiveGameModal('🐍🪜 Snake & Ladder', 'sl-board', 'sl-controls', 'sl-board');
  renderSnakes();
}

/** Same pure step on both sides: move, then snake/ladder, 6 = roll again. */
export function slStep(sl, value) {
  if (sl.winner) return sl;
  const who = sl.turn;
  const from = sl.pos[who];
  let to = from + value;
  let note = '';
  if (to > 100) { to = from; note = 'needs an exact roll to finish'; }
  else if (SNAKES[to]) { note = `🐍 bitten at ${to}, down to ${SNAKES[to]}`; to = SNAKES[to]; }
  else if (LADDERS[to]) { note = `🪜 climbed from ${to} to ${LADDERS[to]}`; to = LADDERS[to]; }
  sl.pos[who] = to;
  sl.last = { who, value, from, to, note };
  if (to === 100) sl.winner = who;
  else if (value !== 6) sl.turn = who === 'host' ? 'guest' : 'host';
  return sl;
}

export function applySnakesMove(move) {
  const g = app.state.liveGame;
  if (!g?.sl) return;
  if (move.type === 'sl-roll') { slStep(g.sl, move.value); renderSnakes(); }
  else if (move.type === 'sl-reset') { g.sl = slFresh(); renderSnakes(); }
}

function cellNumber(r, c) {
  const fromBottom = 9 - r;
  return fromBottom * 10 + (fromBottom % 2 === 0 ? c + 1 : 10 - c);
}

function renderSnakes() {
  const g = app.state.liveGame;
  const board = app.$('sl-board');
  const controls = app.$('sl-controls');
  if (!g?.sl || !board) return;
  const sl = g.sl;
  const me = g.role;
  const myTurn = !sl.winner && sl.turn === me;

  let html = '';
  for (let r = 0; r < 10; r++) {
    for (let c = 0; c < 10; c++) {
      const n = cellNumber(r, c);
      const mark = SNAKES[n] ? `<span class="sl-mark snake" title="Snake to ${SNAKES[n]}">🐍<i>${SNAKES[n]}</i></span>`
        : LADDERS[n] ? `<span class="sl-mark ladder" title="Ladder to ${LADDERS[n]}">🪜<i>${LADDERS[n]}</i></span>` : '';
      const tokens = ['host', 'guest'].filter((p) => sl.pos[p] === n)
        .map((p) => `<span class="sl-token ${p}${p === me ? ' me' : ''}"></span>`).join('');
      html += `<div class="sl-cell ${(r + c) % 2 ? 'alt' : ''} ${n === 100 ? 'goal' : ''}"><span class="sl-n">${n}</span>${mark}${tokens}</div>`;
    }
  }
  board.innerHTML = html;

  const peer = app.escapeHtml(g.peerName);
  const name = (p) => (p === me ? 'You' : peer);
  const offBoard = ['host', 'guest'].filter((p) => sl.pos[p] === 0).map((p) => `<span class="sl-token ${p}${p === me ? ' me' : ''}"></span> ${name(p)}`);
  const last = sl.last ? `${name(sl.last.who)} rolled ${sl.last.value} → ${sl.last.to || 'start'}${sl.last.note ? ` · ${sl.last.note}` : ''}` : 'Roll a 1–6 to start moving. A 6 gives another turn.';
  const status = sl.winner ? (sl.winner === me ? '🎉 You won!' : `${peer} won`)
    : myTurn ? 'Your turn — roll the dice' : `Waiting for ${peer}…`;

  controls.innerHTML = `
    <div class="ludo-status${sl.winner ? ' solved-status' : ''}">${status}</div>
    <div class="sl-last">${last}</div>
    ${offBoard.length ? `<div class="sl-start">At start: ${offBoard.join(' · ')}</div>` : ''}
    <div class="sl-actions">
      ${sl.winner
        ? '<button type="button" class="btn-primary" id="sl-again">Play again</button>'
        : `<button type="button" class="btn-primary sl-roll" id="sl-roll" ${myTurn ? '' : 'disabled'}>🎲 Roll</button>`}
    </div>`;
  app.$('sl-roll')?.addEventListener('click', () => {
    const value = 1 + Math.floor(Math.random() * 6);
    slStep(sl, value);
    app.sendGameSignal({ kind: 'move', move: { type: 'sl-roll', value } });
    renderSnakes();
  });
  app.$('sl-again')?.addEventListener('click', () => {
    g.sl = slFresh();
    app.sendGameSignal({ kind: 'move', move: { type: 'sl-reset' } });
    renderSnakes();
  });
}
