import { rpc } from '../supabase.js';
import { go } from '../state.js';
import { el, toast, errText, r2, sgn } from '../ui.js';
import { nf, cbf, selectf, listEditor, sec, liveInfo, sum } from './forms.js';

const NAMES = { chest: 'Truhen', wheel: 'Glücksrad', race: 'Pferderennen', slots: 'Slotmaschine', blackjack: 'Blackjack', plinko: 'Plinko', scratch: 'Rubbellose', hilo: 'Higher or Lower', poker: 'Video Poker', stocks: 'Börse' };
const comb = (n, k) => { let r = 1; for (let i = 1; i <= k; i++) r = r * (n - k + i) / i; return r; };

function saveBtn(parent, label, fn) {
  const err = el('p', 'err'); parent.appendChild(err);
  const b = el('button', 'full', label);
  b.onclick = async () => { err.textContent = ''; b.disabled = true; try { await fn(err); } catch (e) { err.textContent = errText(e); } b.disabled = false; };
  parent.appendChild(b); return err;
}
const saveConfig = async (key, value, err) => {
  const r = await rpc('admin_save_config', { p_key: key, p_value: value });
  if (r.error) { err.textContent = errText(r.error); return false; }
  toast('Gespeichert'); go('admin', 'games'); return true;
};

export async function renderGamesAdmin(box, a) {
  box.appendChild(el('p', 'adm-help', 'Alle Änderungen gelten sofort für neue Runden. Die Erwartungswerte unter den Feldern zeigen, ob ein Spiel ausgeglichen ist.'));
  // ---------- Spiele verwalten ----------
  const t = sec(box, 'Spiele verwalten', true);
  t.appendChild(el('p', 'adm-help', 'Spiel ein- oder ausschalten, Einsatzgrenzen und optional ein Tageslimit (Runden pro Spieler und Tag, leer = kein Limit).'));
  a.toggles.forEach((tg) => {
    const o = { enabled: tg.enabled, min_stake: tg.min_stake, max_stake: tg.max_stake, limit: tg.daily_round_limit == null ? '' : tg.daily_round_limit };
    const d = el('div', 'card'); d.appendChild(el('h2', null, NAMES[tg.game] || tg.game));
    d.appendChild(cbf('Spiel aktiv', o, 'enabled'));
    const row = el('div', 'row2'); row.style.marginTop = '8px';
    row.appendChild(nf('Mindesteinsatz', o, 'min_stake', { min: 1 })); row.appendChild(nf('Höchsteinsatz', o, 'max_stake', { min: 1 }));
    const lw = el('div', 'fld'); lw.appendChild(el('div', 'lbl', 'Tageslimit')); const li = el('input'); li.type = 'number'; li.min = '1'; li.value = o.limit; li.placeholder = 'kein Limit'; li.style.marginBottom = '0'; li.oninput = () => { o.limit = li.value; }; lw.appendChild(li); row.appendChild(lw);
    d.appendChild(row);
    const b = el('button', 'small', 'Speichern'); b.style.marginTop = '8px';
    b.onclick = async () => { const r = await rpc('admin_save_toggle', { p_game: tg.game, p_enabled: o.enabled, p_min: o.min_stake, p_max: o.max_stake, p_limit: o.limit === '' ? null : parseInt(o.limit, 10) }); if (r.error) toast(errText(r.error), true); else toast(NAMES[tg.game] + ' gespeichert'); };
    d.appendChild(b); t.appendChild(d);
  });
  // ---------- Bisherige Spiele ----------
  const ov = await rpc('admin_game_overview');
  if (ov.data) legacy(box, ov.data);
  plinko(box, a.config.plinko); scratch(box, a.config.scratch); hilo(box, a.config.hilo); poker(box, a.config.poker);
}

