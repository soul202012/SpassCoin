import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, onLeave, stakeBox, cardEl, coinsText } from '../ui.js';
import { sfx } from '../audio.js';

let stake = 1;

export async function init(box, ctx) {
  const tieRule = ctx.cfg.hilo.tie; let alive = true, g = null, busy = false, anim = false; onLeave(() => { alive = false; });
  stake = Math.max(1, Math.min(stake, Math.max(1, state.me.balance)));
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Higher or Lower'));
  c.appendChild(el('p', 'hint', 'Ist die nächste Karte höher oder tiefer? Jede richtige Antwort erhöht deinen Gewinn. Du kannst jederzeit aussteigen. Ass ist die höchste Karte. Gleichstand: ' + (tieRule === 'push' ? 'es geht ohne Verlust weiter.' : 'zählt als falsch.')));
  const main = el('div', 'hilo-main'), cardBox = el('div'), side = el('div'); main.appendChild(cardBox); main.appendChild(side); c.appendChild(main);
  const info = el('p'); info.style.textAlign = 'center'; c.appendChild(info);
  const res = el('div', 'res'); c.appendChild(res);
  const sbx = stakeBox(() => Math.max(1, state.me.balance), () => stake, (v) => { stake = v; });
  c.appendChild(sbx);
  const act = el('div', 'btns'); c.appendChild(act); box.appendChild(c);

  function ladderEl(ladder, streak) {
    const l = el('div', 'ladder');
    ladder.forEach((m, i) => { const d = el('div', i + 1 === streak ? 'cur' : i + 1 < streak ? 'done' : '', ''); d.appendChild(el('span', null, (i + 1) + '. richtig')); d.appendChild(el('b', null, '×' + m)); l.appendChild(d); });
    return l;
  }
  function draw(newCard) {
    cardBox.innerHTML = ''; side.innerHTML = '';
    if (!g) { cardBox.appendChild(cardEl(-1, 'big')); info.textContent = ''; return; }
    cardBox.appendChild(cardEl(g.card, 'big' + (newCard ? ' flip' : ''))); if (newCard) sfx.flip();
    side.appendChild(ladderEl(g.ladder, g.streak));
    const cur = g.streak > 0 ? Math.floor(g.stake * g.ladder[g.streak - 1]) : 0, nxt = g.streak < g.ladder.length ? Math.floor(g.stake * g.ladder[g.streak]) : null;
    info.textContent = 'Einsatz ' + g.stake + ' · Serie ' + g.streak + (g.streak ? ' · Aktueller Gewinn ' + cur + ' Coins' : '') + (nxt != null ? ' · Bei der nächsten richtigen Antwort: ' + nxt + ' Coins' : '');
  }
  function buttons() {
    act.innerHTML = '';
    if (g && g.status === 'active') {
      sbx.style.display = 'none';
      const hi = el('button', null, '▲ Höher'), lo = el('button', null, '▼ Tiefer'), out = el('button', 'ok', 'Aussteigen: +' + (g.streak ? Math.floor(g.stake * g.ladder[g.streak - 1]) : 0));
      out.disabled = g.streak < 1; hi.onclick = () => guess('higher'); lo.onclick = () => guess('lower'); out.onclick = cashout;
      [hi, lo, out].forEach((b) => { b.disabled = b.disabled || busy; act.appendChild(b); });
    } else { sbx.style.display = 'block'; const s = el('button', null, g ? 'Neue Runde' : 'Spiel starten'); s.onclick = start; act.appendChild(s); }
  }
  async function start() {
    const v = parseInt(sbx.input.value, 10) || 0;
    if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
    if (v > state.me.balance) return toast('Nicht genug Coins', true);
    res.textContent = ''; res.style.color = ''; busy = true; buttons();
    const r = await rpc('hilo_start', { p_stake: v }); busy = false;
    if (!alive) return;
    if (r.error) { toast(errText(r.error), true); return buttons(); }
    g = r.data; state.me.balance = Number(g.balance); setBal(); draw(true); buttons();
  }
  async function guess(dir) {
    if (busy) return; busy = true; buttons();
    const r = await rpc('hilo_guess', { p_game: g.id, p_dir: dir }); busy = false;
    if (!alive) return;
    if (r.error) { toast(errText(r.error), true); return buttons(); }
    const d = r.data; g = d; draw(true);
    if (d.result === 'win') { sfx.coin(); res.textContent = 'Richtig! 🎯'; res.style.color = 'var(--green)'; }
    else if (d.result === 'tie') { res.textContent = 'Gleichstand – weiter gehts'; res.style.color = ''; }
    else if (d.result === 'lose') { sfx.lose(); res.textContent = 'Falsch! Einsatz verloren (−' + coinsText(d.stake) + ')'; res.style.color = 'var(--red)'; }
    else if (d.result === 'cashout') { state.me.balance = Number(d.balance); setBal(); sfx.big(); res.textContent = '🏆 Oberste Stufe! +' + coinsText(d.net); res.style.color = 'var(--green)'; }
    buttons();
  }
  async function cashout() {
    if (busy) return; busy = true; buttons();
    const r = await rpc('hilo_cashout', { p_game: g.id }); busy = false;
    if (!alive) return;
    if (r.error) { toast(errText(r.error), true); return buttons(); }
    g = r.data; state.me.balance = Number(g.balance); setBal(); draw(false); sfx.win();
    res.textContent = g.net > 0 ? '🎉 Ausgestiegen: +' + coinsText(g.net) : g.net === 0 ? 'Ausgestiegen: ±0' : 'Ausgestiegen: −' + coinsText(-g.net);
    res.style.color = g.net > 0 ? 'var(--green)' : g.net < 0 ? 'var(--red)' : ''; buttons();
  }
  const cur = await rpc('hilo_current');
  if (!alive) return;
  if (cur.data) { g = cur.data; draw(false); } else draw(false);
  buttons();
}
