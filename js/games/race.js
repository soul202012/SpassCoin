import { rpc } from '../supabase.js';
import { state, refreshMe, setBal } from '../state.js';
import { el, toast, errText, onLeave, hms, stakeBox } from '../ui.js';
import { sfx } from '../audio.js';
import { racePhase } from './index.js';

let betStake = 1;
const mulberry32 = (a) => () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
// Positionen des Rennens werden aus dem Seed des Servers berechnet, darum sehen alle dasselbe Rennen
function raceModel(seed, winner) {
  const rnd = mulberry32(seed), h = [];
  for (let i = 0; i < 5; i++) { const F = i === winner ? 1 : 1 - (0.004 + rnd() * 0.03), a = []; for (let k = 0; k < 4; k++) a.push((rnd() * 2 - 1) * 0.025); h.push({ F, a }); }
  return h;
}
function racePos(m, i, t) { const h = m[i]; let p = h.F * t; for (let k = 1; k <= 4; k++) p += h.a[k - 1] * Math.sin(k * Math.PI * t); return Math.max(0, Math.min(1, p)); }

export function init(box) {
  let st = null, offset = 0, alive = true, reloading = false, model = null, drawn = null, sel = null, raf = 0, gal = 0, poll = 0, refs = {}, lastSig = '', lastOrder = 0;
  onLeave(() => { alive = false; cancelAnimationFrame(raf); clearInterval(gal); clearInterval(poll); });
  const card = el('div', 'card'); card.appendChild(el('h2', null, 'Pferderennen · täglich 19:00 Uhr (Schweizer Zeit)'));
  const body = el('div'); card.appendChild(body); box.appendChild(card);
  const lastBox = el('div'); box.appendChild(lastBox);
  const dot = (c) => { const d = el('span', 'dot'); d.style.background = c; return d; };

  async function load() {
    reloading = true; const r = await rpc('race_state'); reloading = false; if (!alive) return;
    if (r.error) { body.textContent = errText(r.error); return; }
    const prevPhase = drawn; st = r.data; offset = st.server_ms - Date.now();
    model = st.seed != null ? raceModel(st.seed, st.winner) : null;
    drawn = racePhase(st, Date.now() + offset);
    await refreshMe(); setBal();
    const sig = drawn + '|' + JSON.stringify(st.my_bets) + '|' + st.winner + '|' + (st.last && st.last.date);
    if (sig === lastSig && body.childNodes.length) return;
    lastSig = sig; build(prevPhase);
  }
  function betsList() {
    const w = el('div'); if (!st.my_bets.length) return w;
    w.appendChild(el('div', 'lbl', 'Deine Wetten'));
    st.my_bets.forEach((b) => {
      const h = st.horses[b.horse], row = el('div', 'stat'), l = el('span');
      l.appendChild(dot(h.color)); l.appendChild(document.createTextNode(' ' + h.name + ': ' + b.stake + ' Coins'));
      const rt = el('b', null, b.status === 'won' ? 'gewonnen +' + (b.payout - b.stake) : b.status === 'lost' ? 'verloren −' + b.stake : 'bis zu ' + Math.floor(b.stake * h.odds));
      rt.style.color = b.status === 'won' ? 'var(--green)' : b.status === 'lost' ? 'var(--red)' : '';
      row.appendChild(l); row.appendChild(rt); w.appendChild(row);
    });
    return w;
  }
  function trackEl() {
    const t = el('div', 'track'); refs.runners = []; refs.lanes = [];
    st.horses.forEach((h) => {
      const ln = el('div', 'lane'), rn = el('div', 'runner'), bar = el('i'), em = el('em', null, '🐎'); bar.style.background = h.color;
      rn.appendChild(bar); rn.appendChild(em); ln.appendChild(rn); t.appendChild(ln); refs.runners.push(rn); refs.lanes.push(ln);
    });
    return t;
  }
  function build(prevPhase) {
    cancelAnimationFrame(raf); clearInterval(gal); body.innerHTML = ''; lastBox.innerHTML = ''; refs = {};
    refs.count = el('div', 'runline'); const ph = drawn;
    body.appendChild(el('p', 'hint', { waiting: 'Die Wetten öffnen um 18:00 Uhr.', betting: 'Wetten sind offen bis 19:00 Uhr. Du kannst mehrere Wetten setzen.', racing: 'Das Rennen läuft live, alle sehen dasselbe Rennen.', finished: 'Das Rennen ist vorbei.' }[ph] || ''));
    body.appendChild(refs.count);
    if (ph === 'waiting' || ph === 'betting') {
      st.horses.forEach((h, i) => {
        const r = el('div', 'horse' + (sel === i ? ' sel' : '')); r.appendChild(dot(h.color)); r.appendChild(el('div', 'nm', h.name)); r.appendChild(el('div', null, 'Quote ×' + h.odds));
        if (ph === 'betting') r.onclick = () => { sel = i; build(prevPhase); };
        body.appendChild(r);
      });
      if (ph === 'betting') {
        const amt = stakeBox(() => Math.max(1, state.me.balance), () => betStake, (v) => { betStake = v; });
        const go = el('button', 'full', sel == null ? 'Wähle zuerst ein Pferd' : 'Wette setzen'); go.disabled = sel == null;
        go.onclick = async () => {
          const v = parseInt(amt.input.value, 10) || 0;
          if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
          if (v > state.me.balance) return toast('Nicht genug Coins', true);
          go.disabled = true; const r = await rpc('place_bet', { p_horse: sel, p_stake: v });
          if (r.error) { go.disabled = false; return toast(errText(r.error), true); }
          state.me.balance = Number(r.data.balance); setBal(); sfx.coin(); toast('Wette gesetzt'); load();
        };
        amt.style.marginTop = '10px'; body.appendChild(amt); body.appendChild(go);
      }
    } else {
      refs.track = trackEl(); body.appendChild(refs.track); refs.order = el('p', 'hint'); body.appendChild(refs.order);
      if (ph === 'racing') { if (prevPhase === 'betting' || prevPhase === 'waiting') sfx.gun(); gal = setInterval(sfx.hoof, 300); }
      if (ph === 'finished') { const wn = st.horses[st.winner], b = el('div', 'res', '🏆 Sieger: ' + wn.name); b.style.color = wn.color; body.appendChild(b); }
    }
    const bl = betsList(); if (bl.childNodes.length) { bl.style.marginTop = '12px'; body.appendChild(bl); }
    if (st.last && ph !== 'finished') {
      const lc = el('div', 'card'); lc.appendChild(el('h2', null, 'Letztes Rennen'));
      const p = el('p'); p.appendChild(dot(st.last.color)); p.appendChild(document.createTextNode(' Sieger: ' + st.last.name + ' (' + st.last.date + ')')); lc.appendChild(p);
      if (st.last.my_stake > 0) lc.appendChild(el('p', 'hint', 'Dein Ergebnis: ' + (st.last.my_net > 0 ? '+' : '') + st.last.my_net + ' Coins'));
      lastBox.appendChild(lc);
    }
    frame(true);
  }
  function frame(force) {
    if (!alive || !st) return;
    const now = Date.now() + offset, ph = racePhase(st, now);
    if (ph !== drawn && !reloading) { load(); return; }
    if (refs.count) refs.count.textContent = ph === 'waiting' ? 'Wetten öffnen in ' + hms(st.t_open_ms - now) : ph === 'betting' ? 'Rennstart in ' + hms(st.t_start_ms - now) : ph === 'racing' ? 'Noch ' + hms(st.t_end_ms - now) + ' bis zum Ziel' : 'Nächstes Rennen in ' + hms((st.next_start_ms || now) - now);
    if (refs.runners && model) {
      const t = ph === 'racing' ? Math.max(0, Math.min(1, (now - st.t_start_ms) / (st.t_end_ms - st.t_start_ms))) : 1, pos = [];
      refs.runners.forEach((rn, i) => { const p = racePos(model, i, t); pos.push([p, i]); const w = refs.lanes[i].clientWidth - rn.offsetWidth - 18; rn.style.left = Math.max(0, w) * p + 'px'; });
      if (refs.order && (force || now - lastOrder > 500)) {
        lastOrder = now; pos.sort((a, b) => b[0] - a[0]);
        refs.order.textContent = (ph === 'racing' ? 'Zwischenstand: ' : 'Endstand: ') + pos.map((x, k) => (k + 1) + '. ' + st.horses[x[1]].name).join(' · ');
      }
    }
    raf = requestAnimationFrame(() => frame(false));
  }
  poll = setInterval(() => { if (!reloading && !document.hidden) load(); }, 30000);
  load();
}
