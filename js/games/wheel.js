import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, sleep, onLeave } from '../ui.js';
import { sfx } from '../audio.js';

let wheelRot = 0;
const polar = (a, r) => { const t = a * Math.PI / 180; return [100 + r * Math.sin(t), 100 - r * Math.cos(t)]; };
const label = (payout, stake) => { if (payout === 0) return 'Niete'; const n = payout - stake; return n === 0 ? '±0' : (n > 0 ? '+' + n : '−' + (-n)); };

export function init(box, ctx) {
  const fields = ctx.gi.wheel_fields, stake = ctx.gi.wheel_stake;
  let alive = true, auto = false, spinning = false;
  onLeave(() => { alive = false; auto = false; });
  const total = fields.reduce((s, f) => s + Number(f.weight), 0);
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Glücksrad'));
  c.appendChild(el('p', 'hint', 'Eine Drehung kostet ' + stake + (stake === 1 ? ' Coin' : ' Coins') + '. Bei einer Niete ist der Einsatz weg.'));
  const wb = el('div', 'wheelbox'); wb.appendChild(el('div', 'ptr', '▼'));
  let svg = '<svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg"><g id="wg" style="transform:rotate(' + wheelRot + 'deg)">', a0 = 0; const mids = [];
  fields.forEach((f) => {
    const ang = Number(f.weight) / total * 360, a1 = a0 + ang, p0 = polar(a0, 96), p1 = polar(a1, 96), lab = polar(a0 + ang / 2, 66);
    const net = f.payout - stake, col = f.payout === 0 ? '#8a8372' : net < 0 ? '#c2703a' : net === 0 ? '#5b7fa6' : net >= 2 ? '#e0a100' : '#3fa66b';
    svg += '<path d="M100,100 L' + p0[0].toFixed(2) + ',' + p0[1].toFixed(2) + ' A96,96 0 ' + (ang > 180 ? 1 : 0) + ' 1 ' + p1[0].toFixed(2) + ',' + p1[1].toFixed(2) + ' Z" fill="' + col + '" stroke="#fff" stroke-width="1.5"/>';
    svg += '<text x="' + lab[0].toFixed(2) + '" y="' + lab[1].toFixed(2) + '" fill="#fff" font-size="' + (ang < 18 ? 8 : 11) + '" font-weight="800" text-anchor="middle" dominant-baseline="middle" transform="rotate(' + (a0 + ang / 2).toFixed(2) + ' ' + lab[0].toFixed(2) + ' ' + lab[1].toFixed(2) + ')">' + label(f.payout, stake) + '</text>';
    mids.push([a0, a1]); a0 = a1;
  });
  svg += '</g><circle cx="100" cy="100" r="9" fill="#fff" stroke="#2b2414" stroke-width="2"/></svg>';
  wb.insertAdjacentHTML('beforeend', svg); c.appendChild(wb);
  const res = el('div', 'res'); c.appendChild(res);
  const btns = el('div', 'btns');
  const go = el('button', null, 'Drehen (' + stake + (stake === 1 ? ' Coin' : ' Coins') + ')'), au = el('button', 'sec', 'Autospin');
  btns.appendChild(go); btns.appendChild(au); c.appendChild(btns);
  c.appendChild(el('p', 'hint', 'Autospin dreht weiter, bis du auf «Stopp» drückst oder der Kontostand nicht mehr für eine Drehung reicht.'));
  box.appendChild(c);
  const ui = () => { go.disabled = spinning || auto; au.textContent = auto ? 'Stopp' : 'Autospin'; au.disabled = !auto && spinning; };
  async function spinOnce(fast) {
    spinning = true; ui(); res.textContent = ''; res.style.color = '';
    const r = await rpc('wheel_spin');
    if (!alive) return null;
    if (r.error) { spinning = false; ui(); toast(errText(r.error), true); return null; }
    const d = r.data, m = mids[d.index], mid = (m[0] + m[1]) / 2, jit = (Math.random() - 0.5) * (m[1] - m[0]) * 0.7;
    const cur = ((wheelRot % 360) + 360) % 360, need = (((360 - (mid + jit) - cur) % 360) + 360) % 360, dur = fast ? 2.2 : 4.2;
    wheelRot = wheelRot + 360 * (fast ? 3 : 5) + need;
    const wg = document.getElementById('wg');
    wg.style.transition = 'transform ' + dur + 's cubic-bezier(.12,.7,.1,1)'; wg.style.transform = 'rotate(' + wheelRot + 'deg)';
    sfx.spin(); await sleep(dur * 1000 + 150);
    if (!alive) return null;
    state.me.balance = Number(d.balance); setBal(); spinning = false;
    if (d.net > 0) { res.textContent = '🎉 +' + d.net + (d.net === 1 ? ' Coin' : ' Coins') + ' gewonnen!'; res.style.color = 'var(--green)'; sfx.win(); }
    else if (d.net === 0) res.textContent = '±0 – Einsatz zurück';
    else if (d.payout === 0) { res.textContent = 'Niete – Einsatz verloren'; res.style.color = 'var(--red)'; sfx.lose(); }
    else { res.textContent = '−' + (-d.net) + (d.net === -1 ? ' Coin' : ' Coins'); res.style.color = 'var(--red)'; sfx.lose(); }
    ui(); return d;
  }
  go.onclick = () => spinOnce(false);
  au.onclick = async () => {
    if (auto) { auto = false; ui(); return; }
    if (state.me.balance < stake) return toast('Nicht genug Coins', true);
    auto = true; ui();
    while (auto && alive) {
      if (state.me.balance < stake) { toast('Der Kontostand reicht nicht mehr – Autospin beendet'); break; }
      const d = await spinOnce(true); if (!d) break; await sleep(600);
    }
    auto = false; if (alive) ui();
  };
  ui();
}
