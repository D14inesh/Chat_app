// Business tools: product catalogue (manage / browse / share in a chat),
// away message (automatic reply), and private notes on a chat.

import { app, icon, openModal } from './core.js';
import { decryptText, encryptText } from '../crypto.js';

const CURRENCIES = ['INR', 'USD', 'EUR', 'GBP', 'AED', 'SGD', 'MYR', 'LKR'];

export function priceText(price, currency = 'INR') {
  if (price == null) return '';
  try {
    return new Intl.NumberFormat(undefined, { style: 'currency', currency, maximumFractionDigits: price % 1 ? 2 : 0 }).format(price);
  } catch {
    return `${currency} ${price}`;
  }
}

const photo = (url) => (url ? app.apiUrl(url) : '');

// ── Product messages ─────────────────────────────────────────

export function productBody(m, p) {
  if (!p || typeof p !== 'object') return '<div class="text" style="opacity:.6;font-style:italic">Product</div>';
  const { escapeHtml, escapeAttr } = app;
  return `
    <div class="product-card" data-seller="${escapeAttr(p.sellerId || '')}">
      ${p.photoUrl ? `<img class="product-photo" src="${escapeAttr(photo(p.photoUrl))}" alt="" loading="lazy">` : `<div class="product-photo empty">${icon('bag')}</div>`}
      <div class="product-info">
        <div class="product-name">${escapeHtml(p.name || 'Product')}</div>
        ${p.price != null ? `<div class="product-price">${escapeHtml(priceText(p.price, p.currency))}</div>` : ''}
        ${p.description ? `<div class="product-desc">${escapeHtml(p.description)}</div>` : ''}
        ${p.sellerId ? `<button type="button" class="product-more" data-catalog-user="${escapeAttr(p.sellerId)}">View catalogue</button>` : ''}
      </div>
    </div>`;
}

export const productPreview = (p) => `🛍 ${p && typeof p === 'object' ? p.name : 'Product'}`;

function snapshot(item) {
  return {
    itemId: item.id, sellerId: item.sellerId, name: item.name, price: item.price,
    currency: item.currency, description: item.description, photoUrl: item.photoUrl,
  };
}

// ── Automatic replies (kind 'auto', plain text from the server) ──

export function autoBody(m) {
  return `<div class="auto-tag">${icon('clock')} Automatic reply</div>
    <div class="text">${app.linkify(app.escapeHtml(m.ciphertext || ''))}</div>`;
}

// ── Catalogue: browse (anyone) ───────────────────────────────

export async function openCatalogue(userId, name) {
  let items;
  try { ({ items } = await app.api(`/api/users/${userId}/catalog`)); } catch (err) { app.toast(err.message, true); return; }
  const mine = userId === app.state.me.id;
  const { box, close } = openModal(`
    <div class="catalog-head">
      <h3>${icon('bag')} ${mine ? 'My catalogue' : `${app.escapeHtml(name || 'Business')} · Catalogue`}</h3>
      ${mine ? '<button type="button" class="btn-secondary" id="cat-manage">Manage</button>' : ''}
    </div>
    <div class="catalog-grid">
      ${items.length ? items.map((it) => `
        <button type="button" class="catalog-tile ${it.available ? '' : 'off'}" data-id="${app.escapeAttr(it.id)}">
          ${it.photoUrl ? `<img src="${app.escapeAttr(photo(it.photoUrl))}" alt="" loading="lazy">` : `<span class="catalog-noimg">${icon('bag')}</span>`}
          <span class="catalog-name">${app.escapeHtml(it.name)}</span>
          <span class="catalog-price">${app.escapeHtml(priceText(it.price, it.currency))}${it.available ? '' : ' · hidden'}</span>
        </button>`).join('') : '<div class="ai-empty">No products yet.</div>'}
    </div>
    <div class="modal-actions"><button type="button" class="btn-primary" data-close>Done</button></div>`, { cardClass: 'feature-card catalog-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#cat-manage')?.addEventListener('click', () => { close(); openCatalogManager(); });
  box.querySelectorAll('.catalog-tile').forEach((t) => t.addEventListener('click', () => {
    const it = items.find((x) => x.id === t.dataset.id);
    showProduct(it, name, close);
  }));
}

function showProduct(it, sellerName, closeParent) {
  const mine = it.sellerId === app.state.me.id;
  const { box, close } = openModal(`
    ${it.photoUrl ? `<img class="product-hero" src="${app.escapeAttr(photo(it.photoUrl))}" alt="">` : ''}
    <h3 style="margin-bottom:4px">${app.escapeHtml(it.name)}</h3>
    ${it.price != null ? `<div class="product-price big">${app.escapeHtml(priceText(it.price, it.currency))}</div>` : ''}
    ${it.description ? `<p class="product-desc-full">${app.escapeHtml(it.description)}</p>` : ''}
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Back</button>
      <button type="button" class="btn-primary" id="prod-send">${icon('send')} ${mine ? 'Send in this chat' : `Ask ${app.escapeHtml(sellerName || 'them')} about this`}</button>
    </div>`, { cardClass: 'feature-card product-modal' });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#prod-send').addEventListener('click', async () => {
    close();
    closeParent?.();
    // Land in the chat: close whatever led here (contact info, catalogue).
    document.querySelectorAll('.modal-backdrop').forEach((m) => m.remove());
    if (!mine) await app.startChatWith(it.sellerId);
    if (!app.state.activeId) { app.toast('Open a chat first.', true); return; }
    app.sendJsonMessage('product', snapshot(it));
  });
}

