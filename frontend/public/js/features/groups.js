// Groups: info panel (description, admins, settings, invite link, join
// requests), "only admins can send", @everyone, reply privately, invite
// links, and communities.
//
// Adding someone always happens here in an admin's browser: only a member
// can wrap the group's encryption key for the newcomer.

import { app, icon, openModal, whenText } from './core.js';
import { deriveWrapKey, wrapContentKey } from '../crypto.js';

const isAdminRole = (r) => r === 'owner' || r === 'admin';
const myRole = (convo) => convo?.myRole || 'member';
export const iAmGroupAdmin = (convo) => convo?.kind === 'group' && isAdminRole(myRole(convo));

function inviteUrl(code) {
  return `${location.origin}${location.pathname}#join=${code}`;
}

/** Wraps the group key for each user ({id, publicKey}) and adds them. */
export async function addMembersWithKey(convo, users) {
  const contentKey = await app.keyFor(convo);
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', contentKey));
  for (const u of users) {
    if (!u.publicKey) continue;
    const wrapKey = await deriveWrapKey(app.state.privateKey, u.publicKey);
    const { wrappedKey, wrappedIv } = await wrapContentKey(wrapKey, raw);
    await app.api(`/api/conversations/${convo.id}/members`, {
      method: 'POST', body: JSON.stringify({ userId: u.id, wrappedKey, wrappedIv }),
    });
  }
}

// ── Composer lock for admin-only groups ──────────────────────

export function renderComposerLock() {
  const convo = app.state.conversations.get(app.state.activeId);
  const locked = convo?.kind === 'group' && convo.onlyAdminsSend && !iAmGroupAdmin(convo);
  let bar = document.getElementById('admins-only-bar');
  const composer = document.querySelector('.composer');
  composer?.classList.toggle('hidden', locked);
  if (!locked) { bar?.remove(); return; }
  if (!bar) {
    bar = document.createElement('div');
    bar.id = 'admins-only-bar';
    bar.className = 'admins-only-bar';
    composer?.parentElement?.insertBefore(bar, composer);
  }
  bar.innerHTML = `${icon('megaphone')}<span>${convo.isAnnouncement
    ? 'Only community admins can post announcements.'
    : 'Only admins can send messages in this group.'}</span>`;
}

// ── Group info panel ─────────────────────────────────────────

