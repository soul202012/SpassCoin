import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, sleep, onLeave, stakeBox, coinsText } from '../ui.js';
import { sfx } from '../audio.js';

let risk = 'medium', stake = 1;
const RISKS = [['low', 'Niedrig'], ['medium', 'Mittel'], ['high', 'Hoch']];

export function init(box, ctx) {
  const cfg = ctx.cfg.plinko, n = cfg.rows;
  let alive = true, busy = false, raf = 0, ball = null, hot = -1, flash = 0;
  onLeave(() => { alive = false; cancelAnimationFrame(raf); });
  stake = Math.max(1, Math.min(stake, Math.max(1, state.me.balance)));

  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Plinko'));
  c.appendChild(el('p', 'hint', 'Die Kugel fällt durch die Pins und landet in einem Feld. Der Faktor des Felds mal dein Einsatz ist dein Gewinn.'));
  const seg = el('div', 'seg risks');
  RISKS.forEach(([k, t]) => { const b = el('button', risk === k ? 'on' : '', t); b.onclick = () => { if (busy) return; risk = k; seg.querySelectorAll('button').forEach((x) => x.classList.remove('on')); b.classList.add('on'); draw(); potential(); }; seg.appendChild(b); });
  c.appendChild(seg);
  const cv = el('canvas', 'plinko'); c.appendChild(cv);
  const res = el('div', 'res'); c.appendChild(res);
  const sbx = stakeBox(() => Math.max(1, state.me.balance), () => stake, (v) => { stake = v; potential(); });
  c.appendChild(sbx);
  const pot = el('p', 'hint'); c.appendChild(pot);
  const go = el('button', 'full', 'Kugel fallen lassen'); c.appendChild(go);
  box.appendChild(c);
  sbx.input.addEventListener('input', potential);
  function potential() {
    const mx = Math.max(...cfg.levels[risk]), v = parseInt(sbx.input.value, 10) || 0;
    pot.textContent = 'Möglicher Gewinn: bis ' + Math.floor(v * mx) + ' Coins (höchster Faktor ×' + mx + ')';
  }

  // Geometrie
  let W = 0, H = 0, dx = 0, dy = 0, cx = 0, top = 0, ySlot = 0, dpr = 1;
  function layout() {
    dpr = window.devicePixelRatio || 1; W = Math.min(cv.parentElement.clientWidth - 32, 560) || 320;
    dx = W / (n + 2); dy = dx * 0.88; cx = W / 2; top = 34; ySlot = top + (n - 1) * dy + dy * 1.25; H = ySlot + 42;
    cv.style.width = W + 'px'; cv.style.height = H + 'px'; cv.style.margin = '0 auto'; cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
  }
  const slotX = (k) => cx + (k - n / 2) * dx;
  function slotColor(m) { return m >= 10 ? '#f5b301' : m >= 3 ? '#f97316' : m >= 1 ? '#22c55e' : '#ef4444'; }
  function draw() {
    if (!alive) return;
    const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
    g.fillStyle = '#e8e4d8';
    for (let i = 0; i < n; i++) for (let j = 0; j < i + 3; j++) { g.beginPath(); g.arc(cx + (j - (i + 2) / 2) * dx, top + i * dy, Math.max(2, dx * 0.07), 0, 6.283); g.fill(); }
    const mult = cfg.levels[risk];
    for (let k = 0; k <= n; k++) {
      const x = slotX(k), w = dx * 0.88, y = ySlot, h = 26;
      g.fillStyle = slotColor(mult[k]); g.globalAlpha = k === hot && flash > 0 ? 1 : 0.78;
      g.beginPath(); g.roundRect ? g.roundRect(x - w / 2, y, w, h, 6) : g.rect(x - w / 2, y, w, h); g.fill(); g.globalAlpha = 1;
      g.fillStyle = '#111'; g.font = '700 ' + Math.max(8, Math.min(12, dx * 0.34)) + 'px system-ui'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText('×' + mult[k], x, y + h / 2 + 1);
    }
    if (ball) {
      g.shadowColor = 'rgba(245,179,1,.8)'; g.shadowBlur = 12; g.fillStyle = '#f5b301';
      g.beginPath(); g.arc(ball.x, ball.y, Math.max(4, dx * 0.2), 0, 6.283); g.fill(); g.shadowBlur = 0;
    }
  }
  function loop() { if (!alive) return; if (flash > 0) flash -= 1; draw(); raf = requestAnimationFrame(loop); }

  // Kugel entlang des vom Server festgelegten Wegs animieren
  async function animate(path) {
    const xs = [cx], ys = [];
    let k = 0; for (let i = 0; i < n; i++) { k += path[i]; xs.push(cx + (2 * k - (i + 1)) * dx / 2); }
    for (let i = 0; i < n; i++) ys.push(top + i * dy); ys.push(ySlot - 4);
    ball = { x: cx, y: top - dy };
    const pts = [[cx, top - dy]].concat(xs.map((x, i) => [x, ys[i]]));
    for (let i = 1; i < pts.length && alive; i++) {
      const a = pts[i - 1], b = pts[i], dur = i === 1 ? 300 : 260, t0 = performance.now();
      await new Promise((resolve) => {
        const step = (now) => {
          if (!alive) return resolve();
          const t = Math.min(1, (now - t0) / dur);
          ball.x = a[0] + (b[0] - a[0]) * (1 - Math.pow(1 - t, 2));
          ball.y = a[1] + (b[1] - a[1]) * t * t - Math.sin(Math.PI * Math.min(1, t * 1.1)) * (1 - t) * dy * 0.45;
          if (t < 1) requestAnimationFrame(step); else resolve();
        };
        requestAnimationFrame(step);
      });
      if (i < pts.length - 1) sfx.ping(i);
    }
  }
  go.onclick = async () => {
    if (busy) return;
    const v = parseInt(sbx.input.value, 10) || 0;
    if (v < 1) return toast('Bitte einen Einsatz eingeben', true);
    if (v > state.me.balance) return toast('Nicht genug Coins', true);
    busy = true; go.disabled = true; res.textContent = ''; res.style.color = ''; hot = -1;
    const r = await rpc('plinko_drop', { p_stake: v, p_risk: risk });
    if (!alive) return;
    if (r.error) { busy = false; go.disabled = false; return toast(errText(r.error), true); }
    const d = r.data;
    await animate(d.path); if (!alive) return;
    hot = d.slot; flash = 40; ball = { x: slotX(d.slot), y: ySlot + 13 };
    state.me.balance = Number(d.balance); setBal(); busy = false; go.disabled = false;
    if (d.net > 0) { res.textContent = '🎉 ×' + d.mult + ' → +' + coinsText(d.net) + ' (Auszahlung ' + d.payout + ')'; res.style.color = 'var(--green)'; d.mult >= 10 ? sfx.big() : sfx.win(); }
    else if (d.net === 0) { res.textContent = '×' + d.mult + ' → ±0'; sfx.coin(); }
    else { res.textContent = '×' + d.mult + ' → −' + coinsText(-d.net) + ' (Auszahlung ' + d.payout + ')'; res.style.color = 'var(--red)'; sfx.lose(); }
    setTimeout(() => { if (alive && !busy) ball = null; }, 1200);
  };
  layout(); potential(); loop();
  const onResize = () => { layout(); };
  window.addEventListener('resize', onResize); onLeave(() => window.removeEventListener('resize', onResize));
}
