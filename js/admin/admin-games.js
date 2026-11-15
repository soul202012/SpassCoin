import { rpc } from '../supabase.js';
import { state, go, invalidateConfig } from '../state.js';
import { el, toast, errText, r2, sgn, onLeave } from '../ui.js';
import { nf, cbf, selectf, listEditor, sec, liveInfo, sum } from './forms.js';

const NAMES = { chest: 'Schatzkisten', wheel: 'Glücksrad', race: 'Pferderennen', slots: 'Slotmaschine', blackjack: 'Blackjack', plinko: 'Plinko', scratch: 'Rubbellose', hilo: 'Higher or Lower', poker: 'Video Poker', stocks: 'Börse' };
const comb = (n, k) => { let r = 1; for (let i = 1; i <= k; i++) r = r * (n - k + i) / i; return r; };
const snap = (o) => JSON.stringify(o);

export async function renderGamesAdmin(box, a) {
  const savers = [];
  state.dirty = false; onLeave(() => { state.dirty = false; });
  const bar = el('div', 'savebar'), btn = el('button', null, 'Alle Änderungen speichern'), flag = el('span', 'dirty', ''), errBox = el('div');
  bar.appendChild(btn); bar.appendChild(flag); bar.appendChild(errBox);
  const touch = () => { state.dirty = true; flag.textContent = 'Ungespeicherte Änderungen'; };
  box.addEventListener('input', touch); box.addEventListener('change', touch);

  const t = sec(box, 'Spiele verwalten', true);
  const tgs = a.toggles.map((tg) => ({ game: tg.game, o: { enabled: tg.enabled, min_stake: tg.min_stake, max_stake: tg.max_stake, limit: tg.daily_round_limit == null ? '' : tg.daily_round_limit } }));
  tgs.forEach((x) => { x.init = snap(x.o); });
  tgs.forEach(({ game, o }) => {
    const d = el('div', 'card'); d.appendChild(el('h2', null, NAMES[game] || game));
    d.appendChild(cbf('Aktiv', o));
    const row = el('div', 'row2'); row.style.marginTop = '8px';
    row.appendChild(nf('Mindesteinsatz', o, 'min_stake', { min: 1 })); row.appendChild(nf('Höchsteinsatz', o, 'max_stake', { min: 1 }));
    const lw = el('div', 'fld'); lw.appendChild(el('div', 'lbl', 'Tageslimit (Runden)')); const li = el('input'); li.type = 'number'; li.min = '1'; li.value = o.limit; li.placeholder = 'kein Limit'; li.style.marginBottom = '0'; li.oninput = () => { o.limit = li.value; }; lw.appendChild(li); row.appendChild(lw);
    d.appendChild(row); t.appendChild(d);
  });
  savers.push({ name: 'Spiele verwalten', run: async () => {
    for (const x of tgs) {
      if (snap(x.o) === x.init) continue;
      const r = await rpc('admin_save_toggle', { p_game: x.game, p_enabled: x.o.enabled, p_min: x.o.min_stake, p_max: x.o.max_stake, p_limit: x.o.limit === '' ? null : parseInt(x.o.limit, 10) });
      if (r.error) return (NAMES[x.game] || x.game) + ': ' + errText(r.error);
      x.init = snap(x.o);
    }
    return null;
  } });

  const ov = await rpc('admin_game_overview');
  if (ov.data) legacy(box, ov.data, savers);
  plinko(box, a.config.plinko, savers); scratch(box, a.config.scratch, savers); hilo(box, a.config.hilo, savers); poker(box, a.config.poker, savers);

  btn.onclick = async () => {
    btn.disabled = true; errBox.innerHTML = '';
    const errs = [];
    for (const s of savers) { try { const e = await s.run(); if (e) errs.push(s.name + ': ' + e); } catch (e) { errs.push(s.name + ': ' + errText(e)); } }
    btn.disabled = false;
    if (errs.length) { errs.forEach((m) => errBox.appendChild(el('p', 'err', m))); return; }
    state.dirty = false; flag.textContent = ''; invalidateConfig(); toast('Gespeichert'); go('admin', 'games');
  };
  box.appendChild(bar);
}

