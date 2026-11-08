import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, onLeave, stakeBox, cardEl } from '../ui.js';
import { sfx } from '../audio.js';

let bjStake = 1;

export async function init(box, ctx) {
  const gi = ctx.gi; let alive = true, prev = { p: 0, d: 0, hidden: false }, cur = null; onLeave(() => { alive = false; });
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Blackjack'));
  c.appendChild(el('p', 'hint', 'Komm näher an 21 als der Dealer, ohne drüber zu kommen. Blackjack zahlt ' + (gi.bj_blackjack_payout === 1.5 ? '3:2' : '×' + (1 + gi.bj_blackjack_payout) + ' (Einsatz inklusive)') + '. Gewinn = doppelter Einsatz, Gleichstand = Einsatz zurück. Der Dealer zieht bis 17.'));
  const dHand = el('div', 'hand'), dTot = el('div', 'total'), pHand = el('div', 'hand'), pTot = el('div', 'total');
  const banner = el('div', 'res'), act = el('div', 'btns');
  const sbx = stakeBox(() => Math.max(1, state.me.balance), () => bjStake, (v) => { bjStake = v; });
  [el('div', 'lbl', 'Dealer'), dHand, dTot, el('div', 'lbl', 'Du'), pHand, pTot, banner, sbx, act].forEach((x) => c.appendChild(x));
  box.appendChild(c);
  function draw(st) {
    const hiddenNow = st.status === 'active';
    dHand.innerHTML = ''; pHand.innerHTML = '';
    st.dealer.forEach((x, i) => { let cls = ''; if (i === 1 && prev.hidden && !hiddenNow) cls = 'flip'; else if (i >= prev.d) cls = 'deal'; dHand.appendChild(cardEl(x, cls)); if (cls) sfx.card(); });
    st.player.forEach((x, i) => { const cls = i >= prev.p ? 'deal' : ''; pHand.appendChild(cardEl(x, cls)); if (cls) sfx.card(); });
    dTot.textContent = hiddenNow ? '' : 'Summe: ' + st.dtotal; pTot.textContent = 'Summe: ' + st.ptotal;
    prev = { p: st.player.length, d: st.dealer.length, hidden: hiddenNow };
    act.innerHTML = ''; banner.textContent = ''; banner.style.color = '';
    if (hiddenNow) {
      sbx.style.display = 'none';
      const h = el('button', null, 'Karte'), s = el('button', 'sec', 'Halten'), d = el('button', 'sec', 'Verdoppeln');
      h.onclick = () => move('bj_hit'); s.onclick = () => move('bj_stand'); d.onclick = () => move('bj_double');
      d.disabled = !(st.can_double && state.me.balance >= st.stake);
      act.appendChild(h); act.appendChild(s); act.appendChild(d);
    } else {
      sbx.style.display = 'block';
      const t = { win: ['🎉 Gewonnen! +' + st.net + ' Coins', 'var(--green)'], blackjack: ['🃏 Blackjack! +' + st.net + ' Coins', 'var(--green)'], push: ['Unentschieden – Einsatz zurück', ''], lose: ['Verloren −' + (-st.net) + ' Coins', 'var(--red)'] }[st.result];
      if (t) { banner.textContent = t[0]; banner.style.color = t[1]; }
      if (st.result === 'win' || st.result === 'blackjack') sfx.win(); else if (st.result === 'lose') sfx.lose();
      const n = el('button', null, 'Neue Runde austeilen'); n.onclick = start; act.appendChild(n);
    }
  }
  async function move(fn) {
    if (!cur) return; act.querySelectorAll('button').forEach((b) => { b.disabled = true; });
    const r = await rpc(fn, { p_game: cur.id });
    if (!alive) return;
    if (r.error) { toast(errText(r.error), true); return draw(cur); }
    cur = r.data; if (cur.balance != null) { state.me.balance = Number(cur.balance); setBal(); }
    draw(cur);
  }
  async function start() {
    const v = parseInt(sbx.input.value, 10) || 0;
    if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
    if (v > state.me.balance) return toast('Nicht genug Coins', true);
    act.querySelectorAll('button').forEach((b) => { b.disabled = true; });
    const r = await rpc('bj_start', { p_stake: v });
    if (!alive) return;
    if (r.error) { toast(errText(r.error), true); return load(); }
    cur = r.data; prev = { p: 0, d: 0, hidden: false };
    if (cur.balance != null) { state.me.balance = Number(cur.balance); setBal(); }
    draw(cur);
  }
  async function load() {
    const r = await rpc('bj_current');
    if (!alive) return;
    if (r.data) { cur = r.data; prev = { p: 0, d: 0, hidden: true }; draw(cur); return; }
    cur = null; act.innerHTML = ''; sbx.style.display = 'block';
    const b = el('button', null, 'Austeilen'); b.onclick = start; act.appendChild(b);
  }
  load();
}
