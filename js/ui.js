export function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
export function inp(placeholder, type, inputMode) {
  const i = el('input');
  i.placeholder = placeholder || '';
  i.type = type || 'text';
  if (inputMode) i.inputMode = inputMode;
  return i;
}
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const r2 = (x) => Math.round(x * 100) / 100;
export const sgn = (x) => { x = r2(x); return (x > 0 ? '+' : '') + x; };
export const coinsText = (n) => n + (n === 1 ? ' Coin' : ' Coins');
export const errText = (e) => (e && e.message ? e.message : 'Das hat nicht geklappt.');
export const fmtDate = (d) => new Date(d).toLocaleString('de-CH', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
export const fmtDay = (d) => new Date(d).toLocaleDateString('de-CH', { day: '2-digit', month: '2-digit' });
export const zurich = (offsetDays = 0) => new Date(Date.now() + offsetDays * 86400000).toLocaleDateString('sv-SE', { timeZone: 'Europe/Zurich' });
export function hms(ms) {
  ms = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(ms / 3600), m = Math.floor((ms % 3600) / 60), s = ms % 60;
  return (h ? h + ':' : '') + String(m).padStart(h ? 2 : 1, '0') + ':' + String(s).padStart(2, '0');
}

export function toast(text, bad) {
  const d = el('div', 'toast' + (bad ? ' bad' : ''), text);
  document.body.appendChild(d);
  setTimeout(() => d.remove(), 3200);
}
export function modal(title, text, onClose) {
  const m = el('div', 'modal'), b = el('div', 'box');
  b.appendChild(el('h2', null, title));
  b.appendChild(el('p', null, text));
  const ok = el('button', null, 'Weiter');
  ok.onclick = () => { m.remove(); if (onClose) onClose(); };
  b.appendChild(ok); m.appendChild(b); document.body.appendChild(m);
}
export function confirmBox(title, text, okLabel) {
  return new Promise((resolve) => {
    const m = el('div', 'modal'), b = el('div', 'box');
    b.appendChild(el('h2', null, title)); b.appendChild(el('p', null, text));
    const row = el('div', 'btns');
    const no = el('button', 'sec', 'Abbrechen'), ok = el('button', null, okLabel || 'OK');
    no.onclick = () => { m.remove(); resolve(false); };
    ok.onclick = () => { m.remove(); resolve(true); };
    row.appendChild(no); row.appendChild(ok); b.appendChild(row); m.appendChild(b); document.body.appendChild(m);
  });
}

let cleanups = [];
export const onLeave = (fn) => { cleanups.push(fn); };
export function runCleanup() { const c = cleanups; cleanups = []; c.forEach((f) => { try { f(); } catch (e) { /* ignore */ } }); }

export function stakeBox(getMax, getVal, setVal) {
  const w = el('div');
  const i = inp('Einsatz', 'number', 'numeric');
  i.min = '1'; i.value = getVal();
  i.oninput = () => setVal(parseInt(i.value, 10) || 0);
  const q = el('div', 'btns'); q.style.marginBottom = '10px';
  [['1', () => 1], ['½', () => Math.max(1, Math.floor((parseInt(i.value, 10) || 1) / 2))],
   ['2×', () => Math.min(getMax(), (parseInt(i.value, 10) || 1) * 2)], ['Alles', () => getMax()]].forEach(([label, fn]) => {
    const b = el('button', 'sec small', label);
    b.onclick = () => { const v = Math.max(1, fn()); i.value = v; setVal(v); };
    q.appendChild(b);
  });
  w.appendChild(el('div', 'lbl', 'Einsatz (Coins)')); w.appendChild(i); w.appendChild(q);
  w.input = i;
  return w;
}

const RANKS = ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'];
const SUITS = ['♠', '♥', '♦', '♣'];
export function cardEl(c, cls) {
  const red = c >= 0 && (Math.floor(c / 13) === 1 || Math.floor(c / 13) === 2);
  const d = el('div', 'pcard' + (c < 0 ? ' back' : '') + (red ? ' red' : '') + (cls ? ' ' + cls : ''));
  if (c >= 0) { d.appendChild(document.createTextNode(RANKS[c % 13])); d.appendChild(el('span', null, SUITS[Math.floor(c / 13)])); }
  return d;
}
export const cardValue = (c) => (c % 13 === 0 ? 14 : (c % 13) + 1);

export function lineChart(points, opts = {}) {
  const W = 320, H = opts.height || 150, P = 6;
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('preserveAspectRatio', 'none');
  svg.setAttribute('class', opts.cls || 'chart');
  if (points.length < 2) { return svg; }
  const ys = points.map((p) => p[1]);
  let mn = Math.min(...ys), mx = Math.max(...ys);
  if (mn === mx) { mn -= 1; mx += 1; }
  const x = (i) => P + (i / (points.length - 1)) * (W - 2 * P);
  const y = (v) => H - P - ((v - mn) / (mx - mn)) * (H - 2 * P);
  const d = points.map((p, i) => (i ? 'L' : 'M') + x(i).toFixed(1) + ',' + y(p[1]).toFixed(1)).join(' ');
  const up = points[points.length - 1][1] >= points[0][1];
  const col = opts.color || (up ? 'var(--green)' : 'var(--red)');
  svg.innerHTML = `<path d="${d} L${x(points.length - 1).toFixed(1)},${H} L${x(0).toFixed(1)},${H} Z" fill="${col}" opacity=".12"/>` +
                  `<path d="${d}" fill="none" stroke="${col}" stroke-width="2" vector-effect="non-scaling-stroke"/>` +
                  // Punkte als runde Striche der Länge 0: bleiben rund, obwohl das Diagramm in die Breite gezogen wird
                  (opts.dots ? `<path d="${points.map((p, i) => 'M' + x(i).toFixed(1) + ',' + y(p[1]).toFixed(1) + 'h0').join('')}" stroke="${col}" stroke-width="6" stroke-linecap="round" vector-effect="non-scaling-stroke"/>` : '');
  return svg;
}

export function resultLine(payout, stake) {
  if (payout > stake) return { t: '+' + coinsText(payout), c: 'var(--green)' };
  if (payout > 0) return { t: '+' + coinsText(payout), c: '' };
  return { t: '\u2212' + coinsText(stake), c: 'var(--red)' };
}
export const isBigWin = (payout, stake) => payout >= 20 && payout >= stake * 10;

// Konfetti-Fontäne auf einer Leinwand über der Seite.
// Flüssig, weil: Bewegung nach echter Zeit (nicht pro Bild), Emojis nur einmal vorgezeichnet (drawImage statt fillText),
// eine einzige Leinwand für alle Ausbrüche und keine Schatten/Filter pro Teilchen.
const reduceMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const sprites = new Map();
function sprite(e) {
  if (sprites.has(e)) return sprites.get(e);
  const c = document.createElement('canvas'); c.width = c.height = 64;
  const g = c.getContext('2d'); g.font = '48px "Apple Color Emoji","Segoe UI Emoji","Noto Color Emoji",sans-serif';
  g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(e, 32, 36); sprites.set(e, c); return c;
}
let fx = null; // { cv, g, ps, W, H, last }
export function confetti(n, emojis) {
  if (reduceMotion()) return;
  if (!fx) {
    const cv = el('canvas', 'fx-canvas'), dpr = Math.min(1.5, window.devicePixelRatio || 1);
    cv.width = innerWidth * dpr; cv.height = innerHeight * dpr; document.body.appendChild(cv);
    const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0);
    fx = { cv, g, ps: [], W: innerWidth, H: innerHeight, last: 0, d: dpr };
    requestAnimationFrame(tick);
  }
  const a = document.querySelector('.gamewrap .res, .gamewrap'), r = a ? a.getBoundingClientRect() : null;
  const ox = r ? r.left + r.width / 2 : fx.W / 2, oy = r ? Math.min(fx.H * 0.8, Math.max(80, r.top)) : fx.H * 0.6;
  const acc = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#d4af37';
  const cols = [acc, acc, '#ffd54a', '#ff4d8d', '#4dd0ff', '#7cff6b', '#b388ff', '#ffffff'];
  for (let i = 0; i < n; i++) {
    const ang = -Math.PI / 2 + (Math.random() - 0.5) * 1.5, sp = 650 + Math.random() * 850;
    const e = emojis && Math.random() < 0.3 ? emojis[(Math.random() * emojis.length) | 0] : null;
    fx.ps.push({ x: ox + (Math.random() - 0.5) * 40, y: oy, vx: Math.cos(ang) * sp, vy: Math.sin(ang) * sp,
      r: Math.random() * 6.28, vr: (Math.random() - 0.5) * 12, ph: Math.random() * 6.28, vp: 6 + Math.random() * 8,
      s: e ? 22 + Math.random() * 12 : 7 + Math.random() * 6, c: cols[(Math.random() * cols.length) | 0],
      img: e ? sprite(e) : null, t: 0, life: 2.2 + Math.random() * 1.2 });
  }
}
function tick(now) {
  const f = fx; if (!f) return;
  const dt = f.last ? Math.min(0.034, (now - f.last) / 1000) : 0.016; f.last = now;
  const g = f.g, d = f.d; g.setTransform(d, 0, 0, d, 0, 0); g.clearRect(0, 0, f.W, f.H);
  const drag = Math.pow(0.35, dt);
  f.ps = f.ps.filter((p) => {
    p.t += dt; if (p.t > p.life || p.y > f.H + 60) return false;
    p.vy += 1500 * dt; p.vx *= drag;
    if (!p.img && p.vy > 260) p.vy = 260; // Papier schwebt langsam, Münzen fallen schwer
    p.x += p.vx * dt; p.y += p.vy * dt; p.r += p.vr * dt; p.ph += p.vp * dt;
    g.globalAlpha = Math.min(1, (p.life - p.t) / 0.5);
    const cs = Math.cos(p.r) * d, sn = Math.sin(p.r) * d;
    g.setTransform(cs, sn, -sn, cs, p.x * d, p.y * d);
    if (p.img) g.drawImage(p.img, -p.s / 2, -p.s / 2, p.s, p.s);
    else { const w = p.s * Math.cos(p.ph); g.fillStyle = p.c; g.fillRect(-w / 2, -p.s / 4, w, p.s / 2); } // Breite schwankt = Schnipsel dreht sich in 3D
    return true;
  });
  g.globalAlpha = 1;
  if (f.ps.length) requestAnimationFrame(tick); else { f.cv.remove(); fx = null; }
}
// "+X" schwebt über dem Ergebnis nach oben
function floatAmount(text) {
  const anchor = document.querySelector('.gamewrap .res, .gamewrap .runline, .gamewrap');
  const r = anchor ? anchor.getBoundingClientRect() : { left: innerWidth / 2, width: 0, top: innerHeight / 2 };
  const f = el('div', 'fx-float', text); f.style.left = (r.left + r.width / 2) + 'px'; f.style.top = (r.top + window.scrollY) + 'px';
  document.body.appendChild(f); setTimeout(() => f.remove(), 1500);
}
// Bei Verlust: Spielfeld kurz schütteln
export function loseFx() {
  const w = document.querySelector('.gamewrap'); if (!w || reduceMotion()) return;
  w.animate([{ transform: 'none' }, { transform: 'translateX(-8px)' }, { transform: 'translateX(7px)' }, { transform: 'translateX(-5px)' }, { transform: 'translateX(3px)' }, { transform: 'none' }],
    { duration: 420, easing: 'cubic-bezier(.36,.07,.19,.97)' });
  if (navigator.vibrate) navigator.vibrate(60);
}
// Leuchtring um das Spielfeld: eigenes Element, nur Deckkraft und Grösse werden animiert (läuft auf der Grafikkarte)
function glowRing(strong) {
  const w = document.querySelector('.gamewrap'); if (!w || reduceMotion()) return;
  const g = el('div', 'fx-ring' + (strong ? ' strong' : '')); w.appendChild(g);
  g.animate([{ opacity: 0, transform: 'scale(.98)' }, { opacity: 1, transform: 'scale(1)', offset: 0.25 }, { opacity: 0, transform: 'scale(1.015)' }],
    { duration: strong ? 1600 : 1100, easing: 'cubic-bezier(.2,.8,.2,1)' }).onfinish = () => g.remove();
}