function legacy(box, ov, savers) {
  const cfg = JSON.parse(JSON.stringify(ov.settings));
  cfg.wheel_fields.forEach((f) => { f.weight = Number(f.weight); });
  cfg.slot_symbols.forEach((f) => { f.weight = Number(f.weight); f.mult = Number(f.mult); });
  cfg.race_horses.forEach((f) => { f.weight = Number(f.weight); f.odds = Number(f.odds); });
  ['bj_blackjack_payout', 'bj_win_payout', 'pool_strength'].forEach((k) => { cfg[k] = Number(cfg[k]); });
  const init = snap(cfg), infos = [], recalc = () => infos.forEach((f) => f());
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
  const g = sec(box, 'Bank-Anpassung');
  const two = el('div', 'row2');
  two.appendChild(nf('Bank-Schwelle (%)', cfg, 'pool_threshold', { min: 1 }, recalc)); two.appendChild(nf('Stärke der Anpassung', cfg, 'pool_strength', { min: 0, step: '0.5' }, recalc)); g.appendChild(two);

  const t = sec(box, 'Schatzkisten');
  const tw = el('div', 'row2'); tw.appendChild(nf('Einsatz (Coins)', cfg, 'chest_stake', { min: 1 }, recalc)); tw.appendChild(nf('Anzahl Bomben', cfg, 'chest_bombs', { min: 1 }, recalc)); t.appendChild(tw);
  const iv = el('input'); iv.value = cfg.chest_values.join(', '); iv.oninput = () => { cfg.chest_values = parseVals(iv.value); recalc(); };
  t.appendChild(el('div', 'lbl', 'Werte der Schatzkisten (mit Komma, Anzahl = 12 minus Bomben)')); t.appendChild(iv);
  liveInfo(t, infos, () => { const v = cfg.chest_values, b = cfg.chest_bombs; if (v.length + b !== 12 || v.some(isNaN)) return 'Werte der Schatzkisten (' + v.length + ') plus Bomben (' + b + ') müssen genau 12 ergeben.'; const e = chestEV(v, b); return 'Erwartungswert: nur 1 Kiste ' + sgn(e.one - cfg.chest_stake) + ', beste Strategie ' + sgn(e.best - cfg.chest_stake) + ' Coins'; });

  const w = sec(box, 'Glücksrad');
  w.appendChild(nf('Einsatz pro Drehung (Coins)', cfg, 'wheel_stake', { min: 1 }, recalc));
  w.appendChild(listEditor(cfg.wheel_fields, [{ key: 'payout', label: 'Auszahlung', min: 0, step: 1 }, { key: 'weight', label: 'Chance (%)', min: 0, step: '0.1' }], () => ({ payout: 1, weight: 1 }), false, recalc));
  liveInfo(w, infos, () => { const ev = cfg.wheel_fields.reduce((s, f) => s + f.weight / 100 * f.payout, 0); return 'Summe der Chancen: ' + r2(sum(cfg.wheel_fields, 'weight')) + ' % · Erwartungswert pro Drehung: ' + sgn(ev - cfg.wheel_stake) + ' Coins'; });

  const s = sec(box, 'Slotmaschine');
  s.appendChild(listEditor(cfg.slot_symbols, [{ key: 'symbol', label: 'Symbol', type: 'text', max: 8 }, { key: 'weight', label: 'Chance (%)', min: 0, step: '0.1' }, { key: 'mult', label: 'Faktor', min: 0, step: '1' }], () => ({ symbol: '#', weight: 1, mult: 10 }), false, recalc));
  liveInfo(s, infos, () => { const tot = sum(cfg.slot_symbols, 'weight'); if (!(tot > 0)) return ''; let ev = 0, hit = 0; cfg.slot_symbols.forEach((x) => { const p = x.weight / tot; ev += p ** 3 * x.mult; hit += p ** 3; }); return 'Summe der Chancen: ' + r2(tot) + ' % · Trefferchance: ' + r2(hit * 100) + ' % · Erwartungswert pro Coin: ' + sgn(ev - 1); });

  const b = sec(box, 'Blackjack');
  const bw = el('div', 'row2'); bw.appendChild(nf('Blackjack zahlt (Gewinn x Einsatz)', cfg, 'bj_blackjack_payout', { min: 1, step: '0.1' }, recalc)); bw.appendChild(nf('Normaler Gewinn (x Einsatz)', cfg, 'bj_win_payout', { min: 0.5, step: '0.1' }, recalc)); b.appendChild(bw);
  b.appendChild(cbf('Dealer zieht bei weicher 17 weiter', cfg, 'bj_soft17', recalc));
  liveInfo(b, infos, () => 'Ungefährer Erwartungswert: ' + sgn((-0.005 + 0.43 * (cfg.bj_win_payout - 1) + 0.0475 * (cfg.bj_blackjack_payout - 1.5) - (cfg.bj_soft17 ? 0.002 : 0)) * 100) + ' %');

  const h = sec(box, 'Pferderennen');
  h.appendChild(listEditor(cfg.race_horses, [{ key: 'name', label: 'Name', type: 'text', max: 20 }, { key: 'color', label: 'Farbe', type: 'color' }, { key: 'weight', label: 'Chance (%)', min: 0, step: '0.1' }, { key: 'odds', label: 'Quote', min: 1.01, step: '0.1' }], null, true, recalc));
  liveInfo(h, infos, () => 'Summe der Chancen: ' + r2(sum(cfg.race_horses, 'weight')) + ' % · Erwartungswert pro Wette: ' + cfg.race_horses.map((x) => x.name + ' ' + sgn((x.weight / 100 * x.odds - 1) * 100) + ' %').join(', '));
  recalc();
  savers.push({ name: 'Schatzkisten, Rad, Slot, Blackjack, Pferde', run: async () => {
    if (snap(cfg) === init) return null;
    if (cfg.chest_values.length + cfg.chest_bombs !== 12) return 'Schatzkisten: Werte plus Bomben müssen 12 ergeben.';
    if (Math.abs(sum(cfg.wheel_fields, 'weight') - 100) > 0.01) return 'Glücksrad: Die Chancen müssen 100 % ergeben.';
    if (Math.abs(sum(cfg.slot_symbols, 'weight') - 100) > 0.01) return 'Slot: Die Chancen müssen 100 % ergeben.';
    if (Math.abs(sum(cfg.race_horses, 'weight') - 100) > 0.01) return 'Pferde: Die Chancen müssen 100 % ergeben.';
    const r = await rpc('admin_save_settings', { p_settings: cfg });
    return r.error ? errText(r.error) : null;
  } });
}

