import { sb, rpc } from './supabase.js';
import { state, DEFAULTS, refreshMe, canAdmin, setBal } from './state.js';
import { el, runCleanup, sleep } from './ui.js';
import { renderAuth } from './auth.js';
import { applyTheme, loadSettings } from './settings.js';
import { stopMusic } from './audio.js';

const root = document.getElementById('root');

// Jede Ansicht ist ein eigenes Modul und wird erst beim Öffnen geladen (schneller Start)
const VIEWS = {
  home: () => import('./coins.js').then((m) => m.renderHome),
  account: () => import('./coins.js').then((m) => m.renderAccount),
  games: () => import('./games/index.js').then((m) => m.renderGames),
  missions: () => import('./missions/missions.js').then((m) => m.renderMissions),
  rank: () => import('./leaderboard/leaderboard.js').then((m) => m.renderLeaderboard),
  shop: () => import('./shop/shop.js').then((m) => m.renderShop),
  profile: () => import('./profile/profile.js').then((m) => m.renderProfile),
  settings: () => import('./settings.js').then((m) => m.renderSettings),
  admin: () => import('./admin/admin.js').then((m) => m.renderAdmin),
};
const TABS = [['home', '🏠', 'Start'], ['games', '🎮', 'Spiele'], ['missions', '🎯', 'Missionen'], ['rank', '🏆', 'Rangliste'], ['shop', '🛍️', 'Shop'],
  ['profile', '👤', 'Profil'], ['account', '💰', 'Konto'], ['settings', '⚙️', 'Einstellungen']];

let rendering = false, pending = false;

function shell() {
  root.innerHTML = '';
  const top = el('div', 'top');
  const h = el('header'); h.appendChild(el('h1', null, '🪙 SpassCoin'));
  const w = el('div', 'who'); w.appendChild(el('span', null, state.me.username + (state.me.is_test ? ' (Test)' : '')));
  const o = el('button', 'sec small', 'Abmelden'); o.onclick = async () => { await sb.auth.signOut(); };
  w.appendChild(o); h.appendChild(w); top.appendChild(h);
  const nav = el('nav');
  const tabs = TABS.slice(); if (canAdmin()) tabs.push(['admin', '🛠️', 'Admin']);
  tabs.forEach(([k, ic, t]) => {
    const b = el('button', state.tab === k ? 'on' : ''); b.appendChild(el('span', null, ic)); b.appendChild(document.createTextNode(t));
    b.onclick = () => { if (k === 'profile') state.profileUser = null; navigate(k); }; nav.appendChild(b);
  });
  top.appendChild(nav); root.appendChild(top);
  const main = el('div', 'main'); root.appendChild(main); return main;
}

export async function render() {
  if (rendering) { pending = true; return; }
  rendering = true;
  try {
    do {
      pending = false; runCleanup();
      if (!state.me) { renderAuth(root, afterLogin); continue; }
      const main = shell(); main.appendChild(el('p', 'msg', 'Lade …'));
      try {
        const fn = await (VIEWS[state.tab] || VIEWS.home)();
        const box = el('div'); await fn(box);
        if (pending) continue;
        main.innerHTML = ''; main.appendChild(box);
      } catch (e) { console.error(e); main.innerHTML = ''; main.appendChild(el('p', 'msg', 'Etwas ist schiefgelaufen. Bitte neu laden.')); }
    } while (pending);
  } finally { rendering = false; }
}

export function navigate(tab, sub) {
  state.tab = tab || state.tab; state.sub = sub || null;
  try { history.replaceState(null, '', '?tab=' + state.tab + (state.sub ? '&sub=' + encodeURIComponent(state.sub) : '')); } catch (e) { /* ignore */ }
  window.scrollTo(0, 0); render();
}
state.navigate = navigate;

function startError(e) {
  console.error(e); root.innerHTML = '';
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Start fehlgeschlagen'));
  c.appendChild(el('p', null, 'Beim Starten ist ein Fehler aufgetreten: ' + ((e && e.message) || e)));
  const b = el('button', 'full', 'Neu laden'); b.onclick = () => location.reload(); c.appendChild(b); root.appendChild(c);
}
async function afterLogin(cb) {
  try {
    await refreshMe();
    if (!state.me) { renderAuth(root, afterLogin); return; }
    loadSettings();
    try { await Promise.race([rpc('race_state'), sleep(1500)]); } catch (e) { /* beendete Rennen auszahlen, Fehler egal */ }
    await refreshMe();
    readUrl(); render(); if (cb) cb();
  } catch (e) { startError(e); }
}
function readUrl() {
  const p = new URLSearchParams(location.search), t = p.get('tab');
  if (t && (VIEWS[t] || t === 'admin')) { state.tab = t; state.sub = p.get('game') || p.get('sub') || null; }
}

sb.auth.onAuthStateChange((ev) => {
  if (ev === 'SIGNED_OUT') { state.me = null; state.tab = 'home'; state.sub = null; stopMusic(); state.S = { ...DEFAULTS }; applyTheme(); render(); }
});
document.addEventListener('visibilitychange', async () => { if (!document.hidden && state.me) { await refreshMe(); setBal(); } });

// Service Worker (App-Installation, Offline-Hülle, Push)
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('service-worker.js').catch(() => {}));
  navigator.serviceWorker.addEventListener('message', (e) => {
    if (e.data && e.data.type === 'navigate') { const u = new URL(e.data.url); const t = u.searchParams.get('tab'); if (t) navigate(t, u.searchParams.get('game') || u.searchParams.get('sub')); }
  });
}

(async function boot() {
  try {
    const s = await sb.auth.getSession();
    if (s.data.session) await afterLogin(); else renderAuth(root, afterLogin);
  } catch (e) { startError(e); }
})();
window.addEventListener('unhandledrejection', (e) => { if (root.querySelector('.msg') && /Lade/.test(root.textContent)) startError(e.reason); });