function legacy(box, ov) {
  const cfg = JSON.parse(JSON.stringify(ov.settings));
  cfg.wheel_fields.forEach((f) => { f.weight = Number(f.weight); });
  cfg.slot_symbols.forEach((f) => { f.weight = Number(f.weight); f.mult = Number(f.mult); });
  cfg.race_horses.forEach((f) => { f.weight = Number(f.weight); f.odds = Number(f.odds); });
  ['bj_blackjack_payout', 'bj_win_payout', 'pool_strength'].forEach((k) => { cfg[k] = Number(cfg[k]); });
  const infos = []; const recalc = () => infos.forEach((f) => f());
  const parseVals = (s) => s.split(/[\s,;]+/).filter(Boolean).map(Number);
  const chestEV = (vals, bombs) => {
    const items = vals.concat(Array(bombs).fill(-1)), n = items.length, memo = {};
    const V = (mask) => {
      if (memo[mask] !== undefined) return memo[mask];
      let S = 0, cnt = 0, acc = 0;
      for (let i = 0; i < n; i++) if ((mask >> i) & 1 && items[i] > 0) S += items[i];
      for (let i = 0; i < n; i++) if (!((mask >> i) & 1)) { cnt++; if (items[i] > 0) acc += V(mask | (1 << i)); }
      const cont = cnt ? acc / cnt : 0, res = mask === 0 ? cont : Math.max(S, cont); memo[mask] = res; return res;
    };
    return { best: V(0), one: vals.reduce((s, v) => s + v, 0) / n };
  };
  const g = sec(box, 'Bank-Anpassung (Truhen, Rad, Slot, Blackjack)');
  g.appendChild(el('p', 'adm-help', 'Bank jetzt: ' + ov.bank + ' von ' + ov.total + ' Coins (' + ov.bank_pct + ' %). Ist die Bank unter der Schwelle, gibt es etwas mehr Nieten und Bomben, darüber etwas bessere Chancen.'));
  const two = el('div', 'row2');
  two.appendChild(nf('Bank-Schwelle (%)', cfg, 'pool_threshold', { min: 1 }, recalc)); two.appendChild(nf('Stärke der Anpassung', cfg, 'pool_strength', { min: 0, step: '0.5', hint: '0 = aus (empfohlen 3 bis 8)' }, recalc)); g.appendChild(two);

  const t = sec(box, '🧰 Truhen');
  const tw = el('div', 'row2'); tw.appendChild(nf('Einsatz (Coins)', cfg, 'chest_stake', { min: 1 }, recalc)); tw.appendChild(nf('Anzahl Bomben', cfg, 'chest_bombs', { min: 1 }, recalc)); t.appendChild(tw);
  const iv = el('input'); iv.value = cfg.chest_values.join(', '); iv.oninput = () => { cfg.chest_values = parseVals(iv.value); recalc(); };
  t.appendChild(el('div', 'lbl', 'Truhenwerte (mit Komma, Anzahl = 12 minus Bomben)')); t.appendChild(iv);
  liveInfo(t, infos, () => { const v = cfg.chest_values, b = cfg.chest_bombs; if (v.length + b !== 12 || v.some(isNaN)) return 'Truhenwerte (' + v.length + ') plus Bomben (' + b + ') müssen genau 12 ergeben.'; const e = chestEV(v, b); return 'Erwartungswert: nur 1 Truhe ' + sgn(e.one - cfg.chest_stake) + ', beste Strategie ' + sgn(e.best - cfg.chest_stake) + ' Coins (0 = ausgeglichen).'; });

  const w = sec(box, '🎡 Glücksrad');
  w.appendChild(nf('Einsatz pro Drehung (Coins)', cfg, 'wheel_stake', { min: 1 }, recalc));
  w.appendChild(el('p', 'adm-help', 'Auszahlung = Coins, die man zurückbekommt. 0 = Niete, gleich wie der Einsatz = ±0, mehr = Gewinn.'));
  w.appendChild(listEditor(cfg.wheel_fields, [{ key: 'payout', label: 'Auszahlung', min: 0, step: 1 }, { key: 'weight', label: 'Chance (%)', min: 0, step: '0.1' }], () => ({ payout: 1, weight: 1 }), false, recalc));
  liveInfo(w, infos, () => { const ev = cfg.wheel_fields.reduce((s, f) => s + f.weight / 100 * f.payout, 0); return 'Summe der Chancen: ' + r2(sum(cfg.wheel_fields, 'weight')) + ' % (muss 100 sein) · Erwartungswert pro Drehung: ' + sgn(ev - cfg.wheel_stake) + ' Coins'; });

  const s = sec(box, '🎰 Slotmaschine');
  s.appendChild(el('p', 'adm-help', 'Drei gleiche Symbole gewinnen. Gewinnfaktor = Auszahlung mal Einsatz. Jede Walze zieht unabhängig.'));
  s.appendChild(listEditor(cfg.slot_symbols, [{ key: 'symbol', label: 'Symbol', type: 'text', max: 8 }, { key: 'weight', label: 'Chance (%)', min: 0, step: '0.1' }, { key: 'mult', label: 'Faktor ×', min: 0, step: '1' }], () => ({ symbol: '🍀', weight: 1, mult: 10 }), false, recalc));
  liveInfo(s, infos, () => { const tot = sum(cfg.slot_symbols, 'weight'); if (!(tot > 0)) return ''; let ev = 0, hit = 0; cfg.slot_symbols.forEach((x) => { const p = x.weight / tot; ev += p ** 3 * x.mult; hit += p ** 3; }); return 'Summe der Chancen: ' + r2(tot) + ' % (muss 100 sein) · Trefferchance: ' + r2(hit * 100) + ' % · Erwartungswert pro Coin Einsatz: ' + sgn(ev - 1); });

  const b = sec(box, '🃏 Blackjack');
  const bw = el('div', 'row2'); bw.appendChild(nf('Blackjack zahlt (Gewinn × Einsatz)', cfg, 'bj_blackjack_payout', { min: 1, step: '0.1', hint: '1.5 = 3:2' }, recalc)); bw.appendChild(nf('Normaler Gewinn (× Einsatz)', cfg, 'bj_win_payout', { min: 0.5, step: '0.1', hint: '1 = doppelter Einsatz zurück' }, recalc)); b.appendChild(bw);
  b.appendChild(cbf('Dealer zieht bei weicher 17 weiter', cfg, 'bj_soft17', recalc));
  liveInfo(b, infos, () => 'Ungefährer Erwartungswert bei guter Strategie: ' + sgn((-0.005 + 0.43 * (cfg.bj_win_payout - 1) + 0.0475 * (cfg.bj_blackjack_payout - 1.5) - (cfg.bj_soft17 ? 0.002 : 0)) * 100) + ' % (klassisch etwa −0.5 %). Das ist eine Näherung.');

  const h = sec(box, '🏇 Pferderennen');
  h.appendChild(el('p', 'adm-help', '5 Pferde. Quote = Auszahlung × Einsatz (Einsatz inklusive, abgerundet). Änderungen gelten ab dem nächsten Rennen, das der Server erzeugt.'));
  h.appendChild(listEditor(cfg.race_horses, [{ key: 'name', label: 'Name', type: 'text', max: 20 }, { key: 'color', label: 'Farbe', type: 'color' }, { key: 'weight', label: 'Chance (%)', min: 0, step: '0.1' }, { key: 'odds', label: 'Quote ×', min: 1.01, step: '0.1' }], null, true, recalc));
  liveInfo(h, infos, () => 'Summe der Chancen: ' + r2(sum(cfg.race_horses, 'weight')) + ' % (muss 100 sein) · Erwartungswert pro Wette: ' + cfg.race_horses.map((x) => x.name + ' ' + sgn((x.weight / 100 * x.odds - 1) * 100) + ' %').join(', '));

  const all = sec(box, 'Speichern: Truhen, Rad, Slot, Blackjack, Pferde');
  saveBtn(all, 'Diese Einstellungen speichern', async (err) => {
    const vals = cfg.chest_values;
    if (vals.length + cfg.chest_bombs !== 12) return (err.textContent = 'Truhen: Werte plus Bomben müssen 12 ergeben.');
    if (Math.abs(sum(cfg.wheel_fields, 'weight') - 100) > 0.01) return (err.textContent = 'Glücksrad: Die Chancen müssen 100 % ergeben.');
    if (Math.abs(sum(cfg.slot_symbols, 'weight') - 100) > 0.01) return (err.textContent = 'Slot: Die Chancen müssen 100 % ergeben.');
    if (Math.abs(sum(cfg.race_horses, 'weight') - 100) > 0.01) return (err.textContent = 'Pferde: Die Chancen müssen 100 % ergeben.');
    const r = await rpc('admin_save_settings', { p_settings: cfg });
    if (r.error) err.textContent = errText(r.error); else { toast('Gespeichert'); go('admin', 'games'); }
  });
  recalc();
}

