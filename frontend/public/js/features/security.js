// Login alerts & devices — every sign-in to the account pops an alert on
// your other devices, and "Security & logins" lists recent sign-ins with a
// one-tap "Log out all other devices".

import { app, icon, openModal, whenText } from './core.js';

const METHOD_LABEL = { password: 'Password', qr: 'QR code (linked device)', register: 'New account' };

function deviceIcon(device) {
  return /Android|iPhone|app/i.test(device) ? 'phone' : 'device';
}

export function onLoginAlert(frame) {
  const login = frame.login;
  const el = document.createElement('div');
  el.className = 'login-alert';
  el.innerHTML = `
    <div class="login-alert-icon">${icon('shield')}</div>
    <div class="login-alert-body">
      <div class="login-alert-title">New login to your account</div>
      <div class="login-alert-sub">${app.escapeHtml(login.device)}${login.ip ? ` · ${app.escapeHtml(login.ip)}` : ''} · ${whenText(login.createdAt)}</div>
    </div>
    <button type="button" class="btn-secondary login-alert-review">Review</button>
    <button type="button" class="icon-btn login-alert-close" aria-label="Dismiss">${icon('close')}</button>`;
  document.body.appendChild(el);
  requestAnimationFrame(() => el.classList.add('show'));
  const dismiss = () => { el.classList.remove('show'); setTimeout(() => el.remove(), 300); };
  el.querySelector('.login-alert-close').addEventListener('click', dismiss);
  el.querySelector('.login-alert-review').addEventListener('click', () => { dismiss(); openSecurityPanel(); });
  setTimeout(dismiss, 15_000);
}

export async function openSecurityPanel() {
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('shield')}</div>
      <h3>Security &amp; logins</h3>
      <p>Every sign-in to your account. You get an alert on your other devices each time.</p>
    </div>
    <div class="login-list" id="login-list"><div class="ai-loading"><span></span><span></span><span></span> Loading…</div></div>
    <div class="danger-zone">
      <div>
        <div class="danger-title">Don't recognise a login?</div>
        <div class="danger-sub">Sign out every device except this one, straight away.</div>
      </div>
      <button type="button" class="btn-danger" id="logout-others">Log out all other devices</button>
    </div>
    <div class="danger-zone device-lock">
      <div>
        <div class="danger-title">${icon('lock')} This device is locked to your account</div>
        <div class="danger-sub">Only one account can be used on a device. Giving this computer to someone else? Release it — you'll be signed out and another account can sign in here.</div>
      </div>
      <button type="button" class="btn-danger" id="release-device">Release this device</button>
    </div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" id="open-linked">${icon('qr')} Link a device</button>
      <button type="button" class="btn-primary" data-close>Done</button>
    </div>`, { cardClass: 'feature-card' });

  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#open-linked').addEventListener('click', () => { close(); app.openLinkedDevicesPanel(); });

  const listEl = box.querySelector('#login-list');
  try {
    const { logins } = await app.api('/api/auth/logins');
    listEl.innerHTML = logins.length ? logins.map((l, i) => `
      <div class="login-row">
        <div class="login-row-icon">${icon(deviceIcon(l.device))}</div>
        <div class="login-row-body">
          <div class="login-row-device">${app.escapeHtml(l.device)}${i === 0 ? '<span class="login-latest">Latest</span>' : ''}</div>
          <div class="login-row-sub">${app.escapeHtml(METHOD_LABEL[l.method] || l.method)}${l.ip ? ` · ${app.escapeHtml(l.ip)}` : ''}</div>
        </div>
        <div class="login-row-when">${whenText(l.createdAt)}</div>
      </div>`).join('') : '<div class="ai-empty">No sign-ins recorded yet.</div>';
  } catch (err) {
    listEl.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`;
  }

  box.querySelector('#release-device').addEventListener('click', async (e) => {
    if (!confirm('Release this device and sign out? Another account will then be able to sign in here. You can still sign back in as yourself.')) return;
    e.currentTarget.disabled = true;
    e.currentTarget.textContent = 'Releasing…';
    await app.signOut(true);
  });

  box.querySelector('#logout-others').addEventListener('click', async (e) => {
    if (!confirm('Log out every other device signed in to your account? They will need your password (or a QR link) to sign in again.')) return;
    const btn = e.currentTarget;
    btn.disabled = true;
    btn.textContent = 'Signing out…';
    try {
      await app.api('/api/auth/logout-others', { method: 'POST' });
      app.toast('All other devices are signed out.');
      btn.textContent = 'Done — others signed out';
    } catch (err) {
      app.toast(err.message, true);
      btn.disabled = false;
      btn.textContent = 'Log out all other devices';
    }
  });
}
