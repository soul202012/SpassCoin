// Kleine Hilfsfunktionen für die Oberfläche
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
export function modal(title, text, icon, onClose) {
  const m = el('div', 'modal'), b = el('div', 'box');
  b.appendChild(el('div', 'big', icon || '🎉'));
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

// Aufräumen beim Verlassen einer Ansicht (Timer, Animationen, Listener), damit nichts doppelt läuft
let cleanups = [];
export const onLeave = (fn) => { cleanups.push(fn); };
export function runCleanup() { const c = cleanups; cleanups = []; c.forEach((f) => { try { f(); } catch (e) { /* ignore */ } }); }

// Einsatzfeld mit Schnellauswahl
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

// Spielkarte: 0..51, Rang = Karte % 13 (0 = Ass), Farbe = Karte / 13
const RANKS = ['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'];
const SUITS = ['♠', '♥', '♦', '♣'];
export function cardEl(c, cls) {
  const red = c >= 0 && (Math.floor(c / 13) === 1 || Math.floor(c / 13) === 2);
  const d = el('div', 'pcard' + (c < 0 ? ' back' : '') + (red ? ' red' : '') + (cls ? ' ' + cls : ''));
  if (c >= 0) { d.appendChild(document.createTextNode(RANKS[c % 13])); d.appendChild(el('span', null, SUITS[Math.floor(c / 13)])); }
  return d;
}
export const cardValue = (c) => (c % 13 === 0 ? 14 : (c % 13) + 1);

// Einfaches Liniendiagramm als SVG
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
                  `<path d="${d}" fill="none" stroke="${col}" stroke-width="2" vector-effect="non-scaling-stroke"/>`;
  return svg;
}