function plinko(box, c0) {
  const cfg = JSON.parse(JSON.stringify(c0)), infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, '🔴 Plinko'); const txt = {};
  area.appendChild(nf('Reihen (6 bis 16)', cfg, 'rows', { min: 6, max: 16 }, recalc));
  area.appendChild(el('p', 'adm-help', 'Pro Risikostufe braucht es Reihen + 1 Faktoren (von links nach rechts, mit Komma getrennt).'));
  ['low', 'medium', 'high'].forEach((lv) => {
    area.appendChild(el('div', 'lbl', { low: 'Niedrig', medium: 'Mittel', high: 'Hoch' }[lv]));
    const ta = el('textarea'); ta.value = cfg.levels[lv].join(', '); ta.oninput = () => { cfg.levels[lv] = ta.value.split(/[\s,;]+/).filter(Boolean).map(Number); recalc(); }; area.appendChild(ta);
    liveInfo(area, infos, () => { const v = cfg.levels[lv], n = cfg.rows; if (v.length !== n + 1 || v.some(isNaN)) return 'Es braucht genau ' + (n + 1) + ' Zahlen (jetzt ' + v.length + ').'; let ev = 0; v.forEach((m, k) => { ev += comb(n, k) / 2 ** n * m; }); return 'Auszahlungsquote: ' + r2(ev * 100) + ' % · Höchster Faktor ×' + Math.max(...v) + ' (Bankvorteil ' + r2((1 - ev) * 100) + ' %)'; });
  });
  saveBtn(area, 'Plinko speichern', async (err) => { await saveConfig('plinko', cfg, err); });
  recalc();
}