function configSaver(savers, name, key, cfg, validate, build) {
  const init = snap(cfg);
  savers.push({ name, run: async () => {
    if (snap(cfg) === init) return null;
    const v = validate && validate(); if (v) return v;
    const r = await rpc('admin_save_config', { p_key: key, p_value: build ? build() : cfg });
    return r.error ? errText(r.error) : null;
  } });
}

function plinko(box, c0, savers) {
  const cfg = JSON.parse(JSON.stringify(c0)), infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, 'Plinko');
  area.appendChild(nf('Reihen (6 bis 16)', cfg, 'rows', { min: 6, max: 16 }, recalc));
  ['low', 'medium', 'high'].forEach((lv) => {
    area.appendChild(el('div', 'lbl', { low: 'Niedrig', medium: 'Mittel', high: 'Hoch' }[lv]));
    const ta = el('textarea'); ta.value = cfg.levels[lv].join(', '); ta.oninput = () => { cfg.levels[lv] = ta.value.split(/[\s,;]+/).filter(Boolean).map(Number); recalc(); }; area.appendChild(ta);
    liveInfo(area, infos, () => { const v = cfg.levels[lv], n = cfg.rows; if (v.length !== n + 1 || v.some(isNaN)) return 'Es braucht genau ' + (n + 1) + ' Zahlen (jetzt ' + v.length + ').'; let ev = 0; v.forEach((m, k) => { ev += comb(n, k) / 2 ** n * m; }); return 'Auszahlungsquote: ' + r2(ev * 100) + ' % · Höchster Faktor ' + Math.max(...v) + ' (Bankvorteil ' + r2((1 - ev) * 100) + ' %)'; });
  });
  recalc();
  configSaver(savers, 'Plinko', 'plinko', cfg, () => { const n = cfg.rows; for (const lv of ['low', 'medium', 'high']) if (cfg.levels[lv].length !== n + 1 || cfg.levels[lv].some(isNaN)) return 'Stufe ' + lv + ' braucht genau ' + (n + 1) + ' Zahlen.'; return null; });
}

function scratch(box, c0, savers) {
  const cfg = JSON.parse(JSON.stringify(c0)); cfg.tiers.forEach((t) => { t.pct = r2(t.p * 100); });
  const infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, 'Rubbellose');
  area.appendChild(nf('Anzahl Felder (4 bis 12)', cfg, 'cells', { min: 4, max: 12 }, recalc));
  area.appendChild(el('div', 'lbl', 'Symbole'));
  area.appendChild(listEditor(cfg.symbols, [{ key: 'id', label: 'ID (a-z, 0-9, _)', type: 'text', max: 20 }, { key: 'icon', label: 'Zeichen', type: 'text', max: 8 }, { key: 'name', label: 'Name', type: 'text', max: 20 }], () => ({ id: 'neu' + Math.floor(Math.random() * 99), icon: '#', name: 'Neu' }), false, recalc));
  area.appendChild(el('div', 'lbl', 'Gewinnstufen'));
  area.appendChild(listEditor(cfg.tiers, [{ key: 'matches', label: 'Gleiche Symbole', min: 0, step: 1 }, { key: 'pct', label: 'Chance (%)', min: 0, step: '0.01' }, { key: 'mult', label: 'Faktor', min: 0, step: '0.1' }], () => ({ matches: 2, pct: 1, mult: 2 }), false, recalc));
  liveInfo(area, infos, () => { const tot = cfg.tiers.reduce((s, t) => s + t.pct, 0), ev = cfg.tiers.reduce((s, t) => s + t.pct / 100 * t.mult, 0); return 'Summe der Chancen: ' + r2(tot) + ' % · Auszahlungsquote: ' + r2(ev * 100) + ' % (Bankvorteil ' + r2((1 - ev) * 100) + ' %) · ' + cfg.symbols.length + ' Symbole für ' + cfg.cells + ' Felder'; });
  recalc();
  configSaver(savers, 'Rubbellose', 'scratch', cfg, () => (Math.abs(cfg.tiers.reduce((s, t) => s + t.pct, 0) - 100) > 0.01 ? 'Die Chancen müssen 100 % ergeben.' : null),
    () => ({ cells: cfg.cells, symbols: cfg.symbols, tiers: cfg.tiers.map((t) => ({ matches: t.matches, p: t.pct / 100, mult: t.mult })) }));
}

