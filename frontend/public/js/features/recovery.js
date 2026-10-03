// Recovery key + "Forgot password?".
//
// Chats are encrypted with a key that only your password unlocks. A
// recovery key is a second way to unlock it: shown to you once, never sent
// to the server. With it, a password reset keeps every old message
// readable; without it, a reset has to start a fresh key.

import { app, icon, openModal } from './core.js';
import { exportPublicKey, generateIdentity, unwrapPrivateKey, wrapPrivateKey } from '../crypto.js';

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I

function newRecoveryKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  const chars = [...bytes].map((b) => ALPHABET[b % ALPHABET.length]).join('');
  return chars.match(/.{6}/g).join('-');
}

/** What the user typed → the exact string the key was wrapped with. */
const normalizeKey = (s) => String(s || '').toUpperCase().replace(/[^A-Z0-9]/g, '').match(/.{1,6}/g)?.join('-') || '';

function downloadText(name, text) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ── Create a recovery key (signed in) ──────────────────────

export function openRecoveryKeySetup({ onDone } = {}) {
  const me = app.state.me;
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('key')}</div>
      <h3>${me.hasRecoveryKey ? 'Make a new recovery key' : 'Create a recovery key'}</h3>
      <p>If you ever forget your password, this key lets you reset it <b>and keep all your old messages</b>. Only you will have it — we can't show it again.</p>
    </div>
    <div class="auth-error hidden" id="rk-error"></div>
    <div id="rk-step1">
      <div class="field"><label>Your password</label><input type="password" id="rk-password" autocomplete="current-password" placeholder="••••••••"></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" data-close>Not now</button>
        <button type="button" class="btn-primary" id="rk-make">Create key</button>
      </div>
    </div>
    <div id="rk-step2" class="hidden">
      <div class="recovery-key" id="rk-key"></div>
      <div class="recovery-actions">
        <button type="button" class="btn-secondary" id="rk-copy">${icon('copy')} Copy</button>
        <button type="button" class="btn-secondary" id="rk-download">${icon('export')} Download</button>
      </div>
      <label class="recovery-check"><input type="checkbox" id="rk-saved"> I've saved it somewhere safe (not only on this device)</label>
      <div class="modal-actions">
        <button type="button" class="btn-primary" id="rk-finish" disabled>Done</button>
      </div>
    </div>`, { cardClass: 'feature-card' });

  const errEl = box.querySelector('#rk-error');
  const fail = (m) => { errEl.textContent = m; errEl.classList.remove('hidden'); };
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#rk-password').focus();
  let key;

  const make = async () => {
    errEl.classList.add('hidden');
    const btn = box.querySelector('#rk-make');
    btn.disabled = true;
    btn.textContent = 'Creating…';
    try {
      // The key kept on this device can't be exported, so unlock the
      // account's copy with the password — that also checks it.
      const { encPrivateKey } = await app.api('/api/auth/me');
      const privateKey = await unwrapPrivateKey(encPrivateKey, box.querySelector('#rk-password').value)
        .catch(() => { throw new Error('That password isn’t right.'); });
      key = newRecoveryKey();
      const wrapped = await wrapPrivateKey({ privateKey }, key);
      await app.api('/api/auth/recovery-key', { method: 'POST', body: JSON.stringify({ encPrivateKeyRecovery: wrapped }) });
      me.hasRecoveryKey = true;
      box.querySelector('#rk-key').textContent = key;
      box.querySelector('#rk-step1').classList.add('hidden');
      box.querySelector('#rk-step2').classList.remove('hidden');
    } catch (err) {
      fail(err.message);
      btn.disabled = false;
      btn.textContent = 'Create key';
    }
  };
  box.querySelector('#rk-make').addEventListener('click', make);
  box.querySelector('#rk-password').addEventListener('keydown', (e) => { if (e.key === 'Enter') make(); });
  box.querySelector('#rk-copy').addEventListener('click', async () => {
    await navigator.clipboard.writeText(key).catch(() => {});
    app.toast('Recovery key copied.');
  });
  box.querySelector('#rk-download').addEventListener('click', () => downloadText(
    `veyon-recovery-key-${me.username}.txt`,
    `Veyon Chat recovery key for @${me.username}\n\n${key}\n\nUse it with "Forgot password?" to reset your password and keep your messages.\nKeep it private.\n`,
  ));
  box.querySelector('#rk-saved').addEventListener('change', (e) => { box.querySelector('#rk-finish').disabled = !e.target.checked; });
  box.querySelector('#rk-finish').addEventListener('click', () => { close(); app.toast('Recovery key saved. Keep it safe!'); onDone?.(); });
}

/** Once per device, a gentle nudge for accounts without a recovery key. */
export function nudgeRecoveryKey(user) {
  if (!user || user.hasRecoveryKey || user.contactVerified === false) return;
  try {
    if (localStorage.getItem('veyon.recoveryNudged')) return;
    localStorage.setItem('veyon.recoveryNudged', '1');
  } catch { return; }
  setTimeout(() => {
    if (!document.querySelector('.modal-backdrop')) openRecoveryKeySetup();
  }, 2500);
}

// ── Forgot password (signed out) ───────────────────────────

/** `signIn(username, password)` finishes by signing in normally. */
export function openForgotPassword(signIn) {
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('key')}</div>
      <h3>Reset your password</h3>
      <p>We’ll email a code to the Gmail on your account.</p>
    </div>
    <div class="auth-error hidden" id="fp-error"></div>
    <form id="fp-form1">
      <div class="field"><label>Username, mobile or Gmail</label><input id="fp-ident" autocomplete="username" required></div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" data-close>Cancel</button>
        <button type="submit" class="btn-primary" id="fp-send">Send code</button>
      </div>
    </form>
    <form id="fp-form2" class="hidden">
      <div class="otp-hint ok" id="fp-sent"></div>
      <div class="field"><label>Code from your Gmail</label><input id="fp-otp" inputmode="numeric" maxlength="6" autocomplete="one-time-code" placeholder="6-digit code" required></div>
      <div class="field"><label>New password</label><input id="fp-pass" type="password" autocomplete="new-password" minlength="8" placeholder="At least 8 characters" required></div>
      <div class="field">
        <label>Recovery key <span class="field-optional">— keeps your old messages</span></label>
        <input id="fp-key" autocomplete="off" spellcheck="false" placeholder="XXXXXX-XXXXXX-XXXXXX-XXXXXX">
      </div>
      <div class="modal-actions">
        <button type="button" class="btn-secondary" data-close>Cancel</button>
        <button type="submit" class="btn-primary" id="fp-reset">Reset password</button>
      </div>
    </form>`, { cardClass: 'feature-card' });

  box.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', close));
  const errEl = box.querySelector('#fp-error');
  const fail = (m) => { errEl.textContent = m; errEl.classList.remove('hidden'); errEl.scrollIntoView({ block: 'center' }); };
  const identEl = box.querySelector('#fp-ident');
  identEl.value = app.$('f-username').value.trim();
  identEl.focus();
  let verified = null; // {resetToken, username, recoveryWrapped} once the code is checked

  box.querySelector('#fp-form1').addEventListener('submit', async (e) => {
    e.preventDefault();
    errEl.classList.add('hidden');
    const btn = box.querySelector('#fp-send');
    btn.disabled = true;
    try {
      const res = await app.api('/api/auth/reset/otp', { method: 'POST', body: JSON.stringify({ ident: identEl.value }) });
      box.querySelector('#fp-sent').textContent = res.devCode
        ? `Test mode (no email set up): your code is ${res.devCode}`
        : `Code sent to ${res.email} — check your inbox (and Spam).`;
      box.querySelector('#fp-form1').classList.add('hidden');
      box.querySelector('#fp-form2').classList.remove('hidden');
      box.querySelector('#fp-otp').focus();
    } catch (err) {
      fail(err.message);
    } finally {
      btn.disabled = false;
    }
  });

  box.querySelector('#fp-form2').addEventListener('submit', async (e) => {
    e.preventDefault();
    errEl.classList.add('hidden');
    const btn = box.querySelector('#fp-reset');
    const password = box.querySelector('#fp-pass').value;
    const recovery = normalizeKey(box.querySelector('#fp-key').value);
    if (password.length < 8) return fail('Password must be at least 8 characters.');
    btn.disabled = true;
    btn.textContent = 'Checking…';
    try {
      if (!verified) {
        verified = await app.api('/api/auth/reset/verify', {
          method: 'POST', body: JSON.stringify({ ident: identEl.value, otp: box.querySelector('#fp-otp').value }),
        });
        box.querySelector('#fp-otp').disabled = true;
      }
      let payload;
      if (recovery) {
        if (!verified.recoveryWrapped) throw new Error('This account has no recovery key. Clear the box to reset without it.');
        const privateKey = await unwrapPrivateKey(verified.recoveryWrapped, recovery)
          .catch(() => { throw new Error('That recovery key isn’t right — check it, or clear the box to reset without it.'); });
        payload = { encPrivateKey: await wrapPrivateKey({ privateKey }, password), newIdentity: false };
      } else {
        const ok = confirm('Without your recovery key, your account gets a new encryption key.\n\n'
          + 'Messages from before can’t be opened any more — on any device. New messages work normally.\n\nReset anyway?');
        if (!ok) throw new Error('Enter your recovery key to keep your old messages.');
        const keyPair = await generateIdentity();
        payload = {
          encPrivateKey: await wrapPrivateKey(keyPair, password),
          publicKey: await exportPublicKey(keyPair),
          newIdentity: true,
        };
      }
      btn.textContent = 'Saving…';
      await app.api('/api/auth/reset/complete', {
        method: 'POST', body: JSON.stringify({ resetToken: verified.resetToken, password, ...payload }),
      });
      close();
      app.toast('Password changed — signing you in. Your other devices were signed out.');
      signIn(verified.username, password);
    } catch (err) {
      fail(err.message);
      btn.disabled = false;
      btn.textContent = 'Reset password';
    }
  });
}
