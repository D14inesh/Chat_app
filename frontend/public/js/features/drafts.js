// Message drafts — a half-typed message stays in its chat when you switch
// away, and the chat list shows "Draft: …" until it's sent or cleared.
// Kept on this device only (drafts are never uploaded).

import { app } from './core.js';

const KEY = 'veyon.drafts';
let drafts = load();
let saveTimer = null;

function load() {
  try { return JSON.parse(localStorage.getItem(KEY) || '{}'); } catch { return {}; }
}

function persist() {
  try { localStorage.setItem(KEY, JSON.stringify(drafts)); } catch { /* storage blocked */ }
}

export function getDraft(conversationId) {
  return drafts[conversationId] || '';
}

export function setDraft(conversationId, text) {
  if (!conversationId) return;
  const had = Boolean(drafts[conversationId]);
  if (text.trim()) drafts[conversationId] = text;
  else delete drafts[conversationId];
  clearTimeout(saveTimer);
  saveTimer = setTimeout(persist, 300);
  if (had !== Boolean(drafts[conversationId])) app.renderChatList();
}

export function clearDraft(conversationId) {
  if (!drafts[conversationId]) return;
  delete drafts[conversationId];
  persist();
}

/** Chat-list preview for a chat with a draft (not the open one). */
export function draftPreviewHtml(convo) {
  if (convo.id === app.state.activeId) return null;
  const text = drafts[convo.id];
  if (!text) return null;
  return `<span class="draft-label">Draft:</span> ${app.escapeHtml(text.replace(/\s+/g, ' ').slice(0, 80))}`;
}
