import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, toast, errText, sleep, onLeave, resultLine, celebrate, loseFx } from '../ui.js';
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
  const wb = el('div', 'wheelbox'); wb.appendChild(el('div', 'ptr'));
  // Casino-Look: goldener Rand mit Lauflichtern, satte Felder (schwarz = Niete, rot = Verlust/Gewinn, grün = Einsatz zurück, gold = grosser Gewinn)
  let svg = '<svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg"><defs>' +
    '<linearGradient id="wgold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff3b0"/><stop offset=".45" stop-color="#d4a017"/><stop offset="1" stop-color="#7a5200"/></linearGradient>' +
    '<radialGradient id="whub"><stop offset="0" stop-color="#fff8d6"/><stop offset=".6" stop-color="#e0b33a"/><stop offset="1" stop-color="#8a6000"/></radialGradient>' +
    '<radialGradient id="wshade"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".35"/></radialGradient></defs>' +
    '<circle cx="100" cy="100" r="99" fill="url(#wgold)"/><circle cx="100" cy="100" r="92" fill="#120d05"/>' +
    '<g id="wg" style="transform:rotate(' + wheelRot + 'deg)">', a0 = 0; const mids = [];
  fields.forEach((f) => {
    const ang = Number(f.weight) / total * 360, a1 = a0 + ang, p0 = polar(a0, 89), p1 = polar(a1, 89), lab = polar(a0 + ang / 2, 62);
    const net = f.payout - stake, col = f.payout === 0 ? '#16161a' : net < 0 ? '#7d0f1f' : net === 0 ? '#0e6b3c' : net >= 2 ? '#d4a017' : '#c8102e';
    svg += '<path d="M100,100 L' + p0[0].toFixed(2) + ',' + p0[1].toFixed(2) + ' A89,89 0 ' + (ang > 180 ? 1 : 0) + ' 1 ' + p1[0].toFixed(2) + ',' + p1[1].toFixed(2) + ' Z" fill="' + col + '" stroke="url(#wgold)" stroke-width="1.6"/>';
    svg += '<text x="' + lab[0].toFixed(2) + '" y="' + lab[1].toFixed(2) + '" fill="' + (net >= 2 ? '#2a1a00' : '#fff') + '" font-size="' + (ang < 18 ? 8 : 11) + '" font-weight="900" text-anchor="middle" dominant-baseline="middle" transform="rotate(' + (a0 + ang / 2).toFixed(2) + ' ' + lab[0].toFixed(2) + ' ' + lab[1].toFixed(2) + ')">' + label(f.payout, stake) + '</text>';
    mids.push([a0, a1]); a0 = a1;
  });
  svg += '<circle cx="100" cy="100" r="89" fill="url(#wshade)"/></g>';
  for (let i = 0; i < 24; i++) { const b = polar(i * 15, 95.5); svg += '<circle class="bulb" style="animation-delay:' + (i % 2 ? 0.5 : 0) + 's" cx="' + b[0].toFixed(2) + '" cy="' + b[1].toFixed(2) + '" r="2.2"/>'; }
  svg += '<circle cx="100" cy="100" r="15" fill="url(#whub)" stroke="#7a5200" stroke-width="1.5"/><text x="100" y="101" font-size="14" text-anchor="middle" dominant-baseline="middle" fill="#7a5200">★</text></svg>';
  wb.insertAdjacentHTML('beforeend', svg); c.appendChild(wb);
  const res = el('div', 'res'); c.appendChild(res);
  const btns = el('div', 'btns');
  const go = el('button', null, 'Drehen (' + stake + (stake === 1 ? ' Coin' : ' Coins') + ')'), au = el('button', 'sec', 'Autospin');
  btns.appendChild(go); btns.appendChild(au); c.appendChild(btns);
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
    wb.classList.remove('win'); wb.classList.add('spinning');
    sfx.spin(); await sleep(dur * 1000 + 150);
    if (!alive) return null;
    wb.classList.remove('spinning'); if (d.net > 0) wb.classList.add('win');
    state.me.balance = Number(d.balance); setBal(); spinning = false;
    const rl = resultLine(d.payout, d.stake);
    res.textContent = d.payout === 0 ? 'Niete, ' + rl.t : rl.t + (d.payout === d.stake ? ' (Einsatz zurück)' : ''); res.style.color = rl.c;
    if (d.net > 0) { sfx.win(); celebrate(d.payout, d.stake); } else if (d.payout === 0) (sfx.lose(), loseFx()); else sfx.coin();
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
