// Sidebar pages, like WhatsApp Web: screens (Settings, Profile, Theme,
// Starred, Security…) slide in over the chat list with a ← back arrow,
// instead of opening as a box in the middle. Small dialogs (confirmations,
// PIN entry) stay centred.
//
// It works on the dialogs every feature already makes: a dialog whose card
// is a "screen" — `data-panel` on the card, a `.feature-card`, or a
// `.feature-hero` header — is turned into a sidebar page as it appears.

import { app, icon, openModal } from './core.js';

const BACK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5"/><path d="m12 19-7-7 7-7"/></svg>';

const isScreen = (card) => card && (card.hasAttribute('data-panel') || card.classList.contains('feature-card')
  || card.querySelector(':scope > .feature-hero'));

/** Where a page sits: over the chat list (default), on the right side of
 *  the open chat (data-panel="right", like WhatsApp's contact info), or
 *  over the whole chat area (data-panel="main", e.g. games). */
function place(box) {
  const where = box.dataset.where;
  const target = where === 'sidebar' ? document.querySelector('.sidebar')
    : document.querySelector('.chat-pane:not(.hidden)') || document.querySelector('.no-chat');
  if (!target || window.matchMedia('(max-width: 820px)').matches) {
    box.style.left = box.style.top = '0';
    box.style.width = box.style.height = '';
    return;
  }
  const r = target.getBoundingClientRect();
  const width = where === 'right' ? Math.min(420, Math.max(320, r.width * 0.42)) : r.width;
  const left = where === 'right' ? r.right - width : r.left;
  Object.assign(box.style, { left: `${left}px`, top: `${r.top}px`, width: `${width}px`, height: `${r.height}px` });
}

function toPanel(box) {
  if (box.classList.contains('as-panel')) return;
  const card = box.firstElementChild;
  const where = ['right', 'main'].includes(card.dataset.panel) ? card.dataset.panel : 'sidebar';
  box.dataset.where = where;
  box.classList.add('as-panel', `panel-${where}`);
  card.classList.add('panel-card');
  // Title: the screen's own heading moves into the page header.
  const heading = card.querySelector(':scope > h3, :scope > h2, :scope > .feature-hero h3, :scope > .ai-chat-head h3');
  const title = card.dataset.panelTitle || heading?.textContent.trim() || '';
  if (heading && !card.dataset.keepHeading) heading.classList.add('panel-hidden-title');
  const head = document.createElement('div');
  head.className = 'panel-head';
  // Pages beside the chat close with ×, pages over the chat list go back with ←.
  const CLOSE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>';
  head.innerHTML = `<button type="button" class="icon-btn panel-back" aria-label="${where === 'sidebar' ? 'Back' : 'Close'}">${where === 'sidebar' ? BACK : CLOSE}</button><span class="panel-title"></span>`;
  head.querySelector('.panel-title').textContent = title;
  card.prepend(head);
  head.querySelector('.panel-back').addEventListener('click', () => {
    // Closes the way the screen itself closes (a click outside it)…
    box.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    // …or, for a screen that ignores that, by removing it.
    setTimeout(() => box.isConnected && box.remove(), 60);
  });
  place(box);
}

export function initPanels() {
  new MutationObserver((records) => {
    for (const r of records) {
      for (const node of r.addedNodes) {
        if (node.nodeType === 1 && node.classList.contains('modal-backdrop') && isScreen(node.firstElementChild)) toPanel(node);
      }
    }
  }).observe(document.body, { childList: true });
  window.addEventListener('resize', () => document.querySelectorAll('.modal-backdrop.as-panel').forEach(place));
}

