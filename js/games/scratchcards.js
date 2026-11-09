import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, onLeave, stakeBox, coinsText } from '../ui.js';
import { sfx } from '../audio.js';

let stake = 1;
const colsFor = (n) => (n <= 4 ? 2 : n <= 6 ? 3 : n === 9 ? 3 : 4);

export function init(box, ctx) {
  const cfg = ctx.cfg.scratch, icon = {}; cfg.symbols.forEach((s) => { icon[s.id] = s.icon; });
  let alive = true, busy = false; onLeave(() => { alive = false; });
  stake = Math.max(1, Math.min(stake, Math.max(1, state.me.balance)));
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Rubbellose'));
  c.appendChild(el('p', 'hint', 'Kaufe ein Los und rubble die Felder frei. Gleiche Symbole gewinnen: je mehr gleiche, desto mehr Coins. Das Ergebnis steht beim Kauf fest und wird sofort verbucht.'));
  const tl = el('div', 'tierlist');
  cfg.tiers.filter((t) => t.matches > 0).forEach((t) => tl.appendChild(el('div', null, t.matches + ' gleiche: ×' + t.mult)));
  c.appendChild(tl);
  const grid = el('div', 'scratch'); c.appendChild(grid);
  const res = el('div', 'res'); c.appendChild(res);
  const sbx = stakeBox(() => Math.max(1, state.me.balance), () => stake, (v) => { stake = v; });
  c.appendChild(sbx);
  const buy = el('button', 'full', 'Los kaufen'); c.appendChild(buy);
  const all = el('button', 'sec full', 'Alles aufdecken'); all.style.marginTop = '8px'; all.style.display = 'none'; c.appendChild(all);
  box.appendChild(c);

  function makeScratch(cellEl, onDone) {
    const cv = el('canvas'); cellEl.appendChild(cv);
    const dpr = window.devicePixelRatio || 1, w = cellEl.clientWidth, h = cellEl.clientHeight;
    cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
    const g = cv.getContext('2d'); g.scale(dpr, dpr);
    const grad = g.createLinearGradient(0, 0, w, h); grad.addColorStop(0, '#f5d76e'); grad.addColorStop(.5, '#d4af37'); grad.addColorStop(1, '#a8841f');
    g.fillStyle = grad; g.fillRect(0, 0, w, h);
    g.fillStyle = 'rgba(255,255,255,.35)'; g.font = '700 ' + w * 0.45 + 'px system-ui'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText('?', w / 2, h / 2 + 2);
    let down = false, last = null, done = false, moves = 0, lastSound = 0;
    const pos = (e) => { const r = cv.getBoundingClientRect(); return [(e.clientX - r.left) * (w / r.width), (e.clientY - r.top) * (h / r.height)]; };
    const dot = (x, y) => { g.globalCompositeOperation = 'destination-out'; g.beginPath(); g.arc(x, y, Math.max(10, w * 0.17), 0, 6.283); g.fill(); };
    function check() {
      if (done) return;
      const d = g.getImageData(0, 0, cv.width, cv.height).data; let clear = 0, tot = 0;
      for (let i = 3; i < d.length; i += 64) { tot++; if (d[i] < 40) clear++; }
      if (clear / tot > 0.5) reveal();
    }
    function reveal() { if (done) return; done = true; cv.style.transition = 'opacity .35s'; cv.style.opacity = '0'; setTimeout(() => cv.remove(), 380); onDone(); }
    cv.addEventListener('pointerdown', (e) => { down = true; cv.setPointerCapture(e.pointerId); last = pos(e); dot(last[0], last[1]); });
    cv.addEventListener('pointermove', (e) => {
      if (!down) return; const p = pos(e);
      for (let t = 0; t <= 1; t += 0.25) dot(last[0] + (p[0] - last[0]) * t, last[1] + (p[1] - last[1]) * t);
      last = p; moves++; if (performance.now() - lastSound > 90) { sfx.scratch(); lastSound = performance.now(); } if (moves % 5 === 0) check();
    });
    const up = () => { down = false; check(); };
    cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
    return reveal;
  }
  buy.onclick = async () => {
    if (busy) return;
    const v = parseInt(sbx.input.value, 10) || 0;
    if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
    if (v > state.me.balance) return toast('Nicht genug Coins', true);
    busy = true; buy.disabled = true; res.textContent = ''; res.style.color = ''; grid.innerHTML = '';
    const r = await rpc('scratch_buy', { p_stake: v });
    if (!alive) return;
    if (r.error) { busy = false; buy.disabled = false; return toast(errText(r.error), true); }
    const d = r.data; sfx.buy();
    grid.style.gridTemplateColumns = 'repeat(' + colsFor(d.cells.length) + ',1fr)';
    let left = d.cells.length; const reveals = [], cellEls = [];
    d.cells.forEach((id) => { const ce = el('div', 'sc-cell', icon[id] || '?'); ce.dataset.sym = id; grid.appendChild(ce); cellEls.push(ce); });
    const finish = () => {
      state.me.balance = Number(d.balance); setBal(); busy = false; buy.disabled = false; all.style.display = 'none';
      if (d.matches > 0) cellEls.forEach((ce) => ce.classList.add(ce.dataset.sym === d.symbol ? 'win' : 'dim'));
      if (d.net > 0) { res.textContent = '🎉 ' + d.matches + ' gleiche! +' + coinsText(d.net); res.style.color = 'var(--green)'; d.mult >= 20 ? sfx.big() : sfx.win(); }
      else if (d.net === 0) { res.textContent = d.matches + ' gleiche – Einsatz zurück'; sfx.coin(); }
      else if (d.payout > 0) { res.textContent = d.matches + ' gleiche, aber ' + coinsText(d.payout) + ' Auszahlung (−' + (-d.net) + ')'; res.style.color = 'var(--red)'; sfx.lose(); }
      else { res.textContent = 'Leider nichts. −' + coinsText(v); res.style.color = 'var(--red)'; sfx.lose(); }
    };
    requestAnimationFrame(() => {
      cellEls.forEach((ce) => { reveals.push(makeScratch(ce, () => { left--; if (left === 0) finish(); })); });
      all.style.display = 'block'; all.onclick = () => reveals.forEach((f) => f());
    });
  };
}
