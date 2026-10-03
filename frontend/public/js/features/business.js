// Business profile — category, description, address, hours, email and
// website on your profile, shown to people in Contact info.

import { app, icon } from './core.js';

const CATEGORIES = [
  'Jewellery', 'Finance & loans', 'Retail shop', 'Restaurant & food', 'Grocery', 'Clothing & fashion',
  'Beauty & salon', 'Health & medical', 'Education', 'Professional services', 'Automotive',
  'Real estate', 'Travel', 'Electronics', 'Other',
];

/** Section appended to the Edit profile modal. */
export function businessSectionHtml() {
  const b = app.state.me.businessSettings || {};
  const { escapeAttr, escapeHtml } = app;
  return `
    <div class="field business-section" style="margin-top:22px">
      <label>Business profile</label>
      <label class="toggle-row">
        <span>
          <span class="toggle-title">${icon('briefcase')} Show a business profile</span>
          <span class="toggle-sub">Your hours, address and contact details on your profile</span>
        </span>
        <input type="checkbox" class="switch" id="biz-enabled" ${b.enabled ? 'checked' : ''}>
      </label>
      <div class="business-fields ${b.enabled ? '' : 'collapsed'}" id="biz-fields">
        <div class="biz-grid">
          <div class="field"><label>Category</label>
            <select id="biz-category">
              <option value="">Choose…</option>
              ${CATEGORIES.map((c) => `<option ${c === b.category ? 'selected' : ''}>${escapeHtml(c)}</option>`).join('')}
            </select></div>
          <div class="field"><label>Business hours</label>
            <input id="biz-hours" maxlength="120" placeholder="Mon–Sat, 9 am – 6 pm" value="${escapeAttr(b.hours || '')}"></div>
        </div>
        <div class="field"><label>Description</label>
          <textarea id="biz-description" rows="2" maxlength="300" placeholder="What you offer, in a line or two">${escapeHtml(b.description || '')}</textarea></div>
        <div class="field"><label>Address</label>
          <input id="biz-address" maxlength="200" placeholder="Shop no., street, city" value="${escapeAttr(b.address || '')}"></div>
        <div class="biz-grid">
          <div class="field"><label>Email</label>
            <input id="biz-email" type="email" maxlength="120" placeholder="hello@yourshop.com" value="${escapeAttr(b.email || '')}"></div>
          <div class="field"><label>Website</label>
            <input id="biz-website" maxlength="200" placeholder="yourshop.com" value="${escapeAttr(b.website || '')}"></div>
        </div>
      </div>
      <button type="button" class="btn-primary" id="biz-save" style="margin-top:6px">Save business profile</button>
    </div>`;
}

export function wireBusinessSection(box) {
  const enabled = box.querySelector('#biz-enabled');
  const fields = box.querySelector('#biz-fields');
  if (!enabled) return;
  enabled.addEventListener('change', () => fields.classList.toggle('collapsed', !enabled.checked));
  const save = box.querySelector('#biz-save');
  save.addEventListener('click', async () => {
    const v = (id) => box.querySelector(`#biz-${id}`).value.trim();
    save.disabled = true;
    save.textContent = 'Saving…';
    try {
      const { businessSettings } = await app.api('/api/users/me/business', {
        method: 'PATCH',
        body: JSON.stringify({
          enabled: enabled.checked, category: v('category'), description: v('description'),
          address: v('address'), hours: v('hours'), email: v('email'), website: v('website'),
        }),
      });
      app.state.me.businessSettings = businessSettings;
      app.toast(enabled.checked ? 'Business profile saved.' : 'Business profile hidden.');
    } catch (err) {
      app.toast(err.message, true);
    } finally {
      save.disabled = false;
      save.textContent = 'Save business profile';
    }
  });
}

/** Block for Contact info; fetched fresh since the chat list doesn't carry it. */
export async function businessBlockFor(userId) {
  try {
    const { user } = await app.api(`/api/users/${userId}`);
    const b = user.business;
    if (!b) return '';
    const { escapeHtml, escapeAttr } = app;
    const row = (ic, html) => `<div class="biz-row">${icon(ic)}<span>${html}</span></div>`;
    return `
      <div class="contact-info-block business-block">
        <div class="biz-badge">${icon('briefcase')} Business${b.category ? ` · ${escapeHtml(b.category)}` : ''}</div>
        ${b.description ? `<div class="biz-description">${escapeHtml(b.description)}</div>` : ''}
        ${b.address ? row('map', `<a href="https://www.openstreetmap.org/search?query=${encodeURIComponent(b.address)}" target="_blank" rel="noopener">${escapeHtml(b.address)}</a>`) : ''}
        ${b.hours ? row('clock', escapeHtml(b.hours)) : ''}
        ${b.email ? row('mail', `<a href="mailto:${escapeAttr(b.email)}">${escapeHtml(b.email)}</a>`) : ''}
        ${b.website ? row('link', `<a href="${escapeAttr(b.website)}" target="_blank" rel="noopener">${escapeHtml(b.website.replace(/^https?:\/\//, ''))}</a>`) : ''}
      </div>`;
  } catch {
    return '';
  }
}
