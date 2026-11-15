import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, onLeave, stakeBox, resultLine, celebrate } from '../ui.js';
import { sfx } from '../audio.js';

let risk = 'medium', stake = 1;
const RISKS = [['low', 'Niedrig'], ['medium', 'Mittel'], ['high', 'Hoch']];

export function init(box, ctx) {
  const cfg = ctx.cfg.plinko, n = cfg.rows;
  let alive = true, busy = false, raf = 0, ball = null, hot = -1, flashUntil = 0, trail = [], W = 0, H = 0, dx = 0, dy = 0, cx = 0, top = 0, ySlot = 0, dpr = 1;
  const pinHit = new Map();
  onLeave(() => { alive = false; cancelAnimationFrame(raf); });
  stake = Math.max(1, Math.min(stake, Math.max(1, state.me.balance)));

  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Plinko'));
  const seg = el('div', 'seg risks'); seg.style.marginBottom = '12px';
  RISKS.forEach(([k, t]) => { const b = el('button', risk === k ? 'on' : '', t); b.onclick = () => { if (busy) return; risk = k; seg.querySelectorAll('button').forEach((x) => x.classList.remove('on')); b.classList.add('on'); potential(); frame(); }; seg.appendChild(b); });
  c.appendChild(seg);
  const cv = el('canvas', 'plinko'); c.appendChild(cv);
  const res = el('div', 'res'); res.style.marginTop = '12px'; c.appendChild(res);
  const sbx = stakeBox(() => Math.max(1, state.me.balance), () => stake, (v) => { stake = v; potential(); });
  c.appendChild(sbx);
  const pot = el('p', 'hint'); pot.style.marginBottom = '10px'; c.appendChild(pot);
  const go = el('button', 'full', 'Kugel fallen lassen'); c.appendChild(go);
  box.appendChild(c);
  sbx.input.addEventListener('input', potential);
  function potential() { const mx = Math.max(...cfg.levels[risk]), v = parseInt(sbx.input.value, 10) || 0; pot.textContent = 'Möglicher Gewinn: bis ' + Math.floor(v * mx) + ' Coins (x' + mx + ')'; }

  function layout() {
    const avail = Math.floor(cv.parentElement.clientWidth - 36);
    if (avail < 120) return false;
    const w = Math.min(avail, 720);
    if (w === W) return true;
    dpr = Math.min(window.devicePixelRatio || 1, 2); W = w; dx = W / (n + 2); dy = dx * 0.86; cx = W / 2; top = 30; ySlot = top + (n - 1) * dy + dy * 1.25; H = Math.round(ySlot + 44);
    cv.style.width = W + 'px'; cv.style.height = H + 'px'; cv.style.margin = '0 auto'; cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    return true;
  }
  const slotX = (k) => cx + (k - n / 2) * dx;
  const slotColor = (m) => (m >= 10 ? '#d4af37' : m >= 3 ? '#c9803a' : m >= 1 ? '#4fb477' : '#8a4a45');
  function draw(now) {
    if (!layout()) return;
    const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
    const pr = Math.max(2, dx * 0.075);
    for (let i = 0; i < n; i++) for (let j = 0; j < i + 3; j++) {
      const k = i * 40 + j, hit = pinHit.get(k), age = hit ? now - hit : 999;
      g.fillStyle = age < 260 ? '#d4af37' : '#cfd1d6'; g.beginPath(); g.arc(cx + (j - (i + 2) / 2) * dx, top + i * dy, age < 260 ? pr * 1.5 : pr, 0, 6.283); g.fill();
    }
    const mult = cfg.levels[risk];
    for (let k = 0; k <= n; k++) {
      const x = slotX(k), w = dx * 0.86, on = k === hot && now < flashUntil;
      g.fillStyle = slotColor(mult[k]); g.globalAlpha = on ? 1 : 0.7;
      g.beginPath(); if (g.roundRect) g.roundRect(x - w / 2, ySlot, w, 26, 5); else g.rect(x - w / 2, ySlot, w, 26); g.fill(); g.globalAlpha = 1;
      g.fillStyle = '#0f1012'; g.font = '700 ' + Math.max(8, Math.min(12, dx * 0.33)) + 'px system-ui'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText('x' + mult[k], x, ySlot + 14);
    }
    const br = Math.max(4, dx * 0.2);
    trail.forEach((p, i) => { g.globalAlpha = (i + 1) / trail.length * 0.25; g.fillStyle = '#d4af37'; g.beginPath(); g.arc(p[0], p[1], br * (i + 1) / trail.length, 0, 6.283); g.fill(); });
    g.globalAlpha = 1;
    if (ball) { g.shadowColor = 'rgba(212,175,55,.7)'; g.shadowBlur = 10; g.fillStyle = '#e6c25a'; g.beginPath(); g.arc(ball.x, ball.y, br, 0, 6.283); g.fill(); g.shadowBlur = 0; }
  }
  function frame() { cancelAnimationFrame(raf); raf = requestAnimationFrame((t) => { if (!alive) return; draw(t); if (ball || performance.now() < flashUntil) frame(); }); }

  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  async function animate(path) {
    const xs = [cx]; let k = 0;
    for (let i = 0; i < n; i++) { k += path[i]; xs.push(cx + (2 * k - (i + 1)) * dx / 2); }
    const pts = [[cx, top - dy * 1.1]];
    for (let i = 0; i < n; i++) pts.push([xs[i], top + i * dy]);
    pts.push([xs[n], ySlot - 3]);
    ball = { x: pts[0][0], y: pts[0][1] }; trail = []; pinHit.clear();
    frame();
    for (let i = 1; i < pts.length && alive; i++) {
      const a = pts[i - 1], b = pts[i], last = i === pts.length - 1, dur = i === 1 ? 320 : last ? 300 : 250 + Math.min(40, (i / n) * 50), t0 = performance.now();
      await new Promise((resolve) => {
        const step = (now) => {
          if (!alive) return resolve();
          const t = Math.min(1, (now - t0) / dur), ey = t * t, ex = 1 - Math.pow(1 - t, 2);
          ball.x = a[0] + (b[0] - a[0]) * ex;
          ball.y = a[1] + (b[1] - a[1]) * ey - Math.sin(Math.PI * Math.min(1, t * 1.15)) * (1 - t) * dy * 0.42;
          trail.push([ball.x, ball.y]); if (trail.length > 9) trail.shift();
          if (t < 1) requestAnimationFrame(step); else resolve();
        };
        requestAnimationFrame(step);
      });
      if (!last) { pinHit.set((i - 1) * 40 + Math.round((xs[i - 1] - cx) / dx + (i + 1) / 2 + 0.0001), performance.now()); sfx.ping(i); }
    }
    for (let j = 0; j < 3 && alive; j++) {
      const amp = dy * 0.28 / (j + 1), t0 = performance.now();
      await new Promise((resolve) => { const step = (now) => { const t = Math.min(1, (now - t0) / 150); ball.y = ySlot - 3 - Math.sin(Math.PI * t) * amp; if (t < 1) requestAnimationFrame(step); else resolve(); }; requestAnimationFrame(step); });
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
    hot = d.slot; flashUntil = performance.now() + 1400; ball = { x: slotX(d.slot), y: ySlot - 3 }; frame();
    state.me.balance = Number(d.balance); setBal();
    const rl = resultLine(d.payout, v);
    res.textContent = 'x' + d.mult + ': ' + rl.t; res.style.color = rl.c;
    if (d.net > 0) { d.mult >= 10 ? sfx.big() : sfx.win(); celebrate(d.payout, v); } else if (d.payout > 0) sfx.coin(); else sfx.lose();
    busy = false; go.disabled = false;
    setTimeout(() => { if (alive && !busy) { ball = null; trail = []; frame(); } }, 1500);
  };
  potential();
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(() => { W = 0; frame(); }) : null;
  if (ro) { ro.observe(cv.parentElement); onLeave(() => ro.disconnect()); }
  requestAnimationFrame(() => frame());
}