function scratch(box, c0) {
  const cfg = JSON.parse(JSON.stringify(c0)); cfg.tiers.forEach((t) => { t.pct = r2(t.p * 100); });
  const infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, '🎟️ Rubbellose');
  area.appendChild(el('p', 'adm-help', 'Beim Kauf wird eine Gewinnstufe ausgelost. Gleiche Symbole: 0 = Niete, sonst mindestens 2. Es braucht mindestens so viele Symbole wie Felder.'));
  area.appendChild(nf('Anzahl Felder (4 bis 12)', cfg, 'cells', { min: 4, max: 12 }, recalc));
  area.appendChild(el('div', 'lbl', 'Symbole'));
  area.appendChild(listEditor(cfg.symbols, [{ key: 'id', label: 'ID (a-z, 0-9, _)', type: 'text', max: 20 }, { key: 'icon', label: 'Symbol', type: 'text', max: 8 }, { key: 'name', label: 'Name', type: 'text', max: 20 }], () => ({ id: 'neu' + Math.floor(Math.random() * 99), icon: '🍀', name: 'Neu' }), false, recalc));
  area.appendChild(el('div', 'lbl', 'Gewinnstufen'));
  area.appendChild(listEditor(cfg.tiers, [{ key: 'matches', label: 'Gleiche Symbole', min: 0, step: 1 }, { key: 'pct', label: 'Chance (%)', min: 0, step: '0.01' }, { key: 'mult', label: 'Faktor ×', min: 0, step: '0.1' }], () => ({ matches: 2, pct: 1, mult: 2 }), false, recalc));
  liveInfo(area, infos, () => { const tot = cfg.tiers.reduce((s, t) => s + t.pct, 0), ev = cfg.tiers.reduce((s, t) => s + t.pct / 100 * t.mult, 0); return 'Summe der Chancen: ' + r2(tot) + ' % (muss 100 sein) · Auszahlungsquote: ' + r2(ev * 100) + ' % (Bankvorteil ' + r2((1 - ev) * 100) + ' %) · ' + cfg.symbols.length + ' Symbole für ' + cfg.cells + ' Felder'; });
  saveBtn(area, 'Rubbellose speichern', async (err) => {
    const v = { cells: cfg.cells, symbols: cfg.symbols, tiers: cfg.tiers.map((t) => ({ matches: t.matches, p: t.pct / 100, mult: t.mult })) };
    await saveConfig('scratch', v, err);
  });
  recalc();
}

