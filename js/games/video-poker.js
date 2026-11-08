import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, onLeave, stakeBox, cardEl, sleep, coinsText } from '../ui.js';
import { sfx } from '../audio.js';

let stake = 1;
const NAMES = { royal: 'Royal Flush', straight_flush: 'Straight Flush', four: 'Vierling', full_house: 'Full House', flush: 'Flush', straight: 'Strasse', three: 'Drilling', two_pair: 'Zwei Paare', jacks: 'Paar Buben oder höher' };
const ORDER = ['royal', 'straight_flush', 'four', 'full_house', 'flush', 'straight', 'three', 'two_pair', 'jacks'];

export async function init(box, ctx) {
  const pay = ctx.cfg.poker.paytable; let alive = true, game = null, hold = [false, false, false, false, false], busy = false; onLeave(() => { alive = false; });
  stake = Math.max(1, Math.min(stake, Math.max(1, state.me.balance)));
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Video Poker · Jacks or Better'));
  c.appendChild(el('p', 'hint', 'Du bekommst fünf Karten. Tippe auf Karten, die du behalten willst, und zieh den Rest neu. Ab einem Paar Buben gewinnst du.'));
  const hand = el('div', 'vp-hand'); c.appendChild(hand);
  const res = el('div', 'res'); c.appendChild(res);
  const sbx = stakeBox(() => Math.max(1, state.me.balance), () => stake, (v) => { stake = v; table(); });
  c.appendChild(sbx);
  const act = el('div', 'btns'); c.appendChild(act);
  const tbl = el('table', 'vp-pay'); const tw = el('div', 'scroll'); tw.style.marginTop = '12px'; tw.appendChild(tbl); c.appendChild(tw);
  box.appendChild(c);
  sbx.input.addEventListener('input', () => table());

  function table(hit) {
    const v = game ? game.stake : (parseInt(sbx.input.value, 10) || 1);
    tbl.innerHTML = '<tr><th>Hand</th><th>×</th><th>Gewinn bei ' + v + ' Coins</th></tr>';
    ORDER.forEach((k) => { const r = el('tr', k === hit ? 'hit' : ''); r.appendChild(el('td', null, NAMES[k])); r.appendChild(el('td', null, '×' + pay[k])); r.appendChild(el('td', null, Math.floor(v * pay[k]) + ' Coins')); tbl.appendChild(r); });
  }
  function drawHand(cards, flipIdx) {
    hand.innerHTML = '';
    cards.forEach((cd, i) => {
      const slot = el('div', 'vp-slot'), held = el('div', 'held', hold[i] && game ? 'BEHALTEN' : ''), card = cardEl(cd, (flipIdx && flipIdx.includes(i) ? 'flip ' : '') + (hold[i] && game ? 'sel' : ''));
      card.onclick = () => { if (!game || busy) return; hold[i] = !hold[i]; sfx.click(); drawHand(cards); };
      slot.appendChild(held); slot.appendChild(card); hand.appendChild(slot);
    });
  }
  function buttons() {
    act.innerHTML = '';
    if (game) { sbx.style.display = 'none'; const d = el('button', null, 'Karten ziehen'); d.disabled = busy; d.onclick = draw; act.appendChild(d); }
    else { sbx.style.display = 'block'; const s = el('button', null, 'Austeilen'); s.disabled = busy; s.onclick = deal; act.appendChild(s); }
  }
  async function deal() {
    const v = parseInt(sbx.input.value, 10) || 0;
    if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
    if (v > state.me.balance) return toast('Nicht genug Coins', true);
    busy = true; buttons(); res.textContent = ''; res.style.color = '';
    const r = await rpc('vp_deal', { p_stake: v }); busy = false;
    if (!alive) return;
    if (r.error) { toast(errText(r.error), true); return buttons(); }
    game = r.data; hold = [false, false, false, false, false]; state.me.balance = Number(game.balance); setBal();
    drawHand(game.hand, [0, 1, 2, 3, 4]); sfx.card(); table(); buttons();
  }
  async function draw() {
    busy = true; buttons();
    const r = await rpc('vp_draw', { p_game: game.id, p_hold: hold }); busy = false;
    if (!alive) return;
    if (r.error) { toast(errText(r.error), true); return buttons(); }
    const d = r.data, changed = [0, 1, 2, 3, 4].filter((i) => !hold[i]), stakeNow = game.stake;
    const was = game; game = null; hold = [false, false, false, false, false];
    drawHand(d.hand, changed); sfx.flip(); await sleep(350); if (!alive) return;
    state.me.balance = Number(d.balance); setBal(); table(d.kind); game = null; was.done = true;
    if (d.kind === 'none') { res.textContent = 'Keine Gewinnhand. −' + coinsText(stakeNow); res.style.color = 'var(--red)'; sfx.lose(); }
    else { res.textContent = '🎉 ' + NAMES[d.kind] + '! +' + coinsText(d.net) + ' (Auszahlung ' + d.payout + ')'; res.style.color = d.net > 0 ? 'var(--green)' : ''; d.mult >= 25 ? sfx.big() : sfx.win(); }
    buttons();
  }
  const cur = await rpc('vp_current');
  if (!alive) return;
  if (cur.data) { game = cur.data; hold = [false, false, false, false, false]; drawHand(game.hand); }
  else { for (let i = 0; i < 5; i++) { const slot = el('div', 'vp-slot'); slot.appendChild(el('div', 'held')); slot.appendChild(cardEl(-1)); hand.appendChild(slot); } }
  table(); buttons();
}