export async function openGroupInfo() {
  const convo = app.state.conversations.get(app.state.activeId);
  if (!convo || convo.kind !== 'group') return;
  let members;
  try {
    ({ members } = await app.api(`/api/conversations/${convo.id}/members`));
    app.state.groupMembers.set(convo.id, members);
  } catch (err) {
    app.toast(err.message, true);
    return;
  }
  const me = members.find((m) => m.id === app.state.me.id);
  convo.myRole = me?.role || 'member';
  const admin = isAdminRole(convo.myRole);
  const owner = convo.myRole === 'owner';
  const { escapeHtml, escapeAttr, avatarInner } = app;

  const { box, close } = openModal(`
    <div class="ginfo-head">
      <div class="avatar ginfo-avatar" style="background:${escapeAttr(convo.avatarColor)}">${avatarInner({ displayName: convo.title })}</div>
      <div class="ginfo-title" id="ginfo-title">${escapeHtml(convo.title)}</div>
      <div class="ginfo-sub">Group · ${members.length} member${members.length === 1 ? '' : 's'}${convo.isAnnouncement ? ' · Community announcements' : ''}</div>
      <div class="ginfo-desc ${convo.description ? '' : 'empty'}" id="ginfo-desc">${convo.description ? app.linkify(escapeHtml(convo.description)) : (admin ? 'Add a group description' : '')}</div>
      ${admin ? `<button type="button" class="btn-secondary ginfo-edit" id="ginfo-edit">${icon('edit')} Edit name &amp; description</button>` : ''}
    </div>

    ${admin ? `
    <div class="ginfo-section">
      <div class="ginfo-section-title">Group settings</div>
      <label class="toggle-row">
        <span><span class="toggle-title">Only admins can send messages</span>
        <span class="toggle-sub">Members can still read, react and vote</span></span>
        <input type="checkbox" class="switch" id="ginfo-only-admins" ${convo.onlyAdminsSend ? 'checked' : ''} ${convo.isAnnouncement ? 'disabled' : ''}>
      </label>
      <div class="ginfo-invite" id="ginfo-invite"></div>
    </div>
    <div class="ginfo-section hidden" id="ginfo-requests-wrap">
      <div class="ginfo-section-title">Asking to join <span class="ginfo-count" id="ginfo-req-count"></span></div>
      <div id="ginfo-requests"></div>
    </div>` : ''}

    <div class="ginfo-section">
      <div class="ginfo-section-title">${members.length} members
        ${admin ? `<button type="button" class="link-btn" id="ginfo-add">${icon('plus')} Add members</button>` : ''}</div>
      <div class="ginfo-members">
        ${members.map((m) => `
          <div class="ginfo-member" data-user="${escapeAttr(m.id)}">
            <div class="avatar sm" style="background:${escapeAttr(m.avatarColor)}">${avatarInner(m)}</div>
            <div class="ginfo-member-main">
              <div class="ginfo-member-name">${escapeHtml(m.displayName)}${m.id === app.state.me.id ? ' <span class="muted">(you)</span>' : ''}</div>
              <div class="ginfo-member-sub">@${escapeHtml(m.username)}</div>
            </div>
            ${m.role !== 'member' ? `<span class="role-tag ${m.role}">${m.role === 'owner' ? 'Owner' : 'Admin'}</span>` : ''}
            ${m.id !== app.state.me.id ? `<button type="button" class="icon-btn ginfo-more" data-user="${escapeAttr(m.id)}" aria-label="More">⋮</button>` : ''}
          </div>`).join('')}
      </div>
    </div>

    <div class="modal-actions">
      <button type="button" class="btn-danger-soft" id="ginfo-leave">Leave group</button>
      <button type="button" class="btn-primary" data-close>Done</button>
    </div>`, { cardClass: 'feature-card ginfo-card' });

  box.querySelector('[data-close]').addEventListener('click', close);

  box.querySelector('#ginfo-leave').addEventListener('click', async () => {
    const note = owner ? '\n\nYou’re the owner — the group passes to an admin (or the longest member).' : '';
    if (!confirm(`Leave "${convo.title}"?${note}`)) return;
    try {
      await app.api(`/api/conversations/${convo.id}/members/${app.state.me.id}`, { method: 'DELETE' });
      close();
      dropConversation(convo.id);
    } catch (err) { app.toast(err.message, true); }
  });

  box.querySelector('#ginfo-edit')?.addEventListener('click', () => { close(); openEditGroup(convo); });
  box.querySelector('#ginfo-add')?.addEventListener('click', () => { close(); app.openAddMember(convo, members); });

  box.querySelector('#ginfo-only-admins')?.addEventListener('change', async (e) => {
    try {
      await saveSettings(convo, { onlyAdminsSend: e.target.checked });
      app.toast(e.target.checked ? 'Only admins can send messages now.' : 'Everyone can send messages now.');
    } catch (err) { e.target.checked = !e.target.checked; app.toast(err.message, true); }
  });

  // Member menu: message / make admin / remove.
  box.querySelectorAll('.ginfo-more').forEach((btn) => btn.addEventListener('click', (e) => {
    e.stopPropagation();
    const m = members.find((x) => x.id === btn.dataset.user);
    const items = [{ label: `Message ${m.displayName}`, act: 'message' }];
    if (owner && m.role === 'member') items.push({ label: 'Make group admin', act: 'promote' });
    if (owner && m.role === 'admin') items.push({ label: 'Dismiss as admin', act: 'demote' });
    if (admin && m.role !== 'owner' && (owner || m.role === 'member')) items.push({ label: `Remove ${m.displayName}`, act: 'remove', danger: true });
    popMenu(btn, items, async (act) => {
      try {
        if (act === 'message') { close(); await app.startChatWith(m.id); return; }
        if (act === 'remove') {
          if (!confirm(`Remove ${m.displayName} from "${convo.title}"?`)) return;
          await app.api(`/api/conversations/${convo.id}/members/${m.id}`, { method: 'DELETE' });
        } else {
          await app.api(`/api/conversations/${convo.id}/members/${m.id}/role`, {
            method: 'PATCH', body: JSON.stringify({ role: act === 'promote' ? 'admin' : 'member' }),
          });
        }
        close();
        openGroupInfo();
      } catch (err) { app.toast(err.message, true); }
    });
  }));

  if (admin) {
    drawInvite(box.querySelector('#ginfo-invite'), convo);
    loadRequests(box, convo);
  }
}

