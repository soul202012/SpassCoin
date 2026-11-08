import { rpc } from '../supabase.js';
import { state, go } from '../state.js';
import { el, toast, errText, fmtDay, lineChart, sgn } from '../ui.js';
import { loadCatalog, avatarEl, nameEl, colorCss, applyBackground } from './cosmetics.js';

let range = 30;

export async function renderProfile(box) {
  if (state.sub === 'edit') { const m = await import('./profile-editor.js'); return m.renderEditor(box); }
  await loadCatalog();
  const uname = state.profileUser || state.me.username;
  const [pr, hist] = await Promise.all([rpc('get_profile', { p_username: uname }), rpc('balance_history', { p_username: uname, p_days: range })]);
  if (pr.error) { box.appendChild(el('p', 'msg', errText(pr.error))); return; }
  const p = pr.data;

  const head = el('div', 'prof-head'); applyBackground(head, p);
  head.style.setProperty('--pc', colorCss(p));
  const bar = el('div', 'bar2'); bar.style.background = colorCss(p); head.appendChild(bar);
  head.appendChild(avatarEl(p, 96));
  const nm = el('div', 'nm'); nm.appendChild(nameEl(p)); head.appendChild(nm);
  if (p.rank) head.appendChild(el('div', 'hint', 'Rang ' + p.rank + ' nach Kontostand'));
  const codeRow = el('div', 'hint'); codeRow.style.marginTop = '8px';
  codeRow.appendChild(document.createTextNode('SpassCoin-Code: '));
  const code = el('b', null, p.code); code.style.letterSpacing = '.15em'; codeRow.appendChild(code); head.appendChild(codeRow);
  const cp = el('button', 'sec small', 'Code kopieren'); cp.style.marginTop = '8px';
  cp.onclick = async () => { try { await navigator.clipboard.writeText(p.code); toast('Code kopiert'); } catch (e) { toast('Bitte Code von Hand markieren', true); } };
  head.appendChild(cp);
  if (p.is_me) { const ed = el('button', 'small', '✏️ Profil bearbeiten'); ed.style.marginLeft = '8px'; ed.style.marginTop = '8px'; ed.onclick = () => go('profile', 'edit'); head.appendChild(ed); }
  box.appendChild(head);
  if (!p.is_me) { const b = el('button', 'sec back', '← Zu meinem Profil'); b.onclick = () => { state.profileUser = null; go('profile'); }; box.appendChild(b); }

  const sc = el('div', 'card'); sc.appendChild(el('h2', null, 'Statistik'));
  const g = el('div', 'statgrid');
  [['Runden', p.rounds], ['Gewonnen', p.wins], ['Verloren', p.losses], ['Verdient', p.earned], ['Ausgegeben', p.spent], ['Netto-Bilanz', sgn(p.net)]].forEach(([k, v]) => {
    const d = el('div'); d.appendChild(el('small', null, k)); d.appendChild(el('b', null, String(v))); g.appendChild(d);
  });
  sc.appendChild(g); sc.appendChild(el('p', 'hint', 'Coins aus Spielen, Missionen und Tagesbelohnungen zählen als verdient. Spieleinsätze und Shop-Käufe zählen als ausgegeben.'));
  box.appendChild(sc);

  const cc = el('div', 'card'); cc.appendChild(el('h2', null, 'Kontoverlauf'));
  const seg = el('div', 'seg');
  [[7, '7 Tage'], [30, '30 Tage'], [0, 'Allzeit']].forEach(([d, t]) => { const b = el('button', range === d ? 'on' : '', t); b.onclick = () => { range = d; go('profile'); }; seg.appendChild(b); });
  cc.appendChild(seg);
  const pts = (hist.data || []).map((x) => [x.day, Number(x.balance)]);
  if (pts.length >= 2) {
    const svg = lineChart(pts, { cls: 'balchart' }); cc.appendChild(svg);
    const change = pts[pts.length - 1][1] - pts[0][1], dl = (hist.data || []).reduce((s, x) => s + Number(x.delta), 0);
    const info = el('p', change >= 0 ? 'in' : 'out', (change >= 0 ? '▲ ' : '▼ ') + sgn(change) + ' Coins seit ' + fmtDay(pts[0][0]));
    cc.appendChild(info);
    cc.appendChild(el('p', 'hint', 'Zeitraum: ' + fmtDay(pts[0][0]) + ' bis ' + fmtDay(pts[pts.length - 1][0]) + ' · Grün bedeutet Gewinn, Rot bedeutet Verlust in diesem Zeitraum.' + (dl ? '' : '')));
  } else cc.appendChild(el('p', 'hint', 'Noch zu wenig Daten für ein Diagramm.'));
  box.appendChild(cc);
}