/** Attach menu → "Catalogue": send one of my products. */
export async function openSendProduct() {
  let items;
  try { ({ items } = await app.api(`/api/users/${app.state.me.id}/catalog`)); } catch (err) { app.toast(err.message, true); return; }
  items = items.filter((i) => i.available);
  if (!items.length) {
    app.toast('Your catalogue is empty — add products in Edit profile → Business profile.', true);
    return;
  }
  const { box, close } = openModal(`
    <h3>${icon('briefcase', 'class="modal-title-icon"')} Send a product</h3>
    <div class="catalog-grid">${items.map((it) => `
      <button type="button" class="catalog-tile" data-id="${app.escapeAttr(it.id)}">
        ${it.photoUrl ? `<img src="${app.escapeAttr(photo(it.photoUrl))}" alt="">` : `<span class="catalog-noimg">${icon('bag')}</span>`}
        <span class="catalog-name">${app.escapeHtml(it.name)}</span>
        <span class="catalog-price">${app.escapeHtml(priceText(it.price, it.currency))}</span>
      </button>`).join('')}</div>
    <div class="modal-actions"><button type="button" class="btn-secondary" data-close>Cancel</button></div>`, { cardClass: 'feature-card catalog-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelectorAll('.catalog-tile').forEach((t) => t.addEventListener('click', () => {
    app.sendJsonMessage('product', snapshot(items.find((x) => x.id === t.dataset.id)));
    close();
  }));
}

// "View catalogue" anywhere (product cards, contact info).
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-catalog-user]');
  if (!b) return;
  e.stopPropagation();
  const convo = app.state.conversations.get(app.state.activeId);
  openCatalogue(b.dataset.catalogUser, convo?.peer?.id === b.dataset.catalogUser ? convo.peer.displayName : b.dataset.catalogName);
});

// ── Catalogue: manage (my own) ───────────────────────────────