function popMenu(anchor, items, onPick) {
  document.querySelector('.pop-menu')?.remove();
  const menu = document.createElement('div');
  menu.className = 'pop-menu';
  menu.innerHTML = items.map((it) => `<button type="button" data-act="${it.act}" class="${it.danger ? 'danger' : ''}">${app.escapeHtml(it.label)}</button>`).join('');
  document.body.appendChild(menu);
  const r = anchor.getBoundingClientRect();
  const w = menu.offsetWidth;
  menu.style.top = `${Math.min(r.bottom + 4, innerHeight - menu.offsetHeight - 8)}px`;
  menu.style.left = `${Math.max(8, Math.min(r.right - w, innerWidth - w - 8))}px`;
  const off = () => { menu.remove(); document.removeEventListener('click', off, true); };
  setTimeout(() => document.addEventListener('click', off, true));
  menu.addEventListener('click', (e) => {
    const act = e.target.closest('button')?.dataset.act;
    if (act) { off(); onPick(act); }
  });
}

async function saveSettings(convo, patch) {
  const res = await app.api(`/api/conversations/${convo.id}/group-settings`, { method: 'PATCH', body: JSON.stringify(patch) });
  Object.assign(convo, res);
  app.renderChatList();
  if (app.state.activeId === convo.id) {
    app.$('peer-name').textContent = convo.title;
    renderComposerLock();
  }
  return res;
}

function openEditGroup(convo) {
  const { box, close } = openModal(`
    <h3>Edit group</h3>
    <div class="field"><label>Group name</label><input id="eg-title" maxlength="80" value="${app.escapeAttr(convo.title)}"></div>
    <div class="field"><label>Description</label><textarea id="eg-desc" rows="4" maxlength="500" placeholder="What's this group about?">${app.escapeHtml(convo.description || '')}</textarea></div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="eg-save">Save</button>
    </div>`);
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#eg-save').addEventListener('click', async () => {
    try {
      await saveSettings(convo, { title: box.querySelector('#eg-title').value, description: box.querySelector('#eg-desc').value });
      close();
      app.toast('Group updated.');
      openGroupInfo();
    } catch (err) { app.toast(err.message, true); }
  });
  box.querySelector('#eg-title').focus();
}

function drawInvite(el, convo) {
  if (!convo.inviteCode) {
    el.innerHTML = `
      <div class="ginfo-invite-row">
        <div class="ginfo-invite-icon">${icon('link')}</div>
        <div class="ginfo-invite-main"><div class="toggle-title">Invite link</div>
          <div class="toggle-sub">Anyone with the link can ask to join — an admin approves</div></div>
        <button type="button" class="btn-secondary" id="inv-make">Create link</button>
      </div>`;
    el.querySelector('#inv-make').addEventListener('click', async () => {
      try {
        convo.inviteCode = (await app.api(`/api/conversations/${convo.id}/invite`, { method: 'POST' })).inviteCode;
        drawInvite(el, convo);
      } catch (err) { app.toast(err.message, true); }
    });
    return;
  }
  const url = inviteUrl(convo.inviteCode);
  el.innerHTML = `
    <div class="ginfo-invite-row">
      <div class="ginfo-invite-icon on">${icon('link')}</div>
      <div class="ginfo-invite-main"><div class="toggle-title">Invite link</div>
        <div class="invite-url" title="${app.escapeAttr(url)}">${app.escapeHtml(url)}</div></div>
    </div>
    <div class="invite-actions">
      <button type="button" class="btn-secondary" id="inv-copy">${icon('copy')} Copy</button>
      <button type="button" class="btn-secondary" id="inv-reset">Reset link</button>
      <button type="button" class="btn-secondary" id="inv-off">Turn off</button>
    </div>`;
  el.querySelector('#inv-copy').addEventListener('click', async () => {
    await navigator.clipboard.writeText(url).catch(() => {});
    app.toast('Invite link copied.');
  });
  el.querySelector('#inv-reset').addEventListener('click', async () => {
    if (!confirm('Make a new link? The current one stops working.')) return;
    convo.inviteCode = (await app.api(`/api/conversations/${convo.id}/invite`, { method: 'POST' })).inviteCode;
    drawInvite(el, convo);
  });
  el.querySelector('#inv-off').addEventListener('click', async () => {
    await app.api(`/api/conversations/${convo.id}/invite`, { method: 'DELETE' });
    convo.inviteCode = null;
    drawInvite(el, convo);
  });
}