function hiloRtp(M) {
  const S = M.length, memo = {}, R = []; for (let i = 2; i <= 14; i++) R.push(i);
  const V = (s, r) => {
    const key = s * 20 + r; if (memo[key] !== undefined) return memo[key];
    let best = 0;
    for (const d of ['H', 'L']) { let tot = 0; for (const r2_ of R) { const win = d === 'H' ? r2_ > r : r2_ < r; if (win) tot += s + 1 === S ? M[s] / 13 : V(s + 1, r2_) / 13; } best = Math.max(best, tot); }
    const res = s === 0 ? best : Math.max(M[s - 1], best); memo[key] = res; return res;
  };
  return R.reduce((a, r) => a + V(0, r), 0) / 13;
}
function hilo(box, c0) {
  const cfg = JSON.parse(JSON.stringify(c0)), infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, '🔼 Higher or Lower');
  area.appendChild(el('p', 'adm-help', 'Gewinnleiter: Faktor nach 1, 2, 3 ... richtigen Antworten (mit Komma). Die oberste Stufe zahlt automatisch aus.'));
  const ta = el('textarea'); ta.value = cfg.ladder.join(', '); ta.oninput = () => { cfg.ladder = ta.value.split(/[\s,;]+/).filter(Boolean).map(Number); recalc(); }; area.appendChild(ta);
  area.appendChild(selectf('Gleichstand', cfg, 'tie', [['lose', 'Zählt als falsch (Serie endet)'], ['push', 'Es geht ohne Verlust weiter']], recalc));
  liveInfo(area, infos, () => { const l = cfg.ladder; if (!l.length || l.some(isNaN)) return 'Bitte Zahlen eingeben.'; return 'Auszahlungsquote bei bester Strategie: ' + r2(hiloRtp(l) * 100) + ' % (unter 100 % = Bank gewinnt). Normale Spieler liegen meist darunter.'; });
  saveBtn(area, 'Higher or Lower speichern', async (err) => { await saveConfig('hilo', cfg, err); });
  recalc();
}

function poker(box, c0) {
  const cfg = JSON.parse(JSON.stringify(c0)), infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, '♠️ Video Poker');
  const NAMES2 = { royal: 'Royal Flush', straight_flush: 'Straight Flush', four: 'Vierling', full_house: 'Full House', flush: 'Flush', straight: 'Strasse', three: 'Drilling', two_pair: 'Zwei Paare', jacks: 'Paar Buben oder höher' };
  area.appendChild(el('p', 'adm-help', 'Auszahlung pro Hand als Faktor mal Einsatz.'));
  const grid = el('div', 'row2'); grid.style.flexWrap = 'wrap';
  Object.keys(NAMES2).forEach((k) => { const w = nf(NAMES2[k], cfg.paytable, k, { min: 0, step: '1' }, recalc); w.style.flex = '1 1 140px'; grid.appendChild(w); });
  area.appendChild(grid);
  liveInfo(area, infos, () => {
    const p = cfg.paytable, base = p.royal === 250 && p.straight_flush === 50 && p.four === 25 && p.straight === 4 && p.three === 3 && p.two_pair === 2 && p.jacks === 1;
    const table = { '9/6': 99.5, '9/5': 98.4, '8/6': 98.4, '8/5': 97.3, '7/5': 96.2, '6/5': 95.0 }[p.full_house + '/' + p.flush];
    return base && table ? 'Referenz: Mit Full House ' + p.full_house + ' und Flush ' + p.flush + ' liegt die Quote bei perfekter Strategie bei etwa ' + table + ' %. Normale Spieler liegen darunter.' : 'Die Quote lässt sich bei abweichender Tabelle nicht einfach berechnen. Je höher die Werte, desto besser für die Spieler.';
  });
  saveBtn(area, 'Video Poker speichern', async (err) => { await saveConfig('poker', cfg, err); });
  recalc();
}
