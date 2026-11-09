import { sb, rpc } from './supabase.js';
import { state, refreshMe, getConfig, go } from './state.js';
import { el, inp, toast, errText, fmtDate, zurich, coinsText } from './ui.js';
import { sfx } from './audio.js';

/* ---------- Startseite ---------- */
export async function renderHome(box) {
  const [, cfg, rq] = await Promise.all([refreshMe(), getConfig(), sb.from('coin_requests').select('*').eq('user_id', state.me.id).order('created_at', { ascending: false }).limit(5)]);
  const me = state.me;
  const hero = el('div', 'card hero'); hero.appendChild(el('h2', null, 'Mein Kontostand'));
  const b = el('div', 'big', String(me.balance)); b.appendChild(el('small', null, ' Coins')); hero.appendChild(b);
  hero.appendChild(el('p', 'hint', 'Alle Coins sind nur zum Spass.')); box.appendChild(hero);

  const cc = el('div', 'card'); cc.appendChild(el('h2', null, 'Mein persönlicher Code'));
  cc.appendChild(el('div', 'code', me.code));
  const cp = el('button', 'sec full', 'Code kopieren');
  cp.onclick = async () => { try { await navigator.clipboard.writeText(me.code); toast('Code kopiert'); } catch (e) { toast('Bitte Code von Hand markieren', true); } };
  cc.appendChild(cp); cc.appendChild(el('p', 'hint', 'Gib diesen Code Freunden, damit sie dir Coins senden können.')); box.appendChild(cc);

  // Daily Streak mit Coin-Belohnung
  const rewards = (cfg && cfg.streak_rewards) || [5];
  const len = rewards.length, today = zurich(0), yest = zurich(-1);
  const claimed = me.last_claim === today, alive = claimed || me.last_claim === yest;
  const cur = alive ? me.streak : 0;
  const doneCount = claimed ? ((me.streak - 1) % len) + 1 : cur % len;
  const nextIdx = claimed ? me.streak % len : cur % len;
  const dc = el('div', 'card'); dc.appendChild(el('h2', null, 'Tägliche Belohnung'));
  dc.appendChild(el('p', null, '🔥 Aktuelle Serie: ' + cur + (cur === 1 ? ' Tag' : ' Tage')));
  const dots = el('div', 'streakdots');
  rewards.forEach((r, i) => {
    const d = el('div', i < doneCount ? 'done' : (!claimed && i === nextIdx ? 'cur' : ''));
    d.appendChild(el('span', null, 'Tag ' + (i + 1))); d.appendChild(el('b', null, '+' + r)); dots.appendChild(d);
  });
  dc.appendChild(dots);
  const btn = el('button', 'full', claimed ? 'Heute schon abgeholt ✓' : 'Abholen: +' + coinsText(rewards[nextIdx]));
  btn.disabled = claimed;
  btn.onclick = async () => {
    btn.disabled = true;
    const r = await rpc('claim_daily');
    if (r.error) toast(errText(r.error), true);
    else { sfx.coin(); toast('+' + coinsText(r.data.reward) + ' · Serie: ' + r.data.streak + (r.data.streak === 1 ? ' Tag' : ' Tage')); }
    go('home');
  };
  dc.appendChild(btn);
  dc.appendChild(el('p', 'hint', claimed ? 'Morgen wieder: +' + coinsText(rewards[nextIdx]) + '.' : 'Verpasst du einen Tag, beginnt die Serie wieder bei Tag 1.'));
  box.appendChild(dc);

  const mc = el('div', 'card'); mc.appendChild(el('h2', null, 'Missionen'));
  mc.appendChild(el('p', null, 'Jeden Tag neue Aufgaben mit Coin-Belohnung.'));
  const mb = el('button', 'sec full', '🎯 Missionen ansehen'); mb.onclick = () => go('missions'); mc.appendChild(mb); box.appendChild(mc);

  const qc = el('div', 'card'); qc.appendChild(el('h2', null, 'Coins anfragen'));
  qc.appendChild(el('p', 'hint', 'Du fragst den Admin nach Coins. Er bestätigt oder lehnt ab.'));
  const row = el('div', 'row2'); row.style.marginTop = '10px';
  const n = inp('Anzahl Coins', 'number', 'numeric'); n.min = '1';
  const g = el('button', null, 'Anfragen');
  g.onclick = async () => {
    const v = parseInt(n.value, 10); if (!(v > 0)) return toast('Bitte eine Anzahl eingeben', true);
    g.disabled = true; const r = await rpc('request_coins', { p_amount: v });
    if (r.error) toast(errText(r.error), true); else toast('Anfrage gesendet'); go('home');
  };
  row.appendChild(n); row.appendChild(g); qc.appendChild(row);
  const list = rq.data || [];
  if (list.length) {
    const l = el('div', 'list'); l.style.marginTop = '12px';
    list.forEach((x) => {
      const it = el('div', 'item'), m = el('div', 'main'); m.appendChild(el('div', 't', x.amount + ' Coins')); m.appendChild(el('div', 'd', fmtDate(x.created_at)));
      it.appendChild(m); it.appendChild(el('span', 'badge ' + x.status, { open: 'Offen', approved: 'Bestätigt', rejected: 'Abgelehnt' }[x.status])); l.appendChild(it);
    });
    qc.appendChild(l);
  }
  box.appendChild(qc);
}

