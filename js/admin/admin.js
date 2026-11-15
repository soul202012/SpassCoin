import { sb, rpc } from '../supabase.js';
import { state, go } from '../state.js';
import { el, toast, errText, fmtDate, lineChart, sgn, r2, confirmBox } from '../ui.js';

const TABS = [['overview', 'Übersicht'], ['economy', 'Ökonomie'], ['games', 'Spiele'], ['rewards', 'Streak & Rettung'], ['missions', 'Missionen'],
  ['shop', 'Shop'], ['stocks', 'Börse'], ['push', 'Push'], ['accounts', 'Konten'], ['requests', 'Anfragen']];
const csvCell = (v) => '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"';

export async function renderAdmin(box) {
  const tab = state.sub || 'overview';
  const seg = el('div', 'adminseg');
  TABS.forEach(([k, t]) => { const b = el('button', tab === k ? 'on' : '', t); b.onclick = () => go('admin', k); seg.appendChild(b); });
  box.appendChild(seg);
  const body = el('div', 'fullw'); box.appendChild(body);
  const all = await rpc('admin_get_all');
  if (all.error || !all.data) { body.appendChild(el('div', 'card')).appendChild(el('p', null, 'Die Datenbank ist noch nicht eingerichtet. Führe SPASSCOIN_2_0_ALLES.sql im Supabase SQL Editor aus. (' + errText(all.error) + ')')); return; }
  const a = all.data;
  if (tab === 'overview') return overview(body, a);
  if (tab === 'economy') return economy(body);
  if (tab === 'games') return (await import('./admin-games.js')).renderGamesAdmin(body, a);
  if (tab === 'rewards' || tab === 'push') return (await import('./admin-push.js')).render(body, a, tab);
  if (tab === 'missions' || tab === 'shop' || tab === 'stocks') return (await import('./admin-content.js')).render(body, a, tab);
  if (tab === 'accounts') return accounts(body);
  if (tab === 'requests') return requests(body);
}

async function overview(box, a) {
  const [rq, ov] = await Promise.all([rpc('admin_requests'), rpc('admin_economy')]);
  const e = ov.data || {}, reqs = rq.data || [];
  const k = el('div', 'kpis');
  [['Bank', e.bank], ['Im Umlauf', e.circulation], ['In Aktien', e.invested], ['Spieler', e.players], ['Offene Anfragen', reqs.length]].forEach(([t, v]) => {
    const d = el('div', 'kpi'); d.appendChild(el('small', null, t)); d.appendChild(el('b', null, String(v == null ? '–' : v))); k.appendChild(d);
  });
  box.appendChild(k);
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Bank'));
  const pct = e.total ? Math.round(e.bank / e.total * 1000) / 10 : 0;
  c.appendChild(el('p', null, 'Bank: ' + e.bank + ' von ' + e.total + ' Coins (' + pct + ' %)'));
  const bar = el('div', 'bar'), fill = el('div'); fill.style.width = Math.min(100, pct) + '%'; bar.appendChild(fill); c.appendChild(bar);
  box.appendChild(c);
  const tc = el('div', 'card'); tc.appendChild(el('h2', null, 'Gesamtmenge der Coins'));
  const minTotal = Number(e.circulation) + Number(e.invested);
  const st = el('div', 'stat'); st.appendChild(el('span', null, 'Aktuell')); st.appendChild(el('b', null, String(e.total))); tc.appendChild(st);
  const st2 = el('div', 'stat'); st2.appendChild(el('span', null, 'Mindestens (bei Spielern und in Aktien)')); st2.appendChild(el('b', null, String(minTotal))); tc.appendChild(st2);
  const ti = el('input'); ti.type = 'number'; ti.inputMode = 'numeric'; ti.min = String(Math.max(1, minTotal)); ti.max = '1000000'; ti.value = e.total; ti.style.marginTop = '10px'; tc.appendChild(ti);
  const te = el('p', 'err'); tc.appendChild(te);
  const tb = el('button', 'full', 'Gesamtmenge ändern');
  tb.onclick = async () => {
    te.textContent = ''; const v = parseInt(ti.value, 10);
    if (!(v >= 1) || v > 1000000) return (te.textContent = 'Die Gesamtmenge muss zwischen 1 und 1000000 liegen.');
    if (v < minTotal) return (te.textContent = 'Zu klein: Mindestens ' + minTotal + ' Coins sind schon bei Spielern oder in Aktien.');
    if (v === Number(e.total)) return (te.textContent = 'Das ist schon die aktuelle Gesamtmenge.');
    if (!(await confirmBox('Gesamtmenge ändern?', 'Neue Gesamtmenge: ' + v + ' Coins. Die Bank hat danach ' + (v - minTotal) + ' Coins (jetzt ' + e.bank + ').', 'Ändern'))) return;
    tb.disabled = true; const r = await rpc('admin_set_total', { p_total: v }); tb.disabled = false;
    if (r.error) te.textContent = errText(r.error); else { toast('Gesamtmenge: ' + r.data.total + ' Coins'); go('admin', 'overview'); }
  };
  tc.appendChild(tb); box.appendChild(tc);
  if (reqs.length) { const b = el('button', 'full', ' ' + reqs.length + ' offene Anfragen ansehen'); b.onclick = () => go('admin', 'requests'); box.appendChild(b); }
}

