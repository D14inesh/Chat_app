// Mobile number + Gmail — every account has both, each used by one account
// only. A 6-digit code emailed to the Gmail proves it. Used by the sign-up
// form, the one-time "verify your account" step for older accounts, and
// "Change mobile / Gmail" in Security & logins.

import { app, icon } from './core.js';

const RESEND_SECONDS = 45;

/** Phone + email + code inputs (the sign-up form has the same markup). */
export function contactFieldsHtml({ phone = '', email = '' } = {}) {
  return `
    <div class="field">
      <label>Mobile number</label>
      <input class="cf-phone" type="tel" inputmode="tel" autocomplete="tel" placeholder="98765 43210" value="${app.escapeAttr(phone)}" required>
    </div>
    <div class="field">
      <label>Gmail</label>
      <input class="cf-email" type="email" autocomplete="email" placeholder="you@gmail.com" value="${app.escapeAttr(email)}" required>
    </div>
    <div class="field">
      <label>Code from your Gmail</label>
      <div class="otp-row">
        <input class="cf-otp" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="6-digit code" required>
        <button type="button" class="btn-secondary cf-send">Send code</button>
      </div>
      <div class="otp-hint cf-hint"></div>
    </div>`;
}

/** Wires the "Send code" button inside `root`. `path` is the endpoint that
 *  emails the code. Returns a reader for the three values. */
export function wireContactFields(root, path, onError) {
  const phoneEl = root.querySelector('.cf-phone');
  const emailEl = root.querySelector('.cf-email');
  const otpEl = root.querySelector('.cf-otp');
  const sendBtn = root.querySelector('.cf-send');
  const hint = root.querySelector('.cf-hint');
  let timer = null;

  const countdown = () => {
    let left = RESEND_SECONDS;
    clearInterval(timer);
    sendBtn.disabled = true;
    const tick = () => {
      if (left <= 0) { clearInterval(timer); sendBtn.disabled = false; sendBtn.textContent = 'Resend'; return; }
      sendBtn.textContent = `Resend ${left--}s`;
    };
    tick();
    timer = setInterval(tick, 1000);
  };

  sendBtn.addEventListener('click', async () => {
    hint.className = 'otp-hint cf-hint';
    hint.textContent = '';
    if (!phoneEl.value.trim() || !emailEl.value.trim()) {
      onError('Enter your mobile number and Gmail first.');
      return;
    }
    sendBtn.disabled = true;
    sendBtn.textContent = 'Sending…';
    try {
      const res = await app.api(path, {
        method: 'POST',
        body: JSON.stringify({ phone: phoneEl.value, email: emailEl.value }),
      });
      hint.classList.add('ok');
      hint.textContent = res.devCode
        ? `Test mode (no email set up): your code is ${res.devCode}`
        : `Code sent to ${emailEl.value.trim()} — check your inbox (and Spam).`;
      countdown();
      otpEl.focus();
    } catch (err) {
      onError(err.message);
      sendBtn.disabled = false;
      sendBtn.textContent = 'Send code';
    }
  });

  return () => ({ phone: phoneEl.value, email: emailEl.value, otp: otpEl.value.trim() });
}

/** Contact dialog. `blocking`: older accounts must finish it to continue
 *  (no closing, only "Sign out" as the way out). */
export function openContactPanel({ blocking = false } = {}) {
  const me = app.state.me || {};
  const box = document.createElement('div');
  box.className = 'modal-backdrop';
  box.innerHTML = `
    <div class="modal-card feature-card verify-card">
      <div class="feature-hero">
        <div class="feature-hero-icon">${icon('shield')}</div>
        <h3>${blocking ? 'Verify your account' : 'Mobile number &amp; Gmail'}</h3>
        <p>${blocking
          ? 'Each account now needs its own mobile number and Gmail — one account per number. We’ll email you a code.'
          : 'One account per mobile number and Gmail. Changing them needs a new code from your Gmail.'}</p>
      </div>
      <div class="auth-error hidden" id="contact-error"></div>
      <form id="contact-form">
        ${contactFieldsHtml({ phone: me.phone || '', email: me.email || '' })}
        <div class="modal-actions">
          ${blocking ? '<button type="button" class="btn-secondary" id="contact-signout">Sign out</button>'
                     : '<button type="button" class="btn-secondary" id="contact-cancel">Cancel</button>'}
          <button type="submit" class="btn-primary" id="contact-save">${blocking ? 'Verify & continue' : 'Save'}</button>
        </div>
      </form>
    </div>`;
  document.body.appendChild(box);
  // Escape / outside clicks close only the optional version.
  if (!blocking) box.addEventListener('click', (e) => { if (e.target === box) box.remove(); });

  const errEl = box.querySelector('#contact-error');
  const showError = (msg) => {
    errEl.textContent = msg;
    errEl.classList.remove('hidden');
    errEl.scrollIntoView({ block: 'center', behavior: 'smooth' });
  };
  const read = wireContactFields(box, '/api/auth/contact/otp', showError);

  box.querySelector('#contact-cancel')?.addEventListener('click', () => box.remove());
  box.querySelector('#contact-signout')?.addEventListener('click', () => app.signOut());
  box.querySelector('#contact-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    errEl.classList.add('hidden');
    const btn = box.querySelector('#contact-save');
    btn.disabled = true;
    try {
      const saved = await app.api('/api/auth/contact', { method: 'POST', body: JSON.stringify(read()) });
      Object.assign(app.state.me, saved);
      box.remove();
      app.toast(blocking ? 'Account verified — thank you!' : 'Mobile number and Gmail updated.');
    } catch (err) {
      showError(err.message);
    } finally {
      btn.disabled = false;
    }
  });
  box.querySelector(me.phone ? '.cf-email' : '.cf-phone').focus();
}

/** After sign-in: older accounts without a verified number + Gmail must add them. */
export async function ensureContact(user) {
  let verified = user.contactVerified;
  if (verified === undefined) {
    try {
      const { user: fresh } = await app.api('/api/auth/me');
      Object.assign(app.state.me, { phone: fresh.phone, email: fresh.email, contactVerified: fresh.contactVerified });
      verified = fresh.contactVerified;
    } catch { return; /* offline — ask next time */ }
  }
  if (verified === false && !document.querySelector('.verify-card')) openContactPanel({ blocking: true });
}
