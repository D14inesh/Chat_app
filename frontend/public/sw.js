/**
 * Reminders' Web Push service worker.
 *
 * This is what makes a reminder notification arrive even with the browser
 * fully closed — a plain WebSocket push (like the rest of the app uses for
 * live chat) only reaches a tab that's actually open. A push event instead
 * wakes this worker in the background, which is what lets it call
 * showNotification() regardless of whether any tab is open at all.
 */

// PWA app-shell cache — lets the installed app still open (to a cached
// shell) with no network, and is also what Chrome/Edge require for the
// "Install app" prompt to offer itself in the first place. Bumping
// CACHE_NAME invalidates everything below in one shot on the next deploy.
const CACHE_NAME = 'veyon-chat-shell-v7';
const FEATURE_MODULES = [
  'core', 'index', 'polls', 'pins', 'disappearing', 'viewonce', 'drafts', 'export', 'ai-tools',
  'security', 'quickreplies', 'broadcasts', 'business', 'effects', 'settings', 'games2', 'contact', 'admin', 'recovery', 'groups',
].map((name) => `/js/features/${name}.js`);
const SHELL_ASSETS = [
  '/', '/config.js', '/css/theme.css', '/css/features.css',
  '/js/app.js', '/js/crypto.js', '/js/localstore.js', '/manifest.json',
  ...FEATURE_MODULES,
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Real-time chat data (API calls, WebSocket) must never be served from
// cache — only the static shell around it. Network-first so a live server
// always wins; cache is purely the offline/first-paint fallback.
self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  // version.json must always come from the network — it's how open pages
  // learn there's a new version (see app.js "Self-update").
  if (url.origin !== self.location.origin || url.pathname.startsWith('/api/') || url.pathname === '/version.json') return;

  event.respondWith(
    fetch(request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
        return response;
      })
      .catch(() => caches.match(request).then((cached) => cached || caches.match('/')))
  );
});

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data.json();
  } catch {
    data = { title: 'Reminder', body: event.data ? event.data.text() : '' };
  }

  const title = data.title || 'Reminder';
  const options = {
    body: data.body || '',
    icon: '/icons/icon-192.png',
    badge: '/icons/icon-192.png',
    // One notification per reminder replaces itself instead of stacking if
    // delivery is ever retried (e.g. the scheduler's next tick overlaps a
    // slow push) — same reminderId always collapses to the same tag.
    tag: data.reminderId ? `reminder-${data.reminderId}` : undefined,
    data,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

// Clicking the notification focuses an already-open tab if there is one,
// rather than always spawning a new one.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ('focus' in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow('/');
      return undefined;
    })
  );
});