async function economy(box) {
  const r = await rpc('admin_economy');
  if (r.error) { box.appendChild(el('p', 'msg', errText(r.error))); return; }
  const e = r.data;
  const k = el('div', 'kpis');
  [['Bank', e.bank], ['Umlauf', e.circulation], ['Gewonnen (Spiele)', e.earned_games], ['Eingesetzt (Spiele)', e.spent_games], ['Streak-Coins', e.rewards.streak || 0], ['Missions-Coins', e.rewards.missions || 0], ['Rettungsnetz', e.rewards.rescue || 0], ['Shop-Einnahmen', e.shop_income]].forEach(([t, v]) => {
    const d = el('div', 'kpi'); d.appendChild(el('small', null, t)); d.appendChild(el('b', null, String(v))); k.appendChild(d);
  });
  box.appendChild(k);
  const pg = e.per_game || [];
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Pro Spiel'));
  if (!pg.length) c.appendChild(el('p', 'hint', 'Noch keine Spielrunden.'));
  else {
    const w = el('div', 'scroll'), t = el('table'); t.innerHTML = '<tr><th>Spiel</th><th>Runden</th><th>Eingesetzt</th><th>Ausgezahlt</th><th>Quote %</th><th>Ø Gewinn/Runde</th><th>Ø Gewinn</th><th>Ø Verlust</th><th>Spieler netto</th></tr>';
    pg.forEach((g) => { const row = el('tr'); [g.game, g.rounds, g.staked, g.paid, g.rtp == null ? '–' : g.rtp, g.avg_net == null ? '–' : g.avg_net, g.avg_win == null ? '–' : g.avg_win, g.avg_loss == null ? '–' : g.avg_loss, g.net_players].forEach((v) => row.appendChild(el('td', null, String(v)))); t.appendChild(row); });
    w.appendChild(t); c.appendChild(w);
    const worst = pg.slice().sort((x, y) => x.net_players - y.net_players)[0], best = pg.filter((g) => g.rtp != null).sort((x, y) => y.rtp - x.rtp)[0];
    c.appendChild(el('p', 'hint', 'Grösster Verlust für Spieler: ' + worst.game + ' (' + worst.net_players + ' Coins). Höchste Auszahlungsquote: ' + (best ? best.game + ' (' + best.rtp + ' %)' : '–') + '. Quote über 100 % heisst: Die Bank verliert dort Coins.'));
  }
  box.appendChild(c);
  const sc = el('div', 'card'); sc.appendChild(el('h2', null, 'Entwicklung (letzte 60 Tage)'));
  const s = e.series || [];
  if (s.length >= 2) {
    sc.appendChild(el('div', 'lbl', 'Bankstand')); sc.appendChild(lineChart(s.map((x) => [x.day, Number(x.bank)]), { cls: 'line-chart', color: 'var(--accent)' }));
    sc.appendChild(el('div', 'lbl', 'Coins im Umlauf')); sc.appendChild(lineChart(s.map((x) => [x.day, Number(x.circulation)]), { cls: 'line-chart', color: 'var(--green)' }));
    sc.appendChild(el('div', 'lbl', 'Ausgezahlt pro Tag')); sc.appendChild(lineChart(s.map((x) => [x.day, Number(x.paid)]), { cls: 'line-chart', color: 'var(--red)' }));
  } else 
  box.appendChild(sc);
  const mk = (title, list, good) => { const cc = el('div', 'card'); cc.appendChild(el('h2', null, title)); if (!list.length) cc.appendChild(el('p', 'hint', 'Noch keine Daten.')); list.forEach((x) => { const row = el('div', 'stat'); row.appendChild(el('span', null, x.username + ' (' + x.rounds + ' Runden)')); row.appendChild(el('b', x.net >= 0 ? 'in' : 'out', sgn(x.net))); cc.appendChild(row); }); box.appendChild(cc); };
  mk('Höchste Gewinne (30 Tage)', e.top_winners || []); mk('Höchste Verluste (30 Tage)', e.top_losers || []);
}