let bwTimer = 0;
// Jeder Gewinn feiert: kleiner Gewinn = Konfetti und "+X", ab 3× mehr Konfetti mit Münzen, ab 10× die grosse Einblendung
export function celebrate(payout, stake) {
  if (payout <= stake) return;
  const ratio = payout / Math.max(1, stake), big = isBigWin(payout, stake);
  floatAmount('+' + payout);
  glowRing(ratio >= 3);
  if (!reduceMotion()) document.querySelectorAll('.gamewrap .pcard').forEach((c, i) => {
    c.classList.add('win-glow');
    c.animate([{ transform: 'none' }, { transform: 'translateY(-12px) scale(1.07)', offset: 0.35 }, { transform: 'none' }],
      { duration: 900, delay: i * 70, easing: 'cubic-bezier(.3,1.5,.5,1)' }).onfinish = () => c.classList.remove('win-glow');
  });
  if (navigator.vibrate) navigator.vibrate(ratio >= 3 ? [40, 50, 80] : 35);
  // Fontäne: grosse Gewinne in zwei Stössen
  confetti(big ? 130 : ratio >= 3 ? 90 : 45, ratio >= 3 ? ['🪙', '✨', '🎉', '💰'] : null);
  if (big) setTimeout(() => confetti(110, ['🪙', '💰', '✨']), 380);
  if (!isBigWin(payout, stake)) return;
  const old = document.querySelector('.bigwin'); if (old) old.remove();
  clearTimeout(bwTimer);
  const o = el('div', 'bigwin'), b = el('div', 'bw-box');
  b.appendChild(el('div', 'bw-ring'));
  for (let i = 0; i < 16; i++) {
    const p = el('i', 'bw-p'), a = (i / 16) * 6.283 + Math.random() * 0.4, d = 110 + Math.random() * 140;
    p.style.setProperty('--dx', Math.cos(a) * d + 'px'); p.style.setProperty('--dy', Math.sin(a) * d + 'px'); p.style.animationDelay = Math.random() * 0.2 + 's';
    b.appendChild(p);
  }
  b.appendChild(el('div', 'bw-label', 'Grosser Gewinn'));
  const amt = el('div', 'bw-amt', '+0'); b.appendChild(amt);
  b.appendChild(el('div', 'bw-sub', 'Einsatz ' + coinsText(stake)));
  o.appendChild(b); document.body.appendChild(o);
  const t0 = performance.now();
  const step = (now) => {
    const k = Math.min(1, (now - t0) / 1000), e = 1 - Math.pow(1 - k, 3);
    amt.textContent = '+' + Math.round(payout * e);
    if (k < 1 && o.isConnected) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
  bwTimer = setTimeout(() => o.remove(), 3300);
}
