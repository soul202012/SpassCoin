import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, sleep, onLeave } from '../ui.js';
import { sfx } from '../audio.js';

let ch = null;

export async function init(box, ctx) {
  const cur = await rpc('chest_current');
  ch = { box, stake: ctx.gi.chest_stake, phase: 'idle', opened: {}, running: 0, id: null, cells: [], slot: [] };
  if (cur.data) { ch.id = cur.data.id; ch.stake = cur.data.stake; ch.running = cur.data.running; cur.data.opened.forEach((o) => { ch.opened[o.index] = o.value; }); ch.phase = 'play'; }
  const onResize = () => applyPos();
  window.addEventListener('resize', onResize);
  onLeave(() => { window.removeEventListener('resize', onResize); ch = null; });
  build();
}
function setCell(i, st, v, dim) {
  const c = ch.cells[i], f = c.firstChild; f.innerHTML = '';
  c.className = 'chest' + (st !== 'closed' ? ' open' : '') + (st === 'bomb' ? ' bomb' : '') + (dim ? ' dim' : '');
  if (st === 'closed') f.textContent = '🎁'; else if (st === 'bomb') f.textContent = '💣';
  else { f.appendChild(document.createTextNode('🪙')); f.appendChild(el('small', null, '+' + v)); }
}
function applyPos() {
  if (!ch || !ch.cells.length) return;
  ch.cells.forEach((o, i) => { const t = ch.cells[ch.slot[i]]; o.style.transform = 'translate(' + (t.offsetLeft - o.offsetLeft) + 'px,' + (t.offsetTop - o.offsetTop) + 'px)'; });
}
function build() {
  const box = ch.box; box.innerHTML = '';
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Truhen-Spiel'));
  ch.info = el('p', 'hint'); c.appendChild(ch.info);
  const grid = el('div', 'chests'); ch.cells = []; ch.slot = [];
  for (let i = 0; i < 12; i++) {
    const d = el('button', 'chest'); d.type = 'button'; d.appendChild(el('div', 'face'));
    d.onclick = () => openChest(i);
    ch.cells.push(d); ch.slot.push(i); grid.appendChild(d); setCell(i, 'closed');
  }
  c.appendChild(grid);
  ch.run = el('div', 'runline'); c.appendChild(ch.run);
  ch.act = el('div', 'btns'); c.appendChild(ch.act);
  const rules = el('p', 'hint', 'Du siehst zuerst, was in den Truhen ist. Dann werden sie gemischt und du öffnest sie nacheinander. Eine Bombe zerstört deinen ganzen Gewinn und den Einsatz. Du kannst nach jeder Truhe aussteigen. Die Inhalte werden nach dem Mischen zufällig verteilt.');
  rules.style.marginTop = '12px'; c.appendChild(rules); box.appendChild(c);
  if (ch.phase === 'play') Object.keys(ch.opened).forEach((k) => setCell(+k, 'coin', ch.opened[k]));
  update();
}
function update() {
  ch.cells.forEach((c, i) => { c.disabled = ch.phase !== 'play' || ch.opened[i] !== undefined || !!ch.busy; });
  ch.act.innerHTML = '';
  const st = ch.stake + (ch.stake === 1 ? ' Coin' : ' Coins');
  if (ch.phase === 'idle') { ch.info.textContent = 'Einsatz pro Spiel: ' + st + '.'; ch.run.textContent = ''; const b = el('button', null, 'Spiel starten'); b.onclick = start; ch.act.appendChild(b); }
  else if (ch.phase === 'preview') { ch.info.textContent = 'Merk dir, was in den Truhen ist …'; ch.run.textContent = ''; }
  else if (ch.phase === 'shuffle') { ch.info.textContent = 'Die Truhen werden gemischt …'; ch.run.textContent = ''; }
  else if (ch.phase === 'play') {
    const n = Object.keys(ch.opened).length;
    ch.info.textContent = 'Wähle eine Truhe. Einsatz: ' + st + '.'; ch.run.textContent = 'Gewinn bisher: ' + ch.running + (ch.running === 1 ? ' Coin' : ' Coins');
    const o = el('button', 'ok', 'Aussteigen: +' + ch.running + ' Coins einlösen'); o.disabled = n === 0 || !!ch.busy; o.onclick = cash; ch.act.appendChild(o);
  } else if (ch.phase === 'over') { const a = el('button', null, 'Nochmal spielen'); a.onclick = again; ch.act.appendChild(a); }
}
function again() { ch.phase = 'idle'; ch.opened = {}; ch.running = 0; build(); }
async function start() {
  const r = await rpc('chest_start');
  if (r.error) return toast(errText(r.error), true);
  ch.id = r.data.id; ch.stake = r.data.stake; ch.opened = {}; ch.running = 0; state.me.balance = Number(r.data.balance); setBal();
  ch.phase = 'preview';
  ch.cells.forEach((c, i) => { const v = r.data.preview[i]; setCell(i, v < 0 ? 'bomb' : 'coin', v); });
  update();
  const me = ch; await sleep(4000); if (ch !== me) return;
  ch.cells.forEach((c, i) => setCell(i, 'closed'));
  ch.phase = 'shuffle'; update();
  for (let n = 0; n < 16 && ch === me; n++) {
    const a = Math.floor(Math.random() * 12), b = (a + 1 + Math.floor(Math.random() * 11)) % 12;
    const tmp = ch.slot[a]; ch.slot[a] = ch.slot[b]; ch.slot[b] = tmp; applyPos(); sfx.card(); await sleep(260);
  }
  if (ch !== me) return; await sleep(350); ch.phase = 'play'; update();
}
function revealRest(layout) { layout.forEach((v, i) => { if (ch.opened[i] === undefined && !ch.cells[i].classList.contains('bomb')) setCell(i, v < 0 ? 'bomb' : 'coin', v, true); }); }
async function openChest(i) {
  if (ch.busy || ch.phase !== 'play') return; ch.busy = true;
  const r = await rpc('chest_open', { p_game: ch.id, p_index: i });
  if (!ch) return; ch.busy = false;
  if (r.error) { update(); return toast(errText(r.error), true); }
  const d = r.data;
  if (d.result === 'bomb') {
    sfx.bomb(); ch.phase = 'over'; setCell(i, 'bomb'); ch.cells[i].classList.add('pop'); revealRest(d.layout); ch.opened = {};
    ch.cells.forEach((c) => { c.disabled = true; }); ch.info.textContent = ''; ch.run.textContent = '💥 Bombe! Gewinn und Einsatz sind weg.'; ch.run.style.color = 'var(--red)';
    ch.act.innerHTML = ''; const a = el('button', null, 'Nochmal spielen'); a.onclick = () => { ch.run.style.color = ''; again(); }; ch.act.appendChild(a); return;
  }
  sfx.chest(); setTimeout(sfx.coin, 120);
  ch.opened[i] = d.value; ch.running = d.running; setCell(i, 'coin', d.value); ch.cells[i].classList.add('pop'); update();
  if (d.all_open) cash();
}
async function cash() {
  if (ch.busy) return; ch.busy = true; update();
  const r = await rpc('chest_cashout', { p_game: ch.id });
  if (!ch) return; ch.busy = false;
  if (r.error) { update(); return toast(errText(r.error), true); }
  const d = r.data; state.me.balance = Number(d.balance); setBal();
  ch.phase = 'over'; revealRest(d.layout); sfx.win(); ch.cells.forEach((c) => { c.disabled = true; });
  ch.info.textContent = ''; ch.run.style.color = '';
  ch.run.textContent = 'Eingelöst: +' + d.credit + ' Coins (' + (d.net > 0 ? 'Gewinn +' + d.net : d.net < 0 ? 'Verlust −' + (-d.net) : '±0') + ')';
  update();
}