async function accounts(box) {
  const us = await sb.from('profiles').select('*').order('username');
  const users = us.data || [];
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Konten'));
  box.appendChild(c);
  users.forEach((u) => {
    const d = el('details', 'sec2'), sm = el('summary');
    sm.appendChild(el('span', null, u.username + (u.is_test ? ' · Test' : u.is_admin ? ' · Admin' : ''))); sm.appendChild(el('b', null, u.balance + ' Coins')); d.appendChild(sm);
    const body = el('div'); body.appendChild(el('p', 'hint', u.email + ' · Code ' + u.code + ' · Streak ' + u.streak));
    const amt = el('input'); amt.type = 'number'; amt.inputMode = 'numeric'; amt.placeholder = 'Betrag'; amt.min = '0';
    const b = el('div', 'btns');
    async function doit(mode, sign) {
      const v = parseInt(amt.value, 10); if (isNaN(v) || v < 0) return toast('Bitte einen Betrag eingeben', true);
      const r = await rpc('admin_set_balance', { p_user: u.id, p_mode: mode, p_amount: sign * v });
      if (r.error) toast(errText(r.error), true); else { toast('Kontostand: ' + r.data + ' Coins'); go('admin', 'accounts'); }
    }
    const s1 = el('button', null, 'Setzen auf'), s2 = el('button', 'ok', '+ Addieren'), s3 = el('button', 'no', '− Abziehen');
    s1.onclick = () => doit('set', 1); s2.onclick = () => doit('add', 1); s3.onclick = () => doit('add', -1);
    b.appendChild(s1); b.appendChild(s2); b.appendChild(s3); body.appendChild(amt); body.appendChild(b); d.appendChild(body); box.appendChild(d);
  });
  const ex = el('button', 'full', 'Als Excel-Tabelle (CSV) speichern');
  ex.onclick = () => {
    const rows = [['Benutzername', 'E-Mail', 'Coins', 'Serie', 'Rolle', 'Registriert am']];
    users.forEach((x) => rows.push([x.username, x.email, x.balance, x.streak, x.is_test ? 'Test' : x.is_admin ? 'Admin' : 'Spieler', new Date(x.created_at).toLocaleDateString('de-CH')]));
    const csv = '\ufeff' + rows.map((r) => r.map(csvCell).join(';')).join('\r\n');
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = 'spasscoin-benutzer.csv'; a.click();
  };
  box.appendChild(ex);
}

async function requests(box) {
  const rq = await rpc('admin_requests'), reqs = rq.data || [];
  const rc = el('div', 'card'); rc.appendChild(el('h2', null, 'Offene Coin-Anfragen'));
  if (!reqs.length) rc.appendChild(el('p', 'hint', 'Keine offenen Anfragen.'));
  const l = el('div', 'list');
  reqs.forEach((x) => {
    const it = el('div', 'item'), m = el('div', 'main'); m.appendChild(el('div', 't', x.username + ': ' + x.amount + ' Coins')); m.appendChild(el('div', 'd', fmtDate(x.created_at)));
    const ok = el('button', 'ok small', '✓'), no = el('button', 'no small', '✗');
    const decide = async (yes) => { ok.disabled = no.disabled = true; const r = await rpc('decide_request', { p_id: x.req_id, p_approve: yes }); if (r.error) toast(errText(r.error), true); else toast(yes ? 'Bestätigt, Coins aus der Bank gutgeschrieben' : 'Abgelehnt'); go('admin', 'requests'); };
    ok.onclick = () => decide(true); no.onclick = () => decide(false);
    it.appendChild(m); it.appendChild(ok); it.appendChild(no); l.appendChild(it);
  });
  rc.appendChild(l); box.appendChild(rc);
}
