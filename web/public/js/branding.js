// App name + logo, as the owner set them in the admin app. Applied to the
// title, icons, install manifest and the sign-in / lock screens. Falls back
// to the built-in name and artwork if the API is unreachable or nothing is set.
const cfg = window.APP_CONFIG || {};
const apiBase = (() => {
  if (cfg.apiBase) return cfg.apiBase.replace(/\/+$/, '');
  if (cfg.sameOrigin) return location.origin;
  const https = location.protocol === 'https:';
  return `${location.protocol}//${location.hostname}:${https ? (cfg.apiHttpsPort ?? 4443) : (cfg.apiHttpPort ?? 4000)}`;
})();
const KEY = 'app-brand';
const DEFAULT = { name: 'Veyon Chat', logoUrl: null };

window.APP_BRAND = { ...DEFAULT };

const marks = [...document.querySelectorAll('.auth-visual-mark, .brand-mark, .brand-mark-sm')];
const markHtml = marks.map((m) => m.innerHTML);
const iconHref = ['link[rel="icon"]', 'link[rel="apple-touch-icon"]'].map((sel) => document.querySelector(sel)?.getAttribute('href'));

function apply(b) {
  const logo = b.logoUrl ? apiBase + b.logoUrl : null;
  window.APP_BRAND = { name: b.name, logoUrl: logo };
  document.title = `${b.name} — Private Messaging`;
  document.querySelector('meta[name="apple-mobile-web-app-title"]')?.setAttribute('content', b.name);
  document.querySelectorAll('.auth-visual-wordmark, .auth-card-brand-sm span, .welcome-brand span').forEach((e) => { e.textContent = b.name; });
  marks.forEach((m, i) => {
    if (logo) {
      m.replaceChildren(Object.assign(document.createElement('img'), { src: logo, alt: '' }));
    } else {
      m.innerHTML = markHtml[i];
    }
    m.classList.toggle('has-logo', !!logo);
  });
  ['link[rel="icon"]', 'link[rel="apple-touch-icon"]'].forEach((sel, i) => {
    const link = document.querySelector(sel);
    if (link && (logo || iconHref[i])) link.setAttribute('href', logo || iconHref[i]);
  });
  setManifest(b, logo);
}

// The manifest is rebuilt in the page (not served by the API) so its
// start_url/scope stay on the website's own origin.
async function setManifest(b, logo) {
  try {
    const m = await (await fetch('/manifest.json')).json();
    m.name = b.name;
    m.short_name = b.name.slice(0, 12);
    m.start_url = location.origin + '/';
    m.scope = location.origin + '/';
    m.icons = logo ? [{ src: logo, sizes: '512x512', purpose: 'any' }]
                   : m.icons.map((i) => ({ ...i, src: location.origin + i.src }));
    const url = URL.createObjectURL(new Blob([JSON.stringify(m)], { type: 'application/manifest+json' }));
    document.querySelector('link[rel="manifest"]')?.setAttribute('href', url);
  } catch { /* keep the static manifest */ }
}

let cached = null;
try { cached = JSON.parse(localStorage.getItem(KEY)); } catch { /* ignore */ }
const ready = () => new Promise((r) => (document.readyState === 'loading'
  ? document.addEventListener('DOMContentLoaded', r, { once: true }) : r()));

await ready();
if (cached?.name) apply(cached);   // instant, from the last visit

// Live: re-check every 15 s and whenever the tab comes back, so a change made
// in the admin shows up here without a reload.
let shownVersion = cached?.v ?? -1;
async function refresh() {
  try {
    const res = await fetch(apiBase + '/api/branding', { cache: 'no-cache' });
    if (!res.ok) return;
    const b = await res.json();
    if (b.v === shownVersion && cached?.name) return;
    shownVersion = b.v;
    cached = b;
    localStorage.setItem(KEY, JSON.stringify(b));
    apply(b);
  } catch { /* offline — keep what is shown */ }
}
await refresh();
setInterval(refresh, 15000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
