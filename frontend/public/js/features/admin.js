// Admin panel (admins only: `python make_admin.py <username>` on the server)
// and announcements (everyone). Chats stay end-to-end encrypted — nothing
// here can read messages.

import { app, icon, openModal, whenText } from './core.js';

function bytes(n) {
  if (!n) return '0 KB';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  return `${(n / 1024 ** i).toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}

const num = (n) => Number(n || 0).toLocaleString();

// ── Announcements (everyone) ───────────────────────────────

export async function refreshAnnouncementBadge() {
  try {
    const { unseen } = await app.api('/api/announcements');
    const badge = app.$('announce-badge');
    badge.textContent = unseen;
    badge.classList.toggle('hidden', !unseen);
    app.$('sidebar-menu-btn')?.classList.toggle('has-dot', unseen > 0);
  } catch { /* offline */ }
}

/** Live: an admin just sent one. */
export function onAnnouncement(frame) {
  const a = frame.announcement;
  const el = document.createElement('div');
  el.className = 'login-alert announce-alert';
  el.innerHTML = `
    <div class="login-alert-icon announce-icon">${icon('megaphone')}</div>
    <div class="login-alert-body">
      <div class="login-alert-title">${app.escapeHtml(a.title)}</div>
      <div class="login-alert-sub">${app.escapeHtml(a.body.length > 90 ? a.body.slice(0, 90) + '…' : a.body)}</div>
    </div>
    <button type="button" class="btn-secondary login-alert-review">Open</button>
    <button type="button" class="icon-btn login-alert-close" aria-label="Dismiss">${icon('close')}</button>`;
  document.body.appendChild(el);
  requestAnimationFrame(() => el.classList.add('show'));
  const dismiss = () => { el.classList.remove('show'); setTimeout(() => el.remove(), 300); };
  el.querySelector('.login-alert-close').addEventListener('click', dismiss);
  el.querySelector('.login-alert-review').addEventListener('click', () => { dismiss(); openAnnouncements(); });
  setTimeout(dismiss, 20_000);
  refreshAnnouncementBadge();
}

function announcementHtml(a, { admin = false } = {}) {
  return `
    <div class="announce-item" data-id="${a.id}">
      <div class="announce-item-head">
        <div class="announce-item-title">${app.escapeHtml(a.title)}</div>
        <div class="announce-item-when">${whenText(a.createdAt)}</div>
        ${admin ? `<button type="button" class="icon-btn announce-del" title="Delete">${icon('trash')}</button>` : ''}
      </div>
      <div class="announce-item-body">${app.linkify(app.escapeHtml(a.body))}</div>
    </div>`;
}

export async function openAnnouncements() {
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('megaphone')}</div>
      <h3>Announcements</h3>
      <p>News and notices from the people who run this app.</p>
    </div>
    <div class="announce-list" id="announce-list"><div class="ai-loading"><span></span><span></span><span></span> Loading…</div></div>
    <div class="modal-actions"><button type="button" class="btn-primary" data-close>Done</button></div>`, { cardClass: 'feature-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  const list = box.querySelector('#announce-list');
  try {
    const { announcements } = await app.api('/api/announcements');
    list.innerHTML = announcements.length
      ? announcements.map((a) => announcementHtml(a)).join('')
      : '<div class="ai-empty">No announcements yet.</div>';
    await app.api('/api/announcements/seen', { method: 'POST' });
    refreshAnnouncementBadge();
  } catch (err) {
    list.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`;
  }
}

// ── Admin panel ────────────────────────────────────────────

export function showAdminEntry(user) {
  app.$('menu-admin')?.classList.toggle('hidden', !user?.isAdmin);
}

export function openAdminPanel() {
  const { box, close } = openModal(`
    <div class="admin-head">
      <div class="feature-hero-icon">${icon('dashboard')}</div>
      <div>
        <h3>Admin panel</h3>
        <p>Accounts, storage, backups and announcements.</p>
      </div>
      <button type="button" class="icon-btn admin-close" aria-label="Close">${icon('close')}</button>
    </div>
    <div class="admin-tabs" role="tablist">
      <button type="button" class="admin-tab active" data-tab="overview">Overview</button>
      <button type="button" class="admin-tab" data-tab="users">Users</button>
      <button type="button" class="admin-tab" data-tab="announce">Announcements</button>
    </div>
    <div class="admin-body" id="admin-body"></div>`, { cardClass: 'admin-card' });
  box.querySelector('.admin-close').addEventListener('click', close);
  const body = box.querySelector('#admin-body');
  const tabs = box.querySelectorAll('.admin-tab');
  const show = (tab) => {
    tabs.forEach((t) => t.classList.toggle('active', t.dataset.tab === tab));
    ({ overview: renderOverview, users: renderUsers, announce: renderAnnounce })[tab](body);
  };
  tabs.forEach((t) => t.addEventListener('click', () => show(t.dataset.tab)));
  show('overview');
}

const loading = '<div class="ai-loading"><span></span><span></span><span></span> Loading…</div>';

async function renderOverview(body) {
  body.innerHTML = loading;
  let s;
  try { s = await app.api('/api/admin/stats'); } catch (err) {
    body.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`;
    return;
  }
  const stat = (label, value, sub = '', tone = '') => `
    <div class="admin-stat ${tone}"><div class="admin-stat-value">${value}</div>
      <div class="admin-stat-label">${label}</div>${sub ? `<div class="admin-stat-sub">${sub}</div>` : ''}</div>`;
  const total = s.storage.uploads + s.storage.avatars + s.storage.backups + s.db_bytes;
  const bar = (n, cls) => `<span class="${cls}" style="width:${Math.max(total ? (n / total) * 100 : 0, n ? 1.5 : 0)}%"></span>`;
  body.innerHTML = `
    <div class="admin-stats">
      ${stat('Users', num(s.users), `+${num(s.new_week)} this week`)}
      ${stat('Online now', num(s.online), '', 'good')}
      ${stat('Verified', num(s.verified), `${s.users ? Math.round((s.verified / s.users) * 100) : 0}% of users`)}
      ${stat('Suspended', num(s.disabled), '', s.disabled ? 'warn' : '')}
      ${stat('Messages', num(s.messages), `${num(s.messages_day)} in 24 h`)}
      ${stat('Groups', num(s.groups))}
    </div>
    <div class="admin-section">
      <div class="admin-section-title">Storage <span>${bytes(total)}</span></div>
      <div class="storage-bar">${bar(s.storage.uploads, 'sb-uploads')}${bar(s.db_bytes, 'sb-db')}${bar(s.storage.avatars, 'sb-photos')}${bar(s.storage.backups, 'sb-backups')}</div>
      <div class="storage-legend">
        <span><i class="sb-uploads"></i>Files &amp; media ${bytes(s.storage.uploads)}</span>
        <span><i class="sb-db"></i>Database ${bytes(s.db_bytes)}</span>
        <span><i class="sb-photos"></i>Photos &amp; wallpapers ${bytes(s.storage.avatars)}</span>
        <span><i class="sb-backups"></i>Backups ${bytes(s.storage.backups)}</span>
      </div>
    </div>
    <div class="admin-section">
      <div class="admin-section-title">Backups <span>made automatically every night · last 7 kept</span></div>
      <div class="backup-list" id="backup-list"></div>
      <button type="button" class="btn-secondary" id="backup-now">${icon('export')} Back up now</button>
    </div>`;
  const list = body.querySelector('#backup-list');
  const drawBackups = (rows) => {
    list.innerHTML = rows.length ? rows.map((b, i) => `
      <div class="backup-row">
        <span class="backup-dot ${i === 0 ? 'fresh' : ''}"></span>
        <span class="backup-name">${app.escapeHtml(b.name)}</span>
        <span class="backup-size">${bytes(b.size)}</span>
        <span class="backup-when">${whenText(b.createdAt)}</span>
      </div>`).join('') : '<div class="ai-empty">No backups yet — the first one is made tonight, or tap “Back up now”.</div>';
  };
  drawBackups(s.backups);
  body.querySelector('#backup-now').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true;
    btn.textContent = 'Backing up…';
    try {
      const res = await app.api('/api/admin/backups', { method: 'POST' });
      drawBackups(res.backups);
      app.toast(`Backup saved (${bytes(res.backup.size)}).`);
    } catch (err) {
      app.toast(err.message, true);
    } finally {
      btn.disabled = false;
      btn.innerHTML = `${icon('export')} Back up now`;
    }
  });
}

