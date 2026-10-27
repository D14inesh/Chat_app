// Sign-in approval. A sign-in from a device or browser the account hasn't
// used before waits here until the owner accepts it — from the email to
// their Gmail, or from a device they're already signed in on (the
// "login-approval" frame below). Server side: backend/app/utils/login_approval.py.

import { app, icon, openModal } from './core.js';

/** Shown on the new device. Resolves with the normal login result once
 *  accepted; rejects (with a readable message) if rejected, expired or
 *  cancelled. */
export function waitForApproval(pending) {
  return new Promise((resolve, reject) => {
    const { box, close } = openModal(`
      <div class="feature-hero">
        <div class="feature-hero-icon">${icon('shield')}</div>
        <h3>Accept on your phone</h3>
        <p>To keep your account safe, every sign-in on a computer needs your OK.
           Tap <b>Yes, it’s me</b> on your phone${pending.emailed ? ` — or <b>Accept</b> in the email sent to
           <b>${app.escapeHtml(pending.email || 'your Gmail')}</b>` : ''} — and this page continues by itself.</p>
        <p class="join-note">Tip: next time, use <b>Link this device from your phone</b> to sign in with a QR code.</p>
      </div>
      <div class="approval-wait"><span class="link-spinner"></span> Waiting for approval…</div>
      ${pending.devApproveUrl ? `<p class="join-note">Test mode (no email set up):
        <a href="${app.escapeHtml(pending.devApproveUrl)}" target="_blank" rel="noopener">open the accept link</a></p>` : ''}
      ${!pending.emailed && !pending.devApproveUrl ? `<p class="join-note">Email isn't set up on this server —
        accept it from a device you're already signed in on.</p>` : ''}
      <div class="modal-actions"><button type="button" class="btn-secondary" id="approval-cancel">Cancel</button></div>`,
    { cardClass: 'feature-card', onClose: () => finish(new Error('Sign-in cancelled.')) });

    let timer = null;
    let done = false;
    function finish(err, result) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (err) reject(err); else resolve(result);
    }
    box.querySelector('#approval-cancel').addEventListener('click', () => close());

    const poll = async () => {
      if (done) return;
      if (!box.isConnected) { finish(new Error('Sign-in cancelled.')); return; }   // closed with Escape
      try {
        const res = await app.api('/api/auth/login/pending', {
          method: 'POST', body: JSON.stringify({ approvalId: pending.approvalId }),
        });
        if (res.pending) { timer = setTimeout(poll, 2500); return; }
        finish(null, res);
        box.remove();
      } catch (e) {
        finish(e);
        box.remove();
      }
    };
    timer = setTimeout(poll, 2500);
  });
}

/** Shown on devices that are already signed in: someone is trying to sign
 *  in on a new device — accept or reject right here. */
export function onLoginApproval(frame) {
  const a = frame.approval;
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('shield')}</div>
      <h3>Is this you signing in?</h3>
      <p>Someone is trying to sign in to your account on
         <b>${app.escapeHtml(a.device || 'a new device')}</b>${a.ip ? ` (${app.escapeHtml(a.ip)})` : ''}.</p>
    </div>
    <div class="auth-error hidden" id="approval-error"></div>
    <div class="modal-actions">
      <button type="button" class="btn-danger-soft" id="approval-reject">No — reject</button>
      <button type="button" class="btn-primary" id="approval-accept">Yes, it's me</button>
    </div>`, { cardClass: 'feature-card' });
  const answer = async (action) => {
    try {
      await app.api(`/api/auth/login-approval/${a.id}`, { method: 'POST', body: JSON.stringify({ action }) });
      close();
      app.toast(action === 'approve' ? 'Sign-in accepted.' : 'Sign-in rejected. If it wasn’t you, change your password.');
    } catch (e) {
      const err = box.querySelector('#approval-error');
      err.textContent = e.message;
      err.classList.remove('hidden');
    }
  };
  box.querySelector('#approval-accept').addEventListener('click', () => answer('approve'));
  box.querySelector('#approval-reject').addEventListener('click', () => answer('reject'));
}
