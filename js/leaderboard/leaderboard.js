import { rpc } from '../supabase.js';
import { state, go } from '../state.js';
import { el, errText, onLeave, sgn } from '../ui.js';
import { loadCatalog, avatarEl, nameEl } from '../profile/cosmetics.js';

let period = 'day', category = 'stock';
const CATS = [['stock', 'Coin-Bestand'], ['net', 'Coin-Bilanz'], ['wins', 'Gewonnene Spiele'], ['activity', 'Aktivität']];
const PERIODS = [['day', 'Heute'], ['week', 'Woche'], ['all', 'Allzeit']];
const UNIT = { stock: 'Coins', net: 'Coins', wins: 'Siege', activity: 'Runden' };

export async function renderLeaderboard(box) {
  await loadCatalog();
  const seg2 = el('div', 'seg');
  CATS.forEach(([k, t]) => { const b = el('button', category === k ? 'on' : '', t); b.onclick = () => { category = k; go('rank'); }; seg2.appendChild(b); });
  box.appendChild(seg2);
  if (category !== 'stock') {
    const seg1 = el('div', 'seg');
    PERIODS.forEach(([k, t]) => { const b = el('button', period === k ? 'on' : '', t); b.onclick = () => { period = k; go('rank'); }; seg1.appendChild(b); });
    box.appendChild(seg1);
  }
  const card = el('div', 'card wide');
  const list = el('div'); card.appendChild(list); box.appendChild(card);
  const mine = el('div', 'wide'); box.appendChild(mine);

  const fmt = (v) => (category === 'net' ? sgn(v) : v);
  function row(x, rank, withLook) {
    const r = el('div', 'lb-row' + (x.me || x.username === state.me.username ? ' me' : ''));
    r.appendChild(el('div', 'lb-rank' + (rank <= 3 ? ' r' + rank : ''), rank === 1 ? '👑' : String(rank)));
    if (withLook) r.appendChild(avatarEl(x, 34));
    const nm = el('div', 'lb-name'); nm.appendChild(withLook ? nameEl(x) : el('span', 'pname', x.username)); r.appendChild(nm);
    r.appendChild(el('div', 'lb-val', fmt(x.value) + ' ' + UNIT[category]));
    r.onclick = () => { state.profileUser = x.username; go('profile'); };
    return r;
  }
  async function load() {
    mine.innerHTML = '';
    if (category === 'stock') {
      const r = await rpc('leaderboard');
      if (r.error) { list.textContent = errText(r.error); return; }
      list.innerHTML = '';
      const rows = r.data || [];
      if (!rows.length) list.appendChild(el('p', 'hint', 'Noch keine Einträge.'));
      let myRank = null, myVal = null;
      rows.forEach((x, i) => {
        const o = { username: x.username, value: x.balance }; if (x.username === state.me.username) { myRank = i + 1; myVal = x.balance; }
        list.appendChild(row(o, i + 1, false));
      });
      if (myRank) { const m = el('div', 'mycard'); m.appendChild(el('span', null, 'Dein Rang: ' + myRank)); m.appendChild(el('span', null, myVal + ' Coins')); mine.appendChild(m); }
      return;
    }
    const r = await rpc('leaderboard_v2', { p_period: period, p_cat: category });
    if (r.error) { list.textContent = errText(r.error); return; }
    list.innerHTML = '';
    const rows = r.data.rows || [];
    if (!rows.length) list.appendChild(el('p', 'hint', 'Noch keine Einträge.'));
    rows.forEach((x) => list.appendChild(row(x, x.rank, true)));
    if (r.data.me) { const m = el('div', 'mycard'); m.appendChild(el('span', null, 'Dein Rang: ' + r.data.me.rank)); m.appendChild(el('span', null, fmt(r.data.me.value) + ' ' + UNIT[category])); mine.appendChild(m); }
  }
  await load();
  const iv = setInterval(() => { if (!document.hidden) load(); }, 30000);
  onLeave(() => clearInterval(iv));
}
