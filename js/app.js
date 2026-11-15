import { sb, rpc } from './supabase.js';
import { state, DEFAULTS, refreshMe, canAdmin, setBal } from './state.js';
import { el, runCleanup, confirmBox } from './ui.js';
import { renderAuth } from './auth.js';
import { applyTheme, loadSettings } from './settings.js';
import { stopMusic } from './audio.js';

const root = document.getElementById('root');

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
const PRIMARY = [['home', 'Start'], ['games', 'Spiele'], ['missions', 'Missionen'], ['rank', 'Rangliste'], ['shop', 'Shop']];
const MORE = [['profile', 'Profil'], ['account', 'Konto'], ['settings', 'Einstellungen']];
const TITLES = Object.fromEntries(PRIMARY.concat(MORE, [['admin', 'Admin']]));
const ICONS = {
  home: '<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"/>',
  games: '<rect x="2" y="7" width="20" height="11" rx="5.5"/><path d="M7 10.5v4M5 12.5h4"/><circle cx="16" cy="11.5" r=".6"/><circle cx="18" cy="13.5" r=".6"/>',
  missions: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.2"/>',
  rank: '<path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0z"/><path d="M7 6H4v1a3 3 0 0 0 3 3M17 6h3v1a3 3 0 0 1-3 3"/>',
  shop: '<path d="M5 8h14l-1 12H6z"/><path d="M9 8V6a3 3 0 0 1 6 0v2"/>',
  profile: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  account: '<rect x="3" y="6" width="18" height="13" rx="3"/><path d="M3 10h18M7 15h4"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>',
  admin: '<path d="M12 3l8 3v6c0 4.5-3.4 8.3-8 9-4.6-.7-8-4.5-8-9V6z"/>',
  out: '<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3M10 17l5-5-5-5M15 12H3"/>',
};
const svgIcon = (k) => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICONS[k] + '</svg>';

let ui = null, rendering = false, pending = false;

function moreItems() { return canAdmin() ? MORE.concat([['admin', 'Admin']]) : MORE; }

function buildShell() {
  root.innerHTML = '';
  const bar = el('header', 'topbar'), inner = el('div', 'topbar-in');
  const brand = el('button', 'brand', 'SpassCoin'); brand.onclick = () => go('home');
  const desk = el('nav', 'desk-nav'), links = {};
  PRIMARY.forEach(([k, t]) => { const b = el('button', 'nl', t); b.onclick = () => go(k); desk.appendChild(b); links[k] = b; });
  const dd = el('div', 'dd'), more = el('button', 'nl', 'Mehr'), menu = el('div', 'dd-menu'), ddItems = {};
  more.setAttribute('aria-haspopup', 'true');
  moreItems().forEach(([k, t]) => { const b = el('button', null, t); b.onclick = () => { dd.classList.remove('open'); go(k); }; menu.appendChild(b); ddItems[k] = b; });
  menu.appendChild(el('hr'));
  const out = el('button', null, 'Abmelden'); out.onclick = () => sb.auth.signOut(); menu.appendChild(out);
  more.onclick = (e) => { e.stopPropagation(); dd.classList.toggle('open'); more.setAttribute('aria-expanded', dd.classList.contains('open')); };
  dd.appendChild(more); dd.appendChild(menu); desk.appendChild(dd);
  const right = el('div', 'top-right');
  const chip = el('span', 'chip desk'); const bal = el('span'); bal.setAttribute('data-bal', ''); chip.appendChild(bal); chip.appendChild(document.createTextNode(' Coins'));
  const mchip = el('span', 'chip'); mchip.style.display = 'none';
  const mb = el('button', 'menu-btn', 'Menü'); mb.setAttribute('aria-expanded', 'false');
  right.appendChild(chip); right.appendChild(mb);
  inner.appendChild(brand); inner.appendChild(desk); inner.appendChild(right); bar.appendChild(inner);

  const panel = el('div', 'menu-panel'), grid = el('div', 'grid'), pItems = {};
  const item = (k, t, cls) => { const b = el('button', cls); b.innerHTML = svgIcon(k); b.appendChild(el('span', null, t)); return b; };
  PRIMARY.concat(moreItems()).forEach(([k, t]) => { const b = item(k, t); b.onclick = () => { closeMenus(); go(k); }; grid.appendChild(b); pItems[k] = b; });
  const po = item('out', 'Abmelden', 'out'); po.onclick = () => sb.auth.signOut(); grid.appendChild(po);
  panel.appendChild(grid); panel.onclick = (e) => e.stopPropagation();
  mb.onclick = (e) => { e.stopPropagation(); const o = panel.classList.toggle('open'); mb.setAttribute('aria-expanded', o); };
  function closeMenus() { dd.classList.remove('open'); panel.classList.remove('open'); mb.setAttribute('aria-expanded', 'false'); }

  const page = el('main', 'page'); root.appendChild(bar); root.appendChild(panel); root.appendChild(page);
  ui = { bar, page, links, more, ddItems, pItems, closeMenus };
  setBal();
}
document.addEventListener('click', () => { if (ui) ui.closeMenus(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && ui) ui.closeMenus(); });