async function loadRequests(box, convo) {
  const wrap = box.querySelector('#ginfo-requests-wrap');
  const list = box.querySelector('#ginfo-requests');
  let requests = [];
  try { ({ requests } = await app.api(`/api/conversations/${convo.id}/join-requests`)); } catch { return; }
  convo.joinRequests = requests.length;
  app.renderChatList();
  wrap.classList.toggle('hidden', !requests.length);
  box.querySelector('#ginfo-req-count').textContent = requests.length;
  list.innerHTML = requests.map((u) => `
    <div class="ginfo-member" data-user="${app.escapeAttr(u.id)}">
      <div class="avatar sm" style="background:${app.escapeAttr(u.avatarColor)}">${app.avatarInner(u)}</div>
      <div class="ginfo-member-main">
        <div class="ginfo-member-name">${app.escapeHtml(u.displayName)}</div>
        <div class="ginfo-member-sub">@${app.escapeHtml(u.username)} · ${whenText(u.requestedAt)}</div>
      </div>
      <button type="button" class="btn-secondary req-decline">Decline</button>
      <button type="button" class="btn-primary req-approve">Approve</button>
    </div>`).join('');
  list.querySelectorAll('.ginfo-member').forEach((row) => {
    const u = requests.find((x) => x.id === row.dataset.user);
    row.querySelector('.req-approve').addEventListener('click', async (e) => {
      e.target.disabled = true;
      try {
        await addMembersWithKey(convo, [u]);
        app.toast(`${u.displayName} joined the group.`);
        row.remove();
      } catch (err) { app.toast(err.message, true); e.target.disabled = false; }
    });
    row.querySelector('.req-decline').addEventListener('click', async () => {
      await app.api(`/api/conversations/${convo.id}/join-requests/${u.id}/decline`, { method: 'POST' }).catch(() => {});
      row.remove();
    });
  });
}

function dropConversation(id) {
  const s = app.state;
  s.conversations.delete(id);
  s.groupMembers.delete(id);
  s.keys.delete(id);
  s.messages.delete(id);
  if (s.activeId === id) {
    s.activeId = null;
    app.$('chat-pane').classList.add('hidden');
    app.$('no-chat').classList.remove('hidden');
  }
  app.renderChatList();
}

// ── Joining with an invite link ──────────────────────────────