/* ---------- Konto: Senden und Verlauf ---------- */
const KIND_LABEL = { game_chest: 'Truhen-Spiel', game_wheel: 'Glücksrad', game_slots: 'Slotmaschine', game_bj: 'Blackjack', game_race: 'Pferderennen',
  game_plinko: 'Plinko', game_scratch: 'Rubbellos', game_hilo: 'Higher or Lower', game_poker: 'Video Poker', stock_buy: 'Börse: Kauf', stock_sell: 'Börse: Verkauf',
  admin_adjust: 'Admin-Anpassung', grant: 'Admin (Anfrage bestätigt)', reward: 'Tägliche Belohnung', mission: 'Mission', shop: 'Shop', rescue: 'Unterstützung' };

export async function renderAccount(box) {
  await refreshMe();
  const sub = state.sub === 'hist' ? 'hist' : 'send';
  const seg = el('div', 'seg');
  [['send', '📤 Senden'], ['hist', '🧾 Verlauf']].forEach(([k, t]) => { const b = el('button', sub === k ? 'on' : '', t); b.onclick = () => go('account', k); seg.appendChild(b); });
  box.appendChild(seg);
  if (sub === 'send') return renderSend(box);
  return renderHist(box);
}
function renderSend(box) {
  const me = state.me, c = el('div', 'card'); c.appendChild(el('h2', null, 'Coins senden'));
  c.appendChild(el('p', 'hint', 'Du hast ' + me.balance + ' Coins. Frag deinen Freund nach seinem sechsstelligen Code.'));
  const code = inp('Code des Empfängers (6 Zahlen)', 'text', 'numeric'); code.maxLength = 6; code.style.marginTop = '10px';
  const am = inp('Anzahl Coins', 'number', 'numeric'); am.min = '1';
  const goBtn = el('button', 'full', 'Senden');
  goBtn.onclick = async () => {
    const cv = code.value.trim(), v = parseInt(am.value, 10);
    if (!/^\d{6}$/.test(cv)) return toast('Der Code hat genau 6 Zahlen', true);
    if (!(v > 0)) return toast('Bitte eine Anzahl eingeben', true);
    if (cv === me.code) return toast('Du kannst dir nicht selbst Coins senden', true);
    if (v > me.balance) return toast('Nicht genug Coins', true);
    goBtn.disabled = true;
    const r = await rpc('send_coins', { p_code: cv, p_amount: v });
    if (r.error) { toast(errText(r.error), true); goBtn.disabled = false; }
    else { me.balance = Number(r.data); sfx.coin(); toast(v + ' Coins gesendet ✓'); go('account', 'send'); }
  };
  c.appendChild(code); c.appendChild(am); c.appendChild(goBtn); box.appendChild(c);
}
async function renderHist(box) {
  const r = await rpc('my_transactions');
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Verlauf'));
  const list = r.data || [];
  if (!list.length) c.appendChild(el('p', 'hint', 'Noch keine Transaktionen.'));
  const l = el('div', 'list');
  list.forEach((x) => {
    const isIn = x.direction === 'in';
    const who = x.tx_kind === 'transfer' ? (isIn ? 'von ' : 'an ') + (x.other_name || 'unbekannt') : (KIND_LABEL[x.tx_kind] || 'Transaktion');
    const it = el('div', 'item'), ic = el('div', 'ico ' + (isIn ? 'in' : 'out'), isIn ? '↓' : '↑'), m = el('div', 'main');
    m.appendChild(el('div', 't', who)); m.appendChild(el('div', 'd', fmtDate(x.tx_time)));
    it.appendChild(ic); it.appendChild(m); it.appendChild(el('div', isIn ? 'in' : 'out', (isIn ? '+' : '−') + x.tx_amount)); l.appendChild(it);
  });
  c.appendChild(l); box.appendChild(c);
}
