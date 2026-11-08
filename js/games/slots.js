import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, sleep, onLeave, stakeBox } from '../ui.js';
import { sfx } from '../audio.js';

let slotStake = 1;
const H = 96;

export function init(box, ctx) {
  const syms = ctx.gi.slot_symbols; let alive = true, spinning = false, autoLeft = 0;
  onLeave(() => { alive = false; autoLeft = 0; });
  slotStake = Math.max(1, Math.min(slotStake, Math.max(1, state.me.balance)));
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Slotmaschine'));
  c.appendChild(el('p', 'hint', 'Drei gleiche Symbole gewinnen. Der Gewinn hängt vom Symbol ab.'));
  const slot = el('div', 'slot'), strips = [];
  for (let i = 0; i < 3; i++) { const rl = el('div', 'reel'), st = el('div', 'strip'); st.appendChild(el('div', null, syms[Math.floor(Math.random() * syms.length)].symbol)); rl.appendChild(st); slot.appendChild(rl); strips.push(st); }
  c.appendChild(slot);
  const res = el('div', 'res'); c.appendChild(res);
  const sbx = stakeBox(() => Math.max(1, state.me.balance), () => slotStake, (v) => { slotStake = v; });
  c.appendChild(sbx);
  const go = el('button', 'full', 'Drehen'); c.appendChild(go);

  // Autospin
  const ac = el('div', 'card'); ac.style.marginTop = '12px'; ac.appendChild(el('h2', null, 'Autospin'));
  const row = el('div', 'row2');
  const sel = el('select'); [5, 10, 25, 50].forEach((n) => { const o = el('option', null, n + ' Spins'); o.value = n; sel.appendChild(o); });
  const ab = el('button', null, 'Autospin starten'); row.appendChild(sel); row.appendChild(ab); ac.appendChild(row);
  const sr = el('div', 'srow'); sr.appendChild(el('span', null, 'Bei grösserem Gewinn (ab 10× Einsatz) stoppen'));
  const stopBig = el('input'); stopBig.type = 'checkbox'; stopBig.checked = true; sr.appendChild(stopBig); ac.appendChild(sr);
  ac.appendChild(el('p', 'hint', 'Der Einsatz pro Runde bleibt wie oben eingestellt. Jede Runde wird einzeln gespeichert. Der Autospin stoppt automatisch, wenn der Kontostand nicht reicht.'));
  c.appendChild(ac);
  const pt = el('div', 'paytable'); pt.style.marginTop = '14px';
  syms.forEach((s) => { const d = el('div', null, s.symbol + ' ×' + s.mult); d.title = 'Einsatz mal ' + s.mult; pt.appendChild(d); });
  c.appendChild(el('p', 'hint', 'Auszahlung bei drei gleichen Symbolen (× Einsatz):')); c.appendChild(pt);
  box.appendChild(c);

  async function animate(strip, from, fin, dur) {
    strip.style.transition = 'none'; strip.style.transform = 'translateY(0)'; strip.innerHTML = '';
    strip.appendChild(el('div', null, from));
    const n = 14 + Math.floor(Math.random() * 6);
    for (let k = 0; k < n; k++) strip.appendChild(el('div', null, syms[Math.floor(Math.random() * syms.length)].symbol));
    strip.appendChild(el('div', null, fin));
    void strip.offsetHeight;
    strip.style.transition = 'transform ' + dur + 's cubic-bezier(.17,.67,.25,1)'; strip.style.transform = 'translateY(-' + ((n + 1) * H) + 'px)';
    await sleep(dur * 1000 + 60);
    if (!alive) return;
    strip.style.transition = 'none'; strip.style.transform = 'translateY(0)'; strip.innerHTML = ''; strip.appendChild(el('div', null, fin)); sfx.stop();
  }
  function setBusy(b) { spinning = b; go.disabled = b; ab.textContent = autoLeft > 0 ? 'Stopp (' + autoLeft + ' übrig)' : 'Autospin starten'; ab.disabled = b && autoLeft === 0; sel.disabled = autoLeft > 0 || b; }
  async function spin(v, fast) {
    setBusy(true); res.textContent = ''; res.style.color = '';
    const r = await rpc('slot_spin', { p_stake: v });
    if (!alive) return null;
    if (r.error) { setBusy(false); toast(errText(r.error), true); return null; }
    const d = r.data, tk = setInterval(sfx.tick, 110), from = strips.map((s) => (s.firstChild ? s.firstChild.textContent : syms[0].symbol));
    const f = fast ? 0.45 : 1;
    await Promise.all(strips.map((s, i) => animate(s, from[i], syms[d.reels[i]].symbol, (1.5 + i * 0.6) * f)));
    clearInterval(tk);
    if (!alive) return null;
    state.me.balance = Number(d.balance); setBal(); setBusy(false);
    if (d.win) { res.textContent = '🎉 Treffer! +' + d.net + (d.net === 1 ? ' Coin' : ' Coins'); res.style.color = 'var(--green)'; d.payout >= v * 30 ? sfx.big() : sfx.win(); }
    else { res.textContent = 'Leider nichts. −' + v + (v === 1 ? ' Coin' : ' Coins'); res.style.color = 'var(--red)'; sfx.lose(); }
    return d;
  }
  go.onclick = async () => {
    if (spinning) return;
    const v = parseInt(sbx.input.value, 10) || 0;
    if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
    if (v > state.me.balance) return toast('Nicht genug Coins', true);
    await spin(v, false);
  };
  ab.onclick = async () => {
    if (autoLeft > 0) { autoLeft = 0; setBusy(spinning); return; }
    if (spinning) return;
    const v = parseInt(sbx.input.value, 10) || 0;
    if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
    if (v > state.me.balance) return toast('Nicht genug Coins', true);
    autoLeft = parseInt(sel.value, 10); setBusy(false);
    while (autoLeft > 0 && alive) {
      if (state.me.balance < v) { toast('Der Kontostand reicht nicht mehr – Autospin beendet'); break; }
      const d = await spin(v, true); if (!d) break;
      autoLeft--; setBusy(false);
      if (stopBig.checked && d.win && d.payout >= v * 10) { toast('Grosser Gewinn! Autospin gestoppt'); break; }
      await sleep(350);
    }
    autoLeft = 0; if (alive) setBusy(false);
  };
  setBusy(false);
}