export function codeFromLink(text) {
  const t = String(text || '').trim();
  const m = t.match(/[#?&]join=([A-Za-z0-9_-]{6,40})/) || t.match(/^([A-Za-z0-9_-]{6,40})$/);
  return m ? m[1] : null;
}

export async function openJoinPreview(code) {
  let group;
  try { ({ group } = await app.api(`/api/invite/${encodeURIComponent(code)}`)); } catch (err) {
    app.toast(err.message, true);
    return;
  }
  const { box, close } = openModal(`
    <div class="ginfo-head">
      <div class="avatar ginfo-avatar" style="background:${app.escapeAttr(group.avatarColor)}">${app.avatarInner({ displayName: group.title })}</div>
      <div class="ginfo-title">${app.escapeHtml(group.title)}</div>
      <div class="ginfo-sub">Group · ${group.memberCount} members</div>
      ${group.description ? `<div class="ginfo-desc">${app.escapeHtml(group.description)}</div>` : ''}
    </div>
    <p class="join-note">${group.isMember ? 'You’re already in this group.'
      : group.requested ? 'Your request was sent — an admin will let you in.'
      : 'An admin approves new members. You’ll get the group in your chats once they do.'}</p>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Close</button>
      ${group.isMember ? '<button type="button" class="btn-primary" id="jp-open">Open group</button>'
        : group.requested ? '<button type="button" class="btn-secondary" id="jp-cancel">Cancel request</button>'
        : '<button type="button" class="btn-primary" id="jp-ask">Ask to join</button>'}
    </div>`, { cardClass: 'feature-card' });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#jp-open')?.addEventListener('click', () => { close(); app.openConversation(group.id); });
  box.querySelector('#jp-ask')?.addEventListener('click', async () => {
    try {
      await app.api(`/api/invite/${encodeURIComponent(code)}/request`, { method: 'POST' });
      close();
      app.toast('Request sent — you’ll be added when an admin approves.');
    } catch (err) { app.toast(err.message, true); }
  });
  box.querySelector('#jp-cancel')?.addEventListener('click', async () => {
    await app.api(`/api/conversations/${group.id}/join-request`, { method: 'DELETE' }).catch(() => {});
    close();
    app.toast('Request cancelled.');
  });
}

/** "#join=CODE" in the address bar (someone opened an invite link). */
export function checkInviteHash() {
  const code = codeFromLink(location.hash);
  if (!code) return;
  history.replaceState(null, '', location.pathname + location.search);
  openJoinPreview(code);
}

export function openJoinWithLink() {
  const { box, close } = openModal(`
    <h3>Join a group with a link</h3>
    <div class="field"><label>Invite link</label><input id="jl-link" placeholder="Paste the link here"></div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="jl-go">Continue</button>
    </div>`);
  box.querySelector('[data-close]').addEventListener('click', close);
  const go = () => {
    const code = codeFromLink(box.querySelector('#jl-link').value);
    if (!code) { app.toast('That doesn’t look like an invite link.', true); return; }
    close();
    openJoinPreview(code);
  };
  box.querySelector('#jl-go').addEventListener('click', go);
  box.querySelector('#jl-link').addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
  box.querySelector('#jl-link').focus();
}

// ── @everyone ────────────────────────────────────────────────

const EVERYONE_RE = /(^|\s)@everyone\b/i;
export const mentionsEveryone = (text) => EVERYONE_RE.test(text || '');

/** Highlights "@everyone" in already-escaped message html. */
export function highlightEveryone(html, m) {
  if (!m?.mentionAll) return html;
  return html.replace(/(^|\s)@everyone\b/gi, '$1<span class="mention-all">@everyone</span>');
}

/** Composer suggestion: typing "@" in a group I admin offers "@everyone". */
export function onComposerMention(input) {
  const convo = app.state.conversations.get(app.state.activeId);
  let pop = document.getElementById('mention-pop');
  const word = input.value.slice(0, input.selectionStart).match(/(?:^|\s)@(\w*)$/);
  const show = word && iAmGroupAdmin(convo) && 'everyone'.startsWith(word[1].toLowerCase());
  if (!show) { pop?.remove(); return; }
  if (!pop) {
    pop = document.createElement('div');
    pop.id = 'mention-pop';
    pop.className = 'mention-pop';
    input.closest('.composer')?.appendChild(pop);
  }
  pop.innerHTML = `<button type="button">${icon('megaphone')}<span><b>@everyone</b><small>Notify all ${convo.memberCount} members, even if they muted the chat</small></span></button>`;
  pop.querySelector('button').onmousedown = (e) => {
    e.preventDefault();
    const before = input.value.slice(0, input.selectionStart).replace(/@\w*$/, '@everyone ');
    input.value = before + input.value.slice(input.selectionStart);
    input.setSelectionRange(before.length, before.length);
    input.dispatchEvent(new Event('input'));
    pop.remove();
  };
}

// ── Reply privately ──────────────────────────────────────────

const PR = '⁣PR';
const END = '⁣';
let pendingQuote = null; // {conversationId, quote}

export function splitPrivateReply(plain) {
  if (typeof plain !== 'string' || !plain.startsWith(PR)) return null;
  const end = plain.indexOf(END, PR.length);
  if (end < 0) return null;
  try { return { quote: JSON.parse(plain.slice(PR.length, end)), text: plain.slice(end + 1) }; } catch { return null; }
}

/** Plain text of a message, without a private-reply quote. */
export const textOf = (plain) => splitPrivateReply(plain)?.text ?? plain;

export function privateQuoteHtml(quote) {
  return `
    <div class="private-quote">
      <div class="private-quote-head">${icon('lock')} ${app.escapeHtml(quote.sender)} · ${app.escapeHtml(quote.group)}</div>
      <div class="private-quote-text">${app.escapeHtml(quote.snippet)}</div>
    </div>`;
}

export function privateReplyButtonHtml(m, convo, mine) {
  if (mine || convo?.kind !== 'group' || m.pending || m.deleted) return '';
  return `<button type="button" class="bubble-action-btn private-reply-btn" data-msg="${app.escapeAttr(m.id)}" title="Reply privately">${icon('lock')}</button>`;
}

export async function replyPrivately(msgId) {
  const groupConvo = app.state.conversations.get(app.state.activeId);
  const m = (app.state.messages.get(app.state.activeId) || []).find((x) => x.id === msgId);
  if (!m || !groupConvo) return;
  const quote = {
    group: groupConvo.title,
    groupId: groupConvo.id,
    sender: app.senderInfo(groupConvo, m.senderId).displayName,
    snippet: textOf(app.previewFor(m)).slice(0, 200),
  };
  await app.startChatWith(m.senderId);
  pendingQuote = { conversationId: app.state.activeId, quote };
  drawPendingQuote();
  app.$('composer-input')?.focus();
}

function drawPendingQuote() {
  let bar = document.getElementById('private-quote-bar');
  const composer = document.querySelector('.composer');
  if (!pendingQuote || pendingQuote.conversationId !== app.state.activeId) { bar?.remove(); return; }
  if (!bar) {
    bar = document.createElement('div');
    bar.id = 'private-quote-bar';
    bar.className = 'private-quote-bar';
    composer?.parentElement?.insertBefore(bar, composer);
  }
  bar.innerHTML = `${privateQuoteHtml(pendingQuote.quote)}<button type="button" class="icon-btn" aria-label="Cancel">${icon('close')}</button>`;
  bar.querySelector('button').onclick = () => { pendingQuote = null; bar.remove(); };
}

/** Called by sendMessage: adds the pending quote to the text being sent. */
export function packPrivateReply(conversationId, text) {
  if (!pendingQuote || pendingQuote.conversationId !== conversationId) return text;
  const packed = PR + JSON.stringify(pendingQuote.quote) + END + text;
  pendingQuote = null;
  document.getElementById('private-quote-bar')?.remove();
  return packed;
}

export function onChatOpened() {
  renderComposerLock();
  drawPendingQuote();
  document.getElementById('mention-pop')?.remove();
}

// ── Communities ──────────────────────────────────────────────

export async function openCommunities() {
  const { box, close } = openModal(`
    <div class="feature-hero">
      <div class="feature-hero-icon">${icon('community')}</div>
      <h3>Communities</h3>
      <p>Bring related groups together, with an announcements group only admins post in.</p>
    </div>
    <div class="community-list" id="community-list"><div class="ai-loading"><span></span><span></span><span></span> Loading…</div></div>
    <div class="modal-actions">
      <button type="button" class="btn-secondary" data-close>Close</button>
      <button type="button" class="btn-primary" id="comm-new">${icon('plus')} New community</button>
    </div>`, { cardClass: 'feature-card community-card-modal' });
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#comm-new').addEventListener('click', () => { close(); openCreateCommunity(); });
  const list = box.querySelector('#community-list');

  const draw = async () => {
    let communities;
    try { ({ communities } = await app.api('/api/communities')); } catch (err) {
      list.innerHTML = `<div class="ai-error">${app.escapeHtml(err.message)}</div>`;
      return;
    }
    if (!communities.length) {
      list.innerHTML = '<div class="ai-empty">You’re not in any community yet.</div>';
      return;
    }
    list.innerHTML = communities.map((c) => `
      <div class="community" data-id="${app.escapeAttr(c.id)}">
        <div class="community-head">
          <div class="avatar community-avatar" style="background:${app.escapeAttr(c.avatarColor)}">${app.avatarInner({ displayName: c.name })}</div>
          <div class="community-main">
            <div class="community-name">${app.escapeHtml(c.name)}</div>
            <div class="community-sub">${c.groups.length} group${c.groups.length === 1 ? '' : 's'}${c.description ? ' · ' + app.escapeHtml(c.description) : ''}</div>
          </div>
          ${c.isAdmin ? `<button type="button" class="icon-btn comm-more" aria-label="Manage">⋮</button>` : ''}
        </div>
        <div class="community-groups">
          ${c.groups.map((g) => `
            <div class="community-group ${g.isAnnouncement ? 'ann' : ''}" data-gid="${app.escapeAttr(g.id)}">
              <div class="avatar sm" style="background:${app.escapeAttr(g.avatarColor)}">${g.isAnnouncement ? icon('megaphone') : app.avatarInner({ displayName: g.title })}</div>
              <div class="community-group-main">
                <div class="community-group-name">${g.isAnnouncement ? 'Announcements' : app.escapeHtml(g.title)}</div>
                <div class="community-group-sub">${g.memberCount} members</div>
              </div>
              ${g.isMember ? '<button type="button" class="btn-secondary g-open">Open</button>'
                : g.requested ? '<span class="g-requested">Requested</span>'
                : '<button type="button" class="btn-secondary g-ask">Ask to join</button>'}
            </div>`).join('')}
        </div>
      </div>`).join('');

    list.querySelectorAll('.community').forEach((el) => {
      const c = communities.find((x) => x.id === el.dataset.id);
      el.querySelectorAll('.community-group').forEach((row) => {
        const gid = row.dataset.gid;
        row.querySelector('.g-open')?.addEventListener('click', () => { close(); app.openConversation(gid); });
        row.querySelector('.g-ask')?.addEventListener('click', async () => {
          try {
            await app.api(`/api/conversations/${gid}/join-request`, { method: 'POST' });
            app.toast('Request sent to the group’s admins.');
            draw();
          } catch (err) { app.toast(err.message, true); }
        });
      });
      el.querySelector('.comm-more')?.addEventListener('click', (e) => {
        e.stopPropagation();
        popMenu(e.currentTarget, [
          { label: 'Add a group', act: 'link' },
          { label: 'Add everyone to announcements', act: 'sync' },
          { label: 'Rename', act: 'rename' },
          { label: 'Delete community', act: 'delete', danger: true },
        ], async (act) => {
          try {
            if (act === 'link') await linkGroup(c);
            if (act === 'sync') await syncAnnouncements(c, true);
            if (act === 'rename') {
              const name = prompt('Community name', c.name);
              if (!name) return;
              await app.api(`/api/communities/${c.id}`, { method: 'PATCH', body: JSON.stringify({ name, description: c.description }) });
            }
            if (act === 'delete') {
              if (!confirm(`Delete the community "${c.name}"? Its groups carry on as ordinary groups.`)) return;
              await app.api(`/api/communities/${c.id}`, { method: 'DELETE' });
            }
            draw();
          } catch (err) { app.toast(err.message, true); }
        });
      });
      // Admins keep the announcements group in step with the community.
      if (c.isAdmin) syncAnnouncements(c, false);
    });
  };
  draw();
}

/** Adds everyone from the community's groups to its announcements group. */
async function syncAnnouncements(c, loud) {
  const { announcementId, members } = await app.api(`/api/communities/${c.id}/missing-members`);
  const ann = app.state.conversations.get(announcementId);
  if (!ann || !members.length) {
    if (loud) app.toast('Everyone is already in the announcements group.');
    return;
  }
  await addMembersWithKey(ann, members);
  if (loud) app.toast(`Added ${members.length} ${members.length === 1 ? 'person' : 'people'} to announcements.`);
}

async function linkGroup(c) {
  const linked = new Set(c.groups.map((g) => g.id));
  const mine = [...app.state.conversations.values()].filter((v) => v.kind === 'group' && iAmGroupAdmin(v) && !linked.has(v.id) && !v.communityId);
  if (!mine.length) { app.toast('You have no other groups you admin to add.', true); return; }
  return new Promise((resolve) => {
    const { box, close } = openModal(`
      <h3>Add a group to ${app.escapeHtml(c.name)}</h3>
      <div class="picker-list">${mine.map((g) => `
        <label class="picker-row"><input type="radio" name="lg" value="${app.escapeAttr(g.id)}">
          <div class="avatar sm" style="background:${app.escapeAttr(g.avatarColor)}">${app.avatarInner({ displayName: g.title })}</div>
          <span class="name">${app.escapeHtml(g.title)}</span></label>`).join('')}</div>
      <div class="modal-actions"><button type="button" class="btn-secondary" data-close>Cancel</button>
        <button type="button" class="btn-primary" id="lg-go">Add</button></div>`);
    box.querySelector('[data-close]').addEventListener('click', () => { close(); resolve(); });
    box.querySelector('#lg-go').addEventListener('click', async () => {
      const gid = box.querySelector('input:checked')?.value;
      if (!gid) return;
      try {
        await app.api(`/api/communities/${c.id}/groups`, { method: 'POST', body: JSON.stringify({ conversationId: gid }) });
        close();
        await app.loadConversations();
        await syncAnnouncements(c, false).catch(() => {});
        app.toast('Group added to the community.');
      } catch (err) { app.toast(err.message, true); }
      resolve();
    });
  });
}

function openCreateCommunity() {
  const contacts = app.directContacts();
  const groups = [...app.state.conversations.values()].filter((v) => v.kind === 'group' && iAmGroupAdmin(v) && !v.communityId);
  const { box, close } = openModal(`
    <h3>New community</h3>
    <div class="field"><label>Name</label><input id="cc-name" maxlength="80" placeholder="Rocket Club"></div>
    <div class="field"><label>Description</label><input id="cc-desc" maxlength="500" placeholder="What brings everyone together?"></div>
    <div class="field"><label>Groups to include</label>
      <div class="picker-list">${groups.length ? groups.map((g) => `
        <label class="picker-row"><input type="checkbox" value="${app.escapeAttr(g.id)}">
          <div class="avatar sm" style="background:${app.escapeAttr(g.avatarColor)}">${app.avatarInner({ displayName: g.title })}</div>
          <span class="name">${app.escapeHtml(g.title)}</span></label>`).join('')
        : '<div class="ai-empty">No groups you admin yet — you can add groups later.</div>'}</div>
    </div>
    <p class="join-note">An “Announcements” group is created for the community — everyone in its groups is added, and only admins can post.</p>
    <div class="modal-actions"><button type="button" class="btn-secondary" data-close>Cancel</button>
      <button type="button" class="btn-primary" id="cc-go">Create</button></div>`);
  box.querySelector('[data-close]').addEventListener('click', close);
  box.querySelector('#cc-name').focus();
  box.querySelector('#cc-go').addEventListener('click', async (e) => {
    const name = box.querySelector('#cc-name').value.trim();
    if (!name) { app.toast('Give the community a name.', true); return; }
    const groupIds = [...box.querySelectorAll('input:checked')].map((i) => i.value);
    e.target.disabled = true;
    e.target.textContent = 'Creating…';
    try {
      // Announcements starts with just me; the sync below adds everyone else.
      const ann = await app.createGroup(`${name} · Announcements`, [], contacts);
      const { community } = await app.api('/api/communities', {
        method: 'POST',
        body: JSON.stringify({ name, description: box.querySelector('#cc-desc').value, announcementConversationId: ann.id, groupIds }),
      });
      await app.loadConversations();
      await syncAnnouncements({ id: community.id }, false).catch(() => {});
      close();
      app.toast(`Community “${name}” created.`);
      openCommunities();
    } catch (err) {
      app.toast(err.message, true);
      e.target.disabled = false;
      e.target.textContent = 'Create';
    }
  });
}

// ── Live frames ──────────────────────────────────────────────

export function onGroupFrame(frame) {
  const s = app.state;
  const convo = s.conversations.get(frame.conversationId);
  switch (frame.type) {
    case 'group-updated':
      if (convo) {
        Object.assign(convo, { title: frame.title, description: frame.description, onlyAdminsSend: frame.onlyAdminsSend });
        app.renderChatList();
        if (s.activeId === convo.id) { app.$('peer-name').textContent = convo.title; renderComposerLock(); }
      }
      return true;
    case 'members-changed':
      s.groupMembers.delete(frame.conversationId);
      app.loadConversations().then(() => { if (s.activeId === frame.conversationId) renderComposerLock(); });
      return true;
    case 'join-request':
      if (convo) {
        convo.joinRequests = (convo.joinRequests || 0) + 1;
        app.renderChatList();
        app.toast(`${frame.user.displayName} asked to join “${convo.title}”. Open group info to approve.`);
      }
      return true;
    case 'join-declined':
      app.toast(`Your request to join “${frame.title}” was declined.`, true);
      return true;
    case 'group-joined':
      app.loadConversations().then(() => {
        const c = s.conversations.get(frame.conversationId);
        if (c) app.toast(`You’ve been added to “${c.title}”.`);
      });
      return true;
    case 'group-left':
      if (convo) { dropConversation(frame.conversationId); app.toast(`You’re no longer in “${convo.title}”.`); }
      return true;
    case 'communities-changed':
      app.loadConversations();
      return true;
    default:
      return false;
  }
}
