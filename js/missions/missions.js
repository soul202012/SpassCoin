import { rpc } from '../supabase.js';
import { state, go } from '../state.js';
import { el, toast, errText, hms } from '../ui.js';
import { sfx } from '../audio.js';

const DIFF = { easy: 'Leicht', medium: 'Mittel', hard: 'Schwer' };

export async function renderMissions(box) {
  const r = await rpc('my_missions');
  if (r.error) { box.appendChild(el('p', 'msg', errText(r.error))); return; }
  const list = r.data || [], done = list.filter((m) => m.completed).length;
  const head = el('div', 'card'); head.appendChild(el('h2', null, 'Tägliche Missionen'));
  head.appendChild(el('p', null, done + ' von ' + list.length + ' geschafft'));
  const bar = el('div', 'bar'), fill = el('div'); fill.style.width = (list.length ? done / list.length * 100 : 0) + '%'; bar.appendChild(fill); head.appendChild(bar);
  const lt = new Date().toLocaleString('sv-SE', { timeZone: 'Europe/Zurich' }).replace(' ', 'T');
  const now = new Date(lt), mid = new Date(now); mid.setHours(24, 0, 0, 0);
  head.appendChild(el('p', 'hint', 'Neue Missionen in ' + hms(mid - now) + ' (Mitternacht, Schweizer Zeit).'));
  box.appendChild(head);
  const c = el('div', 'card');
  if (!list.length) c.appendChild(el('p', 'hint', 'Heute gibt es keine Missionen.'));
  list.forEach((m) => {
    const row = el('div', 'mission'), top = el('div', 'top2');
    const t = el('div'); t.appendChild(el('b', null, m.title)); if (m.descr) t.appendChild(el('div', 'hint', m.descr));
    const right = el('div'); right.style.textAlign = 'right'; right.appendChild(el('span', 'diff ' + m.difficulty, DIFF[m.difficulty])); right.appendChild(el('div', 'in', '+' + m.reward + ' Coins'));
    top.appendChild(t); top.appendChild(right); row.appendChild(top);
    const pb = el('div', 'bar'), pf = el('div'); pf.style.width = Math.min(100, m.progress / m.target * 100) + '%'; pb.appendChild(pf); row.appendChild(pb);
    const bot = el('div', 'top2'); bot.appendChild(el('span', 'hint', m.progress + ' / ' + m.target));
    if (m.claimed) bot.appendChild(el('span', 'badge approved', 'Abgeholt ✓'));
    else if (m.completed) {
      const b = el('button', 'ok small', 'Belohnung abholen');
      b.onclick = async () => {
        b.disabled = true; const x = await rpc('claim_mission', { p_mission: m.mission_id });
        if (x.error) { toast(errText(x.error), true); b.disabled = false; } else { state.me.balance = Number(x.data.balance); sfx.coin(); toast('+' + x.data.reward + ' Coins'); go('missions'); }
      };
      bot.appendChild(b);
    } else bot.appendChild(el('span', 'badge', 'Offen'));
    row.appendChild(bot); c.appendChild(row);
  });
  box.appendChild(c);
}
