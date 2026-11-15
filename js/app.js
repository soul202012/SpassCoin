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
  PRIMARY.concat(moreItems()).forEach(([k, t]) => { const b = el('button', null, t); b.onclick = () => { closeMenus(); go(k); }; grid.appendChild(b); pItems[k] = b; });
  const po = el('button', 'out', 'Abmelden'); po.onclick = () => sb.auth.signOut(); grid.appendChild(po);
  panel.appendChild(grid);
  mb.onclick = () => { const o = panel.classList.toggle('open'); mb.setAttribute('aria-expanded', o); mb.textContent = o ? 'Schliessen' : 'Menü'; };
  function closeMenus() { dd.classList.remove('open'); panel.classList.remove('open'); mb.textContent = 'Menü'; mb.setAttribute('aria-expanded', 'false'); }

  const page = el('main', 'page'); root.appendChild(bar); root.appendChild(panel); root.appendChild(page);
  ui = { bar, page, links, more, ddItems, pItems, closeMenus };
  setBal();
}
document.addEventListener('click', () => { const d = document.querySelector('.dd.open'); if (d) d.classList.remove('open'); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && ui) ui.closeMenus(); });

function markActive() {
  Object.entries(ui.links).forEach(([k, b]) => { b.classList.toggle('on', k === state.tab); });
  const inMore = moreItems().some(([k]) => k === state.tab);
  ui.more.classList.toggle('on', inMore);
  Object.entries(ui.ddItems).forEach(([k, b]) => b.classList.toggle('on', k === state.tab));
  Object.entries(ui.pItems).forEach(([k, b]) => b.classList.toggle('on', k === state.tab));
}

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
        const box = el('div', 'view'); await fn(box);
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