function markActive() {
  Object.entries(ui.links).forEach(([k, b]) => { b.classList.toggle('on', k === state.tab); });
  const inMore = moreItems().some(([k]) => k === state.tab);
  ui.more.classList.toggle('on', inMore);
  Object.entries(ui.ddItems).forEach(([k, b]) => b.classList.toggle('on', k === state.tab));
  Object.entries(ui.pItems).forEach(([k, b]) => b.classList.toggle('on', k === state.tab));}

export async function render() {
  if (rendering) { pending = true; return; }
  rendering = true;
  try {
    do {
      pending = false; runCleanup();
      if (!state.me) { ui = null; renderAuth(root, afterLogin); continue; }
      if (!ui || !root.contains(ui.bar)) buildShell();
      markActive(); setBal();
      const tab = VIEWS[state.tab] ? state.tab : 'home';
      ui.page.replaceChildren(el('p', 'msg', 'Lade …'));
      try {
        const fn = await VIEWS[tab]();
        const box = el('div', 'view v-' + tab);
        if (!state.sub) box.appendChild(el('h1', 'ptitle', tab === 'home' ? 'Hallo, ' + state.me.username : TITLES[tab]));
        await fn(box);
        if (pending) continue;
        ui.page.replaceChildren(box); setBal();
      } catch (e) { console.error(e); ui.page.replaceChildren(el('p', 'msg', 'Etwas ist schiefgelaufen. Bitte neu laden.')); }
    } while (pending);
  } finally { rendering = false; }
}

function go(tab, sub) {
  if (state.dirty) {
    return confirmBox('Ungespeicherte Änderungen', 'Wenn du die Seite verlässt, gehen deine Änderungen verloren.', 'Verwerfen').then((ok) => { if (ok) { state.dirty = false; navigate(tab, sub); } });
  }
  navigate(tab, sub);
}
export function navigate(tab, sub) {
  state.tab = tab || state.tab; state.sub = sub || null;
  try { history.replaceState(null, '', '?tab=' + state.tab + (state.sub ? '&sub=' + encodeURIComponent(state.sub) : '')); } catch (e) { /* ignore */ }
  window.scrollTo(0, 0); render();
}
state.navigate = go;
window.addEventListener('beforeunload', (e) => { if (state.dirty) { e.preventDefault(); e.returnValue = ''; } });

function startError(e) {
  console.error(e); root.innerHTML = '';
  const w = el('div', 'auth'), c = el('div', 'card'); c.appendChild(el('h2', null, 'Start fehlgeschlagen'));
  c.appendChild(el('p', null, 'Beim Starten ist ein Fehler aufgetreten: ' + ((e && e.message) || e)));
  const b = el('button', 'full', 'Neu laden'); b.onclick = () => location.reload(); c.appendChild(b); w.appendChild(c); root.appendChild(w);
}
async function afterLogin(cb) {
  try {
    await refreshMe(true);
    if (!state.me) { renderAuth(root, afterLogin); return; }
    loadSettings(); readUrl(); render(); if (cb) cb();
    Promise.resolve(rpc('race_state')).then(() => refreshMe(true)).then(() => setBal()).catch(() => {});
  } catch (e) { startError(e); }
}
function readUrl() {
  const p = new URLSearchParams(location.search), t = p.get('tab');
  if (t && (VIEWS[t] || t === 'admin')) { state.tab = t; state.sub = p.get('game') || p.get('sub') || null; }
}

sb.auth.onAuthStateChange((ev) => {
  if (ev === 'SIGNED_OUT') { state.me = null; state.tab = 'home'; state.sub = null; state.dirty = false; stopMusic(); state.S = { ...DEFAULTS }; applyTheme(); render(); }
});
document.addEventListener('visibilitychange', async () => { if (!document.hidden && state.me) { await refreshMe(true); setBal(); } });

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('service-worker.js').catch(() => {}));
  navigator.serviceWorker.addEventListener('message', (e) => {
    if (e.data && e.data.type === 'navigate') { const u = new URL(e.data.url), t = u.searchParams.get('tab'); if (t) navigate(t, u.searchParams.get('game') || u.searchParams.get('sub')); }
  });
}

(async function boot() {
  try {
    const s = await sb.auth.getSession();
    if (s.data.session) await afterLogin(); else renderAuth(root, afterLogin);
  } catch (e) { startError(e); }
})();
window.addEventListener('unhandledrejection', (e) => { if (root.querySelector('.msg') && /Lade/.test(root.textContent) && !ui) startError(e.reason); });