function userRow(u) {
  const badges = [
    u.isAdmin ? '<span class="admin-badge admin">Admin</span>' : '',
    u.disabled ? '<span class="admin-badge off">Suspended</span>' : '',
    !u.verified ? '<span class="admin-badge pending">Not verified</span>' : '',
  ].join('');
  return `
    <div class="admin-user ${u.disabled ? 'is-off' : ''}" data-id="${u.id}">
      <div class="avatar admin-user-avatar" style="background:${app.escapeAttr(u.avatarColor)}">${app.avatarInner(u, { dot: true, online: u.online })}</div>
      <div class="admin-user-main">
        <div class="admin-user-name">${app.escapeHtml(u.displayName)} <span>@${app.escapeHtml(u.username)}</span>${badges}</div>
        <div class="admin-user-sub">${app.escapeHtml(u.phone || 'No number')} · ${app.escapeHtml(u.email || 'No Gmail')}</div>
        <div class="admin-user-sub">Joined ${whenText(u.createdAt)} · ${u.online ? '<b class="ok">online</b>' : `seen ${whenText(u.lastSeen)}`} · ${u.devices} locked device${u.devices === 1 ? '' : 's'}</div>
      </div>
      <div class="admin-user-actions">
        <button type="button" class="btn-secondary" data-act="devices" ${u.devices ? '' : 'disabled'}>Free devices</button>
        <button type="button" class="btn-secondary" data-act="admin">${u.isAdmin ? 'Remove admin' : 'Make admin'}</button>
        <button type="button" class="${u.disabled ? 'btn-secondary' : 'btn-danger-soft'}" data-act="disable">${u.disabled ? 'Restore' : 'Suspend'}</button>
      </div>
    </div>`;
}

