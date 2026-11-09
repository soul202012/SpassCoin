import { rpc } from '../supabase.js';
import { state, setBal } from '../state.js';
import { el, inp, toast, errText, onLeave, hms, lineChart, fmtDate, r2, sgn } from '../ui.js';
import { sfx } from '../audio.js';

const RISK = { low: 'ruhig', medium: 'mittel', high: 'wild' };
let selId = null, hours = 24;

export async function init(box) {
  let alive = true, data = null, offset = 0; onLeave(() => { alive = false; });
  const wrap = el('div', 'stocks'); box.appendChild(wrap);
  const typing = () => document.activeElement && document.activeElement.tagName === 'INPUT';

  async function load() {
    const r = await rpc('stock_market');
    if (!alive) return false;
    if (r.error) { wrap.innerHTML = ''; wrap.appendChild(el('p', 'msg', errText(r.error))); return false; }
    data = r.data; offset = data.server_ms - Date.now(); return true;
  }
  const holdOf = (id) => data.holdings.find((h) => h.company_id === id);
  const chg = (c) => (c.prev ? ((c.price - c.prev) / c.prev) * 100 : 0);
  function spark(arr) {
    const s = lineChart(arr.map((v, i) => [i, Number(v)]), { cls: 'spark', height: 30 });
    return s;
  }
  async function render() {
    if (!alive || !data) return;
    wrap.innerHTML = '';
    const selected = data.companies.find((c) => c.id === selId);
    if (selected) return detail(selected);
    selId = null;
    // Depot-Zusammenfassung
    let val = 0, cost = 0;
    data.holdings.forEach((h) => { const c = data.companies.find((x) => x.id === h.company_id); if (c) { val += Math.floor(c.price * h.shares); cost += Number(h.cost); } });
    const top = el('div', 'card'); top.appendChild(el('h2', null, 'Mein Depot'));
    const st = el('div', 'stat'); st.appendChild(el('span', null, 'Wert der Aktien')); st.appendChild(el('b', null, val + ' Coins')); top.appendChild(st);
    const st2 = el('div', 'stat'); st2.appendChild(el('span', null, 'Investiert')); st2.appendChild(el('b', null, cost + ' Coins')); top.appendChild(st2);
    const pl = val - cost, st3 = el('div', 'stat'); st3.appendChild(el('span', null, 'Gewinn / Verlust')); const b3 = el('b', pl >= 0 ? 'up' : 'down', sgn(pl) + ' Coins'); st3.appendChild(b3); top.appendChild(st3);
    const nxt = el('p', 'hint'); top.appendChild(nxt);
    const upd = () => { if (!alive) return; nxt.textContent = data.paused ? '⏸ Der Markt ist pausiert.' : 'Nächste Kursänderung in ' + hms(data.last_tick_ms + data.interval_sec * 1000 - (Date.now() + offset)) + ' (alle ' + Math.round(data.interval_sec / 60 * 10) / 10 + ' Min.)'; };
    upd(); const iv = setInterval(upd, 1000); onLeave(() => clearInterval(iv));
    top.appendChild(el('p', 'hint', 'Alle Firmen sind erfunden. Es gibt keine garantierten Gewinne, Kurse können steigen und fallen.'));
    wrap.appendChild(top);
    const list = el('div', 'card'); list.appendChild(el('h2', null, 'Aktien'));
    data.companies.forEach((c) => {
      const row = el('div', 'row'), sym = el('div', 'sym', c.symbol), nm = el('div', 'nm'), p = el('div'), ch = chg(c);
      const t = el('span', null, c.name); t.appendChild(el('span', 'risk', RISK[c.risk] || c.risk)); nm.appendChild(t);
      const h = holdOf(c.id); nm.appendChild(el('small', null, h ? h.shares + ' Aktien im Depot' : c.descr));
      p.style.textAlign = 'right'; p.appendChild(el('b', null, c.price.toFixed(2))); p.appendChild(el('div', ch >= 0 ? 'up' : 'down', (ch >= 0 ? '▲ ' : '▼ ') + Math.abs(ch).toFixed(1) + '%'));
      row.appendChild(sym); row.appendChild(nm); row.appendChild(spark(c.spark)); row.appendChild(p);
      row.onclick = () => { selId = c.id; render(); }; list.appendChild(row);
    });
    wrap.appendChild(list);
    const tr = el('div', 'card'); tr.appendChild(el('h2', null, 'Meine letzten Geschäfte')); wrap.appendChild(tr);
    const t = await rpc('stock_trades');
    if (!alive) return;
    if (!(t.data || []).length) tr.appendChild(el('p', 'hint', 'Noch keine Geschäfte.'));
    else { const l = el('div', 'list'); t.data.slice(0, 15).forEach((x) => { const it = el('div', 'item'), m = el('div', 'main'); m.appendChild(el('div', 't', (x.side === 'buy' ? 'Kauf ' : 'Verkauf ') + x.shares + '× ' + x.symbol + ' zu ' + Number(x.price).toFixed(2))); m.appendChild(el('div', 'd', fmtDate(x.at))); it.appendChild(m); it.appendChild(el('div', x.side === 'buy' ? 'out' : 'in', (x.side === 'buy' ? '−' : '+') + x.total)); l.appendChild(it); }); tr.appendChild(l); }
  }
  async function detail(c) {
    const back = el('button', 'sec back', '← Alle Aktien'); back.onclick = () => { selId = null; render(); }; wrap.appendChild(back);
    const card = el('div', 'card'); const ch = chg(c);
    card.appendChild(el('h2', null, c.symbol + ' · ' + c.name));
    card.appendChild(el('p', 'hint', c.descr + ' (Risiko: ' + (RISK[c.risk] || c.risk) + ')'));
    const big = el('div', 'big', c.price.toFixed(2)); big.appendChild(el('small', null, ' Coins pro Aktie')); card.appendChild(big);
    card.appendChild(el('div', ch >= 0 ? 'up' : 'down', (ch >= 0 ? '▲ ' : '▼ ') + Math.abs(ch).toFixed(1) + '% in 24 Stunden'));
    const seg = el('div', 'seg'); seg.style.marginTop = '10px';
    [[24, '24 Stunden'], [168, '7 Tage']].forEach(([h, t]) => { const b = el('button', hours === h ? 'on' : '', t); b.onclick = () => { hours = h; render(); }; seg.appendChild(b); });
    card.appendChild(seg);
    const chartBox = el('div'); card.appendChild(chartBox); wrap.appendChild(card);
    rpc('stock_history', { p_company: c.id, p_hours: hours }).then((r) => { if (!alive || !r.data) return; chartBox.appendChild(lineChart(r.data.map((p) => [p[0], Number(p[1])]), { cls: 'chart' })); });
    const h = holdOf(c.id), tc = el('div', 'card'); tc.appendChild(el('h2', null, 'Kaufen und verkaufen'));
    if (h) {
      const v = Math.floor(c.price * h.shares), pl = v - Number(h.cost);
      [['Deine Aktien', h.shares], ['Durchschnittlicher Kaufpreis', (h.cost / h.shares).toFixed(2)], ['Aktueller Wert', v + ' Coins'], ['Gewinn / Verlust', sgn(pl) + ' Coins']].forEach(([k, val]) => { const r = el('div', 'stat'); r.appendChild(el('span', null, k)); r.appendChild(el('b', k.startsWith('Gewinn') ? (pl >= 0 ? 'up' : 'down') : null, String(val))); tc.appendChild(r); });
    } else tc.appendChild(el('p', 'hint', 'Du besitzt noch keine Aktien dieser Firma.'));
    const n = inp('Anzahl Aktien', 'number', 'numeric'); n.min = '1'; n.value = '1'; n.style.marginTop = '10px'; tc.appendChild(n);
    const pv = el('p', 'hint'); tc.appendChild(pv);
    const upd = () => { const k = parseInt(n.value, 10) || 0; pv.textContent = 'Kauf kostet ' + Math.ceil(c.price * k) + ' Coins · Verkauf bringt ' + Math.floor(c.price * k) + ' Coins · Du hast ' + state.me.balance + ' Coins'; };
    n.oninput = upd; upd();
    const row = el('div', 'btns'), buy = el('button', 'ok', 'Kaufen'), sell = el('button', 'no', 'Verkaufen'), all = el('button', 'sec', 'Alle verkaufen');
    buy.disabled = data.paused; sell.disabled = !h; all.disabled = !h;
    async function trade(fn, shares) {
      if (!(shares > 0)) return toast('Bitte eine Anzahl eingeben', true);
      [buy, sell, all].forEach((b) => { b.disabled = true; });
      const r = await rpc(fn, { p_company: c.id, p_shares: shares });
      if (!alive) return;
      if (r.error) { toast(errText(r.error), true); await load(); return render(); }
      state.me.balance = Number(r.data.balance); setBal(); sfx.buy();
      toast(fn === 'stock_buy' ? 'Gekauft für ' + r.data.paid + ' Coins' : 'Verkauft für ' + r.data.received + ' Coins (' + sgn(r.data.profit) + ')');
      await load(); render();
    }
    buy.onclick = () => trade('stock_buy', parseInt(n.value, 10)); sell.onclick = () => trade('stock_sell', parseInt(n.value, 10)); all.onclick = () => trade('stock_sell', h.shares);
    row.appendChild(buy); row.appendChild(sell); row.appendChild(all); tc.appendChild(row);
    if (data.paused) tc.appendChild(el('p', 'hint', 'Der Markt ist pausiert. Kaufen geht gerade nicht.'));
    wrap.appendChild(tc);
  }
  if (await load()) await render();
  const iv = setInterval(async () => { if (document.hidden || typing()) return; if (await load()) render(); }, 20000);
  onLeave(() => clearInterval(iv));
}