function hiloRtp(M) {
  const S = M.length, memo = {}, R = []; for (let i = 2; i <= 14; i++) R.push(i);
  const V = (s, r) => {
    const key = s * 20 + r; if (memo[key] !== undefined) return memo[key];
    let best = 0;
    for (const d of ['H', 'L']) { let tot = 0; for (const q of R) { const win = d === 'H' ? q > r : q < r; if (win) tot += s + 1 === S ? M[s] / 13 : V(s + 1, q) / 13; } best = Math.max(best, tot); }
    const res = s === 0 ? best : Math.max(M[s - 1], best); memo[key] = res; return res;
  };
  return R.reduce((a, r) => a + V(0, r), 0) / 13;
}
function hilo(box, c0, savers) {
  const cfg = JSON.parse(JSON.stringify(c0)), infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, 'Higher or Lower');
  area.appendChild(el('div', 'lbl', 'Gewinnleiter (Faktor nach 1, 2, 3 ... richtigen Antworten)'));
  const ta = el('textarea'); ta.value = cfg.ladder.join(', '); ta.oninput = () => { cfg.ladder = ta.value.split(/[\s,;]+/).filter(Boolean).map(Number); recalc(); }; area.appendChild(ta);
  area.appendChild(selectf('Gleichstand', cfg, 'tie', [['lose', 'Zählt als falsch'], ['push', 'Es geht ohne Verlust weiter']], recalc));
  liveInfo(area, infos, () => { const l = cfg.ladder; if (!l.length || l.some(isNaN)) return 'Bitte Zahlen eingeben.'; return 'Auszahlungsquote bei bester Strategie: ' + r2(hiloRtp(l) * 100) + ' %'; });
  recalc();
  configSaver(savers, 'Higher or Lower', 'hilo', cfg, () => (!cfg.ladder.length || cfg.ladder.some(isNaN) ? 'Bitte gültige Zahlen eingeben.' : null));
}

function poker(box, c0, savers) {
  const cfg = JSON.parse(JSON.stringify(c0)), infos = [], recalc = () => infos.forEach((f) => f());
  const area = sec(box, 'Video Poker');
  const N = { royal: 'Royal Flush', straight_flush: 'Straight Flush', four: 'Vierling', full_house: 'Full House', flush: 'Flush', straight: 'Strasse', three: 'Drilling', two_pair: 'Zwei Paare', jacks: 'Paar Buben oder höher' };
  const grid = el('div', 'row2');
  Object.keys(N).forEach((k) => { const wd = nf(N[k], cfg.paytable, k, { min: 0, step: '1' }, recalc); wd.style.flex = '1 1 140px'; grid.appendChild(wd); });
  area.appendChild(grid);
  liveInfo(area, infos, () => {
    const p = cfg.paytable, base = p.royal === 250 && p.straight_flush === 50 && p.four === 25 && p.straight === 4 && p.three === 3 && p.two_pair === 2 && p.jacks === 1;
    const table = { '9/6': 99.5, '9/5': 98.4, '8/6': 98.4, '8/5': 97.3, '7/5': 96.2, '6/5': 95.0 }[p.full_house + '/' + p.flush];
    return base && table ? 'Quote bei perfekter Strategie: etwa ' + table + ' %' : 'Quote bei dieser Tabelle nicht berechenbar';
  });
  recalc();
  configSaver(savers, 'Video Poker', 'poker', cfg, () => (Object.values(cfg.paytable).some(isNaN) ? 'Bitte gültige Zahlen eingeben.' : null));
}
