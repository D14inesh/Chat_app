// Shared plumbing for the feature modules in this folder. app.js hands over
// the pieces they need once at boot (bindFeatures), so the modules never
// reach into app.js internals any other way.

export const app = {};

export function bindFeatures(ctx) {
  Object.assign(app, ctx);
}

// ── Small per-device preferences (never required for anything to work) ──
const PREFS_KEY = 'veyon.prefs';
const PREF_DEFAULTS = { autoTranscribe: false, effects: true, translateTo: 'en' };

export const prefs = {
  get(name) {
    try {
      const all = JSON.parse(localStorage.getItem(PREFS_KEY) || '{}');
      return name in all ? all[name] : PREF_DEFAULTS[name];
    } catch { return PREF_DEFAULTS[name]; }
  },
  set(name, value) {
    try {
      const all = JSON.parse(localStorage.getItem(PREFS_KEY) || '{}');
      all[name] = value;
      localStorage.setItem(PREFS_KEY, JSON.stringify(all));
    } catch { /* storage blocked — the setting just won't stick */ }
  },
};

/** Opens a standard modal card. Returns { box, card, close }. */
export function openModal(innerHtml, { cardClass = '', onClose } = {}) {
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `<div class="modal-card ${cardClass}">${innerHtml}</div>`;
  document.body.appendChild(box);
  const close = () => { box.remove(); onClose?.(); };
  // Escape is handled app-wide (app.js closes the top-most dialog).
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  return { box, card: box.firstElementChild, close };
}

/** Display name for someone in a conversation ("You" for me). */
export function nameOf(convo, userId) {
  if (userId === app.state.me?.id) return 'You';
  if (convo?.kind === 'group') return app.senderInfo(convo, userId).displayName;
  return convo?.peer?.id === userId ? convo.peer.displayName : 'Someone';
}

export function svg(paths, extra = '') {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round" ${extra}>${paths}</svg>`;
}

export const ICONS = {
  poll: '<line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/>',
  pin: '<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/>',
  timer: '<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2"/><path d="M9 2h6"/>',
  once: '<circle cx="12" cy="12" r="10"/><path d="M11 8h1.5v8"/>',
  sparkle: '<path d="M12 3l1.8 4.7L18.5 9.5l-4.7 1.8L12 16l-1.8-4.7L5.5 9.5l4.7-1.8z"/><path d="M19 15l.8 2.2 2.2.8-2.2.8L19 21l-.8-2.2-2.2-.8 2.2-.8z"/>',
  translate: '<path d="m5 8 6 6"/><path d="m4 14 6-6 2-3"/><path d="M2 5h12"/><path d="M7 2h1"/><path d="m22 22-5-10-5 10"/><path d="M14 18h6"/>',
  export: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>',
  broadcast: '<path d="M4.9 19.1C1 15.2 1 8.8 4.9 4.9"/><path d="M7.8 16.2c-2.3-2.3-2.3-6.1 0-8.5"/><circle cx="12" cy="12" r="2"/><path d="M16.2 7.8c2.3 2.3 2.3 6.1 0 8.5"/><path d="M19.1 4.9C23 8.8 23 15.1 19.1 19"/>',
  quick: '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/>',
  shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/>',
  briefcase: '<rect x="2" y="7" width="20" height="14" rx="2"/><path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
  close: '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
  plus: '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
  trash: '<path d="M3 6h18"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
  send: '<path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4 20-7z"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  device: '<rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>',
  phone: '<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',
  qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3M21 14v7h-7"/>',
  map: '<path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z"/><circle cx="12" cy="10" r="3"/>',
  lock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  mail: '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 6-10 7L2 6"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  info: '<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
};

export function icon(name, extra = '') {
  return svg(ICONS[name] || '', extra);
}

/** Readable relative time for lists ("just now", "5 min ago", "Yesterday 4:10 pm"). */
export function whenText(iso) {
  const d = new Date(iso);
  const diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 60) return 'just now';
  if (diff < 3600) return `${Math.floor(diff / 60)} min ago`;
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const today = new Date();
  if (d.toDateString() === today.toDateString()) return `Today ${time}`;
  const y = new Date(today); y.setDate(today.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return `Yesterday ${time}`;
  return `${d.toLocaleDateString([], { day: 'numeric', month: 'short', year: d.getFullYear() === today.getFullYear() ? undefined : 'numeric' })} ${time}`;
}