export async function openCatalogManager() {
  const { box, close } = openModal(`
    <div class="catalog-head">
      <h3>${icon('bag')} My catalogue</h3>
      <button type="button" class="btn-primary" id="cat-add">${icon('plus')} Add product</button>
    </div>
    <div class="catalog-manage" id="cat-list"><div class="ai-loading"><span></span><span></span><span></span> Loading…</div></div>
    <div class="modal-actions"><button type="button" class="btn-secondary" data-close>Done</button></div>`, { cardClass: 'feature-card catalog-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  const list = box.querySelector('#cat-list');
  let items = [];
  const draw = () => {
    list.innerHTML = items.length ? items.map((it, i) => `
      <div class="cat-row ${it.available ? '' : 'off'}" data-id="${app.escapeAttr(it.id)}">
        ${it.photoUrl ? `<img src="${app.escapeAttr(photo(it.photoUrl))}" alt="">` : `<span class="catalog-noimg sm">${icon('bag')}</span>`}
        <div class="cat-row-main">
          <div class="catalog-name">${app.escapeHtml(it.name)}</div>
          <div class="catalog-price">${app.escapeHtml(priceText(it.price, it.currency) || 'No price')}${it.available ? '' : ' · hidden'}</div>
        </div>
        <button type="button" class="icon-btn" data-act="up" ${i === 0 ? 'disabled' : ''} title="Move up">▲</button>
        <button type="button" class="icon-btn" data-act="down" ${i === items.length - 1 ? 'disabled' : ''} title="Move down">▼</button>
        <button type="button" class="icon-btn" data-act="edit" title="Edit">${icon('edit')}</button>
        <button type="button" class="icon-btn" data-act="del" title="Delete">${icon('trash')}</button>
      </div>`).join('') : `<div class="calls-empty">${icon('bag')}<div>No products yet</div><small>Add what you sell — customers see it in your profile and you can send it in chats.</small></div>`;
    list.querySelectorAll('.cat-row').forEach((row) => row.addEventListener('click', async (e) => {
      const act = e.target.closest('button')?.dataset.act;
      const i = items.findIndex((x) => x.id === row.dataset.id);
      if (!act) return;
      if (act === 'edit') { editProduct(items[i], load); return; }
      if (act === 'del') {
        if (!confirm(`Delete "${items[i].name}"?`)) return;
        await app.api(`/api/catalog/${items[i].id}`, { method: 'DELETE' }).catch((err) => app.toast(err.message, true));
        load();
        return;
      }
      const j = act === 'up' ? i - 1 : i + 1;
      [items[i], items[j]] = [items[j], items[i]];
      draw();
      app.api('/api/catalog/reorder', { method: 'POST', body: JSON.stringify({ ids: items.map((x) => x.id) }) }).catch(() => {});
    }));
  };
  const load = async () => {
    try { ({ items } = await app.api(`/api/users/${app.state.me.id}/catalog`)); draw(); } catch (err) { list.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`; }
  };
  box.querySelector('#cat-add').addEventListener('click', () => editProduct(null, load));
  load();
}

function editProduct(item, onSaved) {
  const it = item || { name: '', price: null, currency: 'INR', description: '', available: true };
  const { box, close } = openModal(`
    <h3>${item ? 'Edit product' : 'Add product'}</h3>
    <div class="prod-photo-pick" id="pp">
      ${it.photoUrl ? `<img src="${app.escapeAttr(photo(it.photoUrl))}" alt="">` : `<span>${icon('plus')} Add a photo</span>`}
    </div>
    <input type="file" id="pp-file" accept="image/jpeg,image/png,image/webp" hidden>
    <div class="field"><label>Name</label><input id="pf-name" maxlength="80" value="${app.escapeAttr(it.name)}" placeholder="Masala dosa"></div>
    <div class="biz-grid">
      <div class="field"><label>Price</label><input id="pf-price" inputmode="decimal" value="${it.price ?? ''}" placeholder="120"></div>
      <div class="field"><label>Currency</label><select id="pf-cur">${CURRENCIES.map((c) => `<option ${c === it.currency ? 'selected' : ''}>${c}</option>`).join('')}</select></div>
    </div>
    <div class="field"><label>Description</label><textarea id="pf-desc" rows="3" maxlength="600" placeholder="Size, colours, what's included…">${app.escapeHtml(it.description)}</textarea></div>
    <label class="toggle-row"><span><span class="toggle-title">Show in catalogue</span><span class="toggle-sub">Turn off to hide it without deleting</span></span>
      <input type="checkbox" class="switch" id="pf-avail" ${it.available ? 'checked' : ''}></label>
    <div class="modal-actions">
      ${item?.photoUrl ? '<button type="button" class="btn-secondary" id="pf-nophoto">Remove photo</button>' : ''}
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="pf-save">Save</button>
    </div>`, { cardClass: 'feature-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  let file = null;
  let removePhoto = false;
  const pick = box.querySelector('#pp');
  const fileEl = box.querySelector('#pp-file');
  pick.addEventListener('click', () => fileEl.click());
  fileEl.addEventListener('change', () => {
    file = fileEl.files[0] || null;
    if (file) { pick.innerHTML = `<img src="${URL.createObjectURL(file)}" alt="">`; removePhoto = false; }
  });
  box.querySelector('#pf-nophoto')?.addEventListener('click', (e) => {
    removePhoto = true; file = null;
    pick.innerHTML = `<span>${icon('plus')} Add a photo</span>`;
    e.target.remove();
  });
  box.querySelector('#pf-save').addEventListener('click', async (e) => {
    const form = new FormData();
    form.append('name', box.querySelector('#pf-name').value);
    form.append('price', box.querySelector('#pf-price').value);
    form.append('currency', box.querySelector('#pf-cur').value);
    form.append('description', box.querySelector('#pf-desc').value);
    form.append('available', box.querySelector('#pf-avail').checked ? 'true' : 'false');
    if (file) form.append('photo', file);
    if (item) form.append('remove_photo', removePhoto ? 'true' : 'false');
    e.target.disabled = true;
    try {
      const res = await fetch(app.apiUrl(item ? `/api/catalog/${item.id}` : '/api/catalog'), {
        method: item ? 'PATCH' : 'POST', body: form, credentials: 'include',
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not save.');
      close();
      app.toast(item ? 'Product updated.' : 'Product added.');
      onSaved();
    } catch (err) {
      app.toast(err.message, true);
      e.target.disabled = false;
    }
  });
}

// ── Away message ─────────────────────────────────────────────

export async function openAwaySettings() {
  let a;
  try { ({ away: a } = await app.api('/api/users/me/away')); } catch (err) { app.toast(err.message, true); return; }
  const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('clock')}</div>
      <h3>Away message</h3>
      <p>Customers who message you while you're away get this reply automatically — at most once every 12 hours each.</p>
    </div>
    <label class="toggle-row"><span><span class="toggle-title">Send away message</span></span>
      <input type="checkbox" class="switch" id="aw-on" ${a.enabled ? 'checked' : ''}></label>
    <div class="field"><label>Message</label><textarea id="aw-msg" rows="3" maxlength="500" placeholder="Thanks for your message! We're closed now and will reply when we open at 9 AM.">${app.escapeHtml(a.message || '')}</textarea></div>
    <div class="field"><label>When</label>
      <div class="seg" id="aw-mode">
        <button type="button" data-v="outside" class="${a.mode !== 'always' ? 'active' : ''}">Outside business hours</button>
        <button type="button" data-v="always" class="${a.mode === 'always' ? 'active' : ''}">Always</button>
      </div>
    </div>
    <div id="aw-hours" class="${a.mode === 'always' ? 'hidden' : ''}">
      <div class="biz-grid">
        <div class="field"><label>Open from</label><input type="time" id="aw-from" value="${a.from}"></div>
        <div class="field"><label>Until</label><input type="time" id="aw-to" value="${a.to}"></div>
      </div>
      <div class="field"><label>Open on</label>
        <div class="day-chips">${DAYS.map((d, i) => `<button type="button" class="day-chip ${a.days.includes(i + 1) ? 'active' : ''}" data-d="${i + 1}">${d}</button>`).join('')}</div>
      </div>
    </div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="aw-save">Save</button>
    </div>`, { cardClass: 'feature-card' });
  let mode = a.mode === 'always' ? 'always' : 'outside';
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelectorAll('#aw-mode button').forEach((b) => b.addEventListener('click', () => {
    mode = b.dataset.v;
    box.querySelectorAll('#aw-mode button').forEach((x) => x.classList.toggle('active', x === b));
    box.querySelector('#aw-hours').classList.toggle('hidden', mode === 'always');
  }));
  box.querySelectorAll('.day-chip').forEach((b) => b.addEventListener('click', () => b.classList.toggle('active')));
  box.querySelector('#aw-save').addEventListener('click', async () => {
    try {
      await app.api('/api/users/me/away', {
        method: 'PATCH',
        body: JSON.stringify({
          enabled: box.querySelector('#aw-on').checked,
          message: box.querySelector('#aw-msg').value,
          mode,
          from: box.querySelector('#aw-from').value,
          to: box.querySelector('#aw-to').value,
          days: [...box.querySelectorAll('.day-chip.active')].map((b) => Number(b.dataset.d)),
          tzOffset: -new Date().getTimezoneOffset(),
        }),
      });
      close();
      app.toast('Away message saved.');
    } catch (err) { app.toast(err.message, true); }
  });
}

// ── Private notes on a chat ──────────────────────────────────

export async function openChatNotes() {
  const convo = app.state.conversations.get(app.state.activeId);
  if (!convo) return;
  const key = await app.keyFor(convo);
  let text = '';
  let updatedAt = null;
  try {
    const { note } = await app.api(`/api/conversations/${convo.id}/note`);
    if (note) { text = await decryptText(key, note.ciphertext, note.iv).catch(() => ''); updatedAt = note.updatedAt; }
  } catch (err) { app.toast(err.message, true); return; }
  const isBiz = !!app.state.me.businessSettings?.enabled;
  const who = convo.kind === 'group' ? convo.title : convo.peer.displayName;
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('edit')}</div>
      <h3>${isBiz ? 'Customer notes' : 'Notes'} · ${app.escapeHtml(who)}</h3>
      <p>Only you can see these — they're encrypted like your messages.</p>
    </div>
    <div class="field"><textarea id="note-text" rows="8" maxlength="5000" placeholder="${isBiz ? 'Order details, preferences, follow-ups…' : 'Anything to remember about this chat'}">${app.escapeHtml(text)}</textarea></div>
    ${updatedAt ? `<div class="note-updated">Last saved ${new Date(updatedAt).toLocaleString()}</div>` : ''}
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="note-save">Save</button>
    </div>`, { cardClass: 'feature-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#note-text').focus();
  box.querySelector('#note-save').addEventListener('click', async () => {
    const value = box.querySelector('#note-text').value.trim();
    try {
      const body = value ? await encryptText(key, value) : { ciphertext: '' };
      await app.api(`/api/conversations/${convo.id}/note`, { method: 'PUT', body: JSON.stringify(body) });
      close();
      app.toast(value ? 'Note saved.' : 'Note cleared.');
    } catch (err) { app.toast(err.message, true); }
  });
}