async function renderUsers(body) {
  body.innerHTML = `
    <div class="admin-search">
      ${icon('search')}
      <input type="search" id="admin-q" placeholder="Search name, username, number or Gmail">
    </div>
    <div class="admin-users" id="admin-users">${loading}</div>
    <button type="button" class="btn-secondary hidden" id="admin-more">Show more</button>`;
  const listEl = body.querySelector('#admin-users');
  const more = body.querySelector('#admin-more');
  const qEl = body.querySelector('#admin-q');
  let users = [];
  let timer;

  const load = async (append = false) => {
    try {
      const res = await app.api(`/api/admin/users?q=${encodeURIComponent(qEl.value)}&offset=${append ? users.length : 0}`);
      users = append ? users.concat(res.users) : res.users;
      listEl.innerHTML = users.length ? users.map(userRow).join('') : '<div class="ai-empty">No one matches that.</div>';
      more.classList.toggle('hidden', res.users.length < 50);
    } catch (err) {
      listEl.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`;
    }
  };
  qEl.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => load(), 250); });
  more.addEventListener('click', () => load(true));

  listEl.addEventListener('click', async (e) => {
    const btn = e.target.closest('button[data-act]');
    if (!btn) return;
    const row = btn.closest('.admin-user');
    const u = users.find((x) => x.id === row.dataset.id);
    const act = btn.dataset.act;
    const who = `@${u.username}`;
    let path; let body_; let done;
    if (act === 'disable') {
      if (!confirm(u.disabled ? `Restore ${who}? They can sign in again.` : `Suspend ${who}? They're signed out everywhere at once and can't sign in until restored.`)) return;
      path = `/api/admin/users/${u.id}/disable`; body_ = { disabled: !u.disabled };
      done = () => { u.disabled = !u.disabled; return u.disabled ? `${who} is suspended.` : `${who} is restored.`; };
    } else if (act === 'admin') {
      if (!confirm(u.isAdmin ? `Remove admin access from ${who}?` : `Make ${who} an admin? They'll see this panel and can suspend accounts.`)) return;
      path = `/api/admin/users/${u.id}/admin`; body_ = { admin: !u.isAdmin };
      done = () => { u.isAdmin = !u.isAdmin; return `${who} ${u.isAdmin ? 'is now an admin' : 'is no longer an admin'}.`; };
    } else {
      if (!confirm(`Free ${who}'s locked devices? Any account can then sign in on those phones/computers (${who} can still sign back in).`)) return;
      path = `/api/admin/users/${u.id}/release-devices`; body_ = {};
      done = () => { u.devices = 0; return `${who}'s devices are free.`; };
    }
    btn.disabled = true;
    try {
      await app.api(path, { method: 'POST', body: JSON.stringify(body_) });
      app.toast(done());
      row.outerHTML = userRow(u);
    } catch (err) {
      app.toast(err.message, true);
      btn.disabled = false;
    }
  });
  load();
  qEl.focus();
}

async function renderAnnounce(body) {
  body.innerHTML = `
    <form class="announce-form" id="announce-form">
      <div class="field"><label>Title</label><input id="ann-title" maxlength="120" placeholder="Server maintenance tonight" required></div>
      <div class="field"><label>Message</label><textarea id="ann-body" rows="4" maxlength="2000" placeholder="Veyon Chat will be offline from 11 PM to 11:30 PM." required></textarea></div>
      <div class="announce-form-foot">
        <span>Everyone sees it in the app and gets a notification.</span>
        <button type="submit" class="btn-primary" id="ann-send">${icon('send')} Send to everyone</button>
      </div>
    </form>
    <div class="admin-section-title">Sent</div>
    <div class="announce-list" id="ann-list">${loading}</div>`;
  const listEl = body.querySelector('#ann-list');
  const draw = async () => {
    const { announcements } = await app.api('/api/announcements');
    listEl.innerHTML = announcements.length
      ? announcements.map((a) => announcementHtml(a, { admin: true })).join('')
      : '<div class="ai-empty">Nothing sent yet.</div>';
  };
  draw().catch(() => {});
  listEl.addEventListener('click', async (e) => {
    const del = e.target.closest('.announce-del');
    if (!del || !confirm('Delete this announcement for everyone?')) return;
    const id = del.closest('.announce-item').dataset.id;
    await app.api(`/api/admin/announcements/${id}`, { method: 'DELETE' }).catch((err) => app.toast(err.message, true));
    draw();
  });
  body.querySelector('#announce-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = body.querySelector('#ann-send');
    if (!confirm('Send this to every user now?')) return;
    btn.disabled = true;
    try {
      await app.api('/api/admin/announcements', {
        method: 'POST',
        body: JSON.stringify({ title: body.querySelector('#ann-title').value, body: body.querySelector('#ann-body').value }),
      });
      app.toast('Announcement sent.');
      e.target.reset();
      draw();
    } catch (err) {
      app.toast(err.message, true);
    } finally {
      btn.disabled = false;
    }
  });
}
