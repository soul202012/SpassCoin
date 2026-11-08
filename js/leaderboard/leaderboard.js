import { rpc } from '../supabase.js';
import { state, go } from '../state.js';
import { el, errText, onLeave, sgn } from '../ui.js';
import { loadCatalog, avatarEl, nameEl } from '../profile/cosmetics.js';

let period = 'day', category = 'net';
const CATS = [['net', '💰 Coin-Bilanz'], ['wins', '🏅 Gewonnene Spiele'], ['activity', '🎮 Aktivität']];
const PERIODS = [['day', 'Heute'], ['week', 'Woche'], ['all', 'Allzeit']];
const UNIT = { net: 'Coins', wins: 'Siege', activity: 'Runden' };

export async function renderLeaderboard(box) {
  await loadCatalog();
  const seg1 = el('div', 'seg'), seg2 = el('div', 'seg');
  PERIODS.forEach(([k, t]) => { const b = el('button', period === k ? 'on' : '', t); b.onclick = () => { period = k; go('rank'); }; seg1.appendChild(b); });
  CATS.forEach(([k, t]) => { const b = el('button', category === k ? 'on' : '', t); b.onclick = () => { category = k; go('rank'); }; seg2.appendChild(b); });
  box.appendChild(seg1); box.appendChild(seg2);
  const card = el('div', 'card'); const sub = { net: 'Verdiente minus ausgegebene Coins', wins: 'Anzahl gewonnener Runden', activity: 'Anzahl gespielter Runden' }[category];
  card.appendChild(el('h2', null, sub + (period === 'day' ? ' · heute' : period === 'week' ? ' · diese Woche' : ' · allzeit')));
  const list = el('div'); card.appendChild(list); box.appendChild(card);
  const mine = el('div'); box.appendChild(mine);
  card.appendChild(el('p', 'hint', period === 'day' ? 'Die Tagesrangliste startet täglich um Mitternacht neu (Schweizer Zeit).' : period === 'week' ? 'Die Wochenrangliste startet jeden Montag neu.' : 'Die Allzeit-Rangliste bleibt dauerhaft.'));

  async function load() {
    const r = await rpc('leaderboard_v2', { p_period: period, p_cat: category });
    if (r.error) { list.textContent = errText(r.error); return; }
    list.innerHTML = '';
    const rows = r.data.rows || [];
    if (!rows.length) list.appendChild(el('p', 'hint', 'Noch keine Einträge. Spiel eine Runde!'));
    rows.forEach((x) => {
      const row = el('div', 'lb-row' + (x.me ? ' me' : ''));
      row.appendChild(el('div', 'lb-rank', ['🥇', '🥈', '🥉'][x.rank - 1] || String(x.rank)));
      row.appendChild(avatarEl(x, 38));
      const nm = el('div', 'lb-name'); nm.appendChild(nameEl(x)); row.appendChild(nm);
      row.appendChild(el('div', 'lb-val', (category === 'net' ? sgn(x.value) : x.value) + ' ' + UNIT[category]));
      row.onclick = () => { state.profileUser = x.username; go('profile'); };
      list.appendChild(row);
    });
    mine.innerHTML = '';
    if (r.data.me) { const m = el('div', 'mycard'); m.appendChild(el('span', null, 'Dein Rang: ' + r.data.me.rank)); m.appendChild(el('span', null, (category === 'net' ? sgn(r.data.me.value) : r.data.me.value) + ' ' + UNIT[category])); mine.appendChild(m); }
    else mine.appendChild(el('p', 'hint', 'Du hast in diesem Zeitraum noch keinen Eintrag.'));
  }
  await load();
  const iv = setInterval(() => { if (!document.hidden) load(); }, 30000);
  onLeave(() => clearInterval(iv));
}