// ── Settings ─────────────────────────────────────────────────
const ROW_ICONS = {
  profile: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  account: '<circle cx="7.5" cy="15.5" r="5.5"/><path d="m21 2-9.6 9.6"/><path d="m15.5 7.5 3 3L22 7l-3-3"/>',
  privacy: '<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  chats: '<circle cx="13.5" cy="6.5" r=".5" fill="currentColor"/><circle cx="17.5" cy="10.5" r=".5" fill="currentColor"/><circle cx="8.5" cy="7.5" r=".5" fill="currentColor"/><circle cx="6.5" cy="12.5" r=".5" fill="currentColor"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.965 6.012 17.461 2 12 2z"/>',
  bell: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
  backup: '<path d="M20 16.6A5 5 0 0 0 18 7h-1.3A8 8 0 1 0 4 15.3"/><path d="M12 12v9"/><path d="m8 16 4-4 4 4"/>',
  storage: '<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14a9 3 0 0 0 18 0V5"/><path d="M3 12a9 3 0 0 0 18 0"/>',
  mic: '<path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" x2="12" y1="19" y2="22"/>',
  logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>',
  shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10"/>',
  devices: '<rect width="14" height="20" x="5" y="2" rx="2"/><path d="M12 18h.01"/>',
  key: '<path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4"/><path d="m21 2-9.6 9.6"/><circle cx="7.5" cy="15.5" r="5.5"/>',
  block: '<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>',
  lock: '<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  chatlock: '<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/><rect x="9" y="11" width="6" height="5" rx="1"/><path d="M10 11V9.5a2 2 0 0 1 4 0V11"/>',
};
const rowIcon = (k) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ROW_ICONS[k]}</svg>`;

function settingsRows(rows) {
  return `<div class="settings-rows">${rows.map((r) => `
    <button type="button" class="settings-row ${r.danger ? 'danger' : ''}" data-go="${r.go}">
      <span class="settings-row-icon">${rowIcon(r.icon)}</span>
      <span class="settings-row-text"><span class="settings-row-title">${r.title}</span>${r.sub ? `<span class="settings-row-sub">${r.sub}</span>` : ''}</span>
    </button>`).join('')}</div>`;
}

function wireRows(box, actions) {
  box.querySelectorAll('[data-go]').forEach((btn) => btn.addEventListener('click', () => actions[btn.dataset.go]?.()));
}

/** Settings — one list, each row opens its page (like WhatsApp). */
export function openSettings() {
  const me = app.state.me;
  const { box, close } = openModal(`
    <div class="settings-me" data-go="profile">
      <div class="avatar lg" style="background:${app.escapeAttr(me.avatarColor)}">${app.avatarInner(me)}</div>
      <div class="settings-me-text">
        <div class="settings-me-name">${app.escapeHtml(me.displayName)}</div>
        <div class="settings-me-sub">${app.escapeHtml(me.about || 'Available')}</div>
      </div>
    </div>
    ${settingsRows([
      { go: 'profile', icon: 'profile', title: 'Profile', sub: 'Name, profile photo, about, business' },
      { go: 'account', icon: 'account', title: 'Account', sub: 'Security, linked devices, recovery key' },
      { go: 'privacy', icon: 'privacy', title: 'Privacy', sub: 'Blocked contacts, app lock, chat lock' },
      { go: 'chats', icon: 'chats', title: 'Chats', sub: 'Theme, light / dark, layout' },
      { go: 'notifications', icon: 'bell', title: 'Notifications & chat features', sub: 'Messages, calls, voice-to-text, effects' },
      { go: 'storage', icon: 'storage', title: 'Storage and data', sub: 'What this device keeps' },
      { go: 'backup', icon: 'backup', title: 'Chat backup', sub: 'Password-locked backup of your chats' },
      { go: 'voice', icon: 'mic', title: 'Voice commands', sub: 'Say “Hey ARM” — turn on or off' },
      { go: 'logout', icon: 'logout', title: 'Log out', danger: true },
    ])}`, { cardClass: 'settings-card', onClose: () => {} });
  box.firstElementChild.setAttribute('data-panel', '');
  box.firstElementChild.dataset.panelTitle = 'Settings';
  toPanelNow(box);
  const go = (action) => () => app.sidebarAction(action);
  wireRows(box, {
    profile: go('profile'),
    account: openAccount,
    privacy: openPrivacy,
    chats: go('appearance'),
    notifications: go('chat-features'),
    storage: go('storage'),
    backup: go('chat-backup'),
    voice: () => { app.sidebarAction('voice-commands'); },
    logout: () => { close(); document.getElementById('logout-btn')?.click(); },
  });
}

function toPanelNow(box) {
  if (!box.classList.contains('as-panel')) toPanel(box);
}

function subPage(title, rows, actions) {
  const { box } = openModal(settingsRows(rows), { cardClass: 'settings-card' });
  box.firstElementChild.setAttribute('data-panel', '');
  box.firstElementChild.dataset.panelTitle = title;
  toPanelNow(box);
  wireRows(box, actions);
}

function openAccount() {
  const go = (a) => () => app.sidebarAction(a);
  subPage('Account', [
    { go: 'security', icon: 'shield', title: 'Security & logins', sub: 'Every sign-in, log out other devices' },
    { go: 'devices', icon: 'devices', title: 'Linked devices', sub: 'Phones and browsers using this account' },
    { go: 'recovery', icon: 'key', title: 'Recovery key', sub: 'Get back in if you forget your password' },
  ], { security: go('security'), devices: go('linked-devices'), recovery: go('recovery-key') });
}

function openPrivacy() {
  const go = (a) => () => app.sidebarAction(a);
  subPage('Privacy', [
    { go: 'blocked', icon: 'block', title: 'Blocked contacts' },
    { go: 'applock', icon: 'lock', title: 'App lock', sub: 'PIN, pattern or fingerprint for this device' },
    { go: 'chatlock', icon: 'chatlock', title: 'Chat lock', sub: 'PIN for locked chats and private chats' },
  ], { blocked: go('blocked-users'), applock: go('app-lock'), chatlock: go('chat-lock') });
}
