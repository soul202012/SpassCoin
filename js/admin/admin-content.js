import { rpc } from '../supabase.js';
import { go } from '../state.js';
import { el, toast, errText, lineChart } from '../ui.js';
import { nf, tf, cbf, selectf, listEditor, sec } from './forms.js';

export async function render(box, a, tab) {
  if (tab === 'missions') return missions(box, a);
  if (tab === 'shop') return shop(box, a);
  return stocks(box, a);
}
const DIFF = [['easy', 'Leicht'], ['medium', 'Mittel'], ['hard', 'Schwer']];
const KINDS = [['rounds_any', 'Runden spielen (egal welches Spiel)'], ['rounds_game', 'Runden in einem Spiel spielen'], ['wins_any', 'Runden gewinnen (egal welches Spiel)'],
  ['wins_game', 'Runden in einem Spiel gewinnen'], ['win_streak_game', 'Gewinne in Folge in einem Spiel'], ['win_streak_any', 'Gewinne in Folge (egal wo)'], ['distinct_games', 'Verschiedene Spiele spielen']];
const GAMES = [['chest', 'Truhen'], ['wheel', 'Glücksrad'], ['race', 'Pferderennen'], ['slots', 'Slotmaschine'], ['blackjack', 'Blackjack'], ['plinko', 'Plinko'], ['scratch', 'Rubbellose'], ['hilo', 'Higher or Lower'], ['poker', 'Video Poker']];

function saveRow(parent, label, fn, del) {
  const err = el('p', 'err'); parent.appendChild(err);
  const row = el('div', 'btns');
  const b = el('button', null, label); b.onclick = async () => { err.textContent = ''; b.disabled = true; try { await fn(err); } catch (e) { err.textContent = errText(e); } b.disabled = false; };
  row.appendChild(b);
  if (del) { const d = el('button', 'no', 'Löschen'); d.onclick = async () => { if (!confirm('Wirklich löschen?')) return; try { await del(err); } catch (e) { err.textContent = errText(e); } }; row.appendChild(d); }
  parent.appendChild(row);
}

/* ---------- Missionen ---------- */
function missions(box, a) {
  const cfg = Object.assign({ slots: ['easy', 'medium', 'hard'] }, a.config.missions || {});
  const slots = cfg.slots.map((s) => ({ v: s }));
  const top = sec(box, 'Wie viele Missionen pro Tag?', false);
  top.appendChild(el('p', 'adm-help', 'Jede Zeile ist eine Mission pro Spieler und Tag mit der gewählten Schwierigkeit. Die Missionen werden zufällig aus den aktiven ausgewählt.'));
  const slotBox = el('div'); top.appendChild(slotBox);
  const drawSlots = () => {
    slotBox.innerHTML = '';
    slots.forEach((s, i) => { const row = el('div', 'row2'); row.style.marginBottom = '6px'; row.appendChild(selectf('Mission ' + (i + 1), s, 'v', DIFF)); const d = el('button', 'sec small', '✗'); d.style.flex = '0 0 44px'; d.style.marginTop = '24px'; d.onclick = () => { if (slots.length > 1) { slots.splice(i, 1); drawSlots(); } }; row.appendChild(d); slotBox.appendChild(row); });
    const add = el('button', 'sec small', '+ Mission pro Tag'); add.onclick = () => { if (slots.length < 6) { slots.push({ v: 'easy' }); drawSlots(); } }; slotBox.appendChild(add);
  };
  drawSlots();
  saveRow(top, 'Speichern', async (err) => { const r = await rpc('admin_save_config', { p_key: 'missions', p_value: { slots: slots.map((s) => s.v) } }); if (r.error) err.textContent = errText(r.error); else toast('Gespeichert'); });
  const list = sec(box, 'Alle Missionen (' + a.missions.length + ')', true);
  const form = (m, isNew) => {
    const o = Object.assign({ id: null, key: '', title: '', descr: '', kind: 'rounds_any', game: 'plinko', target: 1, reward: 2, difficulty: 'easy', active: true }, m);
    const d = el('div', 'card');
    d.appendChild(tf('Titel', o, 'title', { max: 80 })); d.appendChild(tf('Beschreibung (optional)', o, 'descr', { max: 120 }));
    d.appendChild(selectf('Art', o, 'kind', KINDS)); d.appendChild(selectf('Spiel (nur bei «in einem Spiel»)', o, 'game', GAMES));
    const row = el('div', 'row2'); row.appendChild(nf('Ziel', o, 'target', { min: 1 })); row.appendChild(nf('Belohnung (Coins)', o, 'reward', { min: 0 })); d.appendChild(row);
    d.appendChild(selectf('Schwierigkeit', o, 'difficulty', DIFF)); d.appendChild(cbf('Aktiv', o, 'active'));
    saveRow(d, isNew ? 'Mission erstellen' : 'Speichern', async (err) => { const r = await rpc('admin_save_mission', { p_mission: o }); if (r.error) err.textContent = errText(r.error); else { toast('Gespeichert'); go('admin', 'missions'); } },
      isNew ? null : async (err) => { const r = await rpc('admin_delete_mission', { p_id: o.id }); if (r.error) err.textContent = errText(r.error); else go('admin', 'missions'); });
    return d;
  };
  a.missions.forEach((m) => { const d = el('details', 'sec2'), s = el('summary'); s.appendChild(el('span', null, (m.active ? '' : '⏸ ') + m.title)); s.appendChild(el('span', 'hint', m.difficulty + ' · +' + m.reward)); d.appendChild(s); const b = el('div'); b.appendChild(form(m, false)); d.appendChild(b); list.appendChild(d); });
  const nw = sec(box, '+ Neue Mission', false); nw.appendChild(form({}, true));
}

/* ---------- Shop ---------- */
const CATS = [['avatar', 'Avatare'], ['frame', 'Rahmen'], ['color', 'Profilfarben'], ['background', 'Hintergründe'], ['name_color', 'Namensfarben'], ['rank_effect', 'Effekte']];
let shopCat = 'avatar';
function shop(box, a) {
  const seg = el('div', 'seg'); CATS.forEach(([k, t]) => { const b = el('button', shopCat === k ? 'on' : '', t); b.onclick = () => { shopCat = k; go('admin', 'shop'); }; seg.appendChild(b); }); box.appendChild(seg);
  box.appendChild(el('p', 'adm-help', 'Preise, Namen und Sichtbarkeit der Artikel. Gekaufte Artikel bleiben im Besitz der Spieler, auch wenn du sie ausblendest. Artikel mit Preis 0 gehören allen.'));
  const form = (it, isNew) => {
    const o = Object.assign({ id: '', category: shopCat, name: '', descr: '', price: 50, rarity: 'common', data: {}, active: true, sort: 0 }, JSON.parse(JSON.stringify(it)));
    const j = { data: JSON.stringify(o.data) };
    const d = el('div', 'card');
    if (isNew) d.appendChild(tf('ID (a-z, 0-9, - und _)', o, 'id', { max: 40 })); else d.appendChild(el('p', 'hint', 'ID: ' + o.id));
    d.appendChild(tf('Name', o, 'name', { max: 40 })); d.appendChild(tf('Beschreibung', o, 'descr', { max: 120 }));
    const row = el('div', 'row2'); row.appendChild(nf('Preis (Coins)', o, 'price', { min: 0 })); row.appendChild(nf('Sortierung', o, 'sort', { step: 1 })); d.appendChild(row);
    d.appendChild(selectf('Seltenheit', o, 'rarity', [['common', 'Normal'], ['rare', 'Selten'], ['epic', 'Episch'], ['legendary', 'Legendär']]));
    if (isNew) d.appendChild(selectf('Kategorie', o, 'category', CATS));
    d.appendChild(tf('Darstellung (JSON)', j, 'data', { area: true })); d.appendChild(cbf('Im Shop sichtbar', o, 'active'));
    d.appendChild(el('p', 'hint', 'Avatar: {"file":"assets/avatars/avatar-31.svg"} · Rahmen: {"file":"assets/frames/frame-x.svg"} · Farbe/Name: {"css":"#ff0000"} oder {"css":"linear-gradient(...)"} · Hintergrund: {"css":"..."} · Effekt: {"class":"fx-glow"}'));
    saveRow(d, isNew ? 'Artikel erstellen' : 'Speichern', async (err) => {
      try { o.data = JSON.parse(j.data || '{}'); } catch (e) { err.textContent = 'Die Darstellung ist kein gültiges JSON.'; return; }
      const r = await rpc('admin_save_item', { p_item: o }); if (r.error) err.textContent = errText(r.error); else { toast('Gespeichert'); go('admin', 'shop'); }
    }, isNew ? null : async (err) => { const r = await rpc('admin_delete_item', { p_id: o.id }); if (r.error) err.textContent = errText(r.error); else go('admin', 'shop'); });
    return d;
  };
  a.items.filter((i) => i.category === shopCat).forEach((it) => {
    const d = el('details', 'sec2'), s = el('summary'); s.appendChild(el('span', null, (it.active ? '' : '⏸ ') + it.name)); s.appendChild(el('span', 'hint', it.price + ' Coins · ' + it.rarity)); d.appendChild(s);
    const b = el('div'); b.appendChild(form(it, false)); d.appendChild(b); box.appendChild(d);
  });
  const nw = sec(box, '+ Neuer Artikel', false); nw.appendChild(form({}, true));
}

/* ---------- Börse ---------- */
function stocks(box, a) {
  const cfg = Object.assign({ interval_sec: 300, paused: false }, a.config.stocks || {});
  const m = sec(box, '📈 Markt', true);
  m.appendChild(el('p', 'adm-help', 'Die Kurse werden auf dem Server berechnet und ändern sich im eingestellten Abstand. Ist der Markt pausiert, bleiben die Kurse stehen und Kaufen ist gesperrt (Verkaufen geht weiter).'));
  m.appendChild(cbf('Markt pausiert', cfg)); m.appendChild(nf('Aktualisierung alle … Sekunden (30 bis 86400)', cfg, 'interval_sec', { min: 30 }));
  saveRow(m, 'Markt speichern', async (err) => { const r = await rpc('admin_save_config', { p_key: 'stocks', p_value: { interval_sec: Number(cfg.interval_sec), paused: !!cfg.paused } }); if (r.error) err.textContent = errText(r.error); else { toast('Gespeichert'); go('admin', 'stocks'); } });
  const list = sec(box, 'Unternehmen (' + a.companies.length + ')', true);
  const form = (c, isNew) => {
    const o = Object.assign({ id: null, symbol: '', name: '', descr: '', risk: 'medium', start_price: 10, volatility: 0.008, drift: 0, active: true, reset_price: false }, JSON.parse(JSON.stringify(c)));
    o.start_price = Number(o.start_price); o.volatility = Number(o.volatility); o.drift = Number(o.drift);
    const d = el('div', 'card');
    if (!isNew) d.appendChild(el('p', 'hint', 'Aktueller Kurs: ' + Number(c.price).toFixed(2) + ' Coins'));
    const r1 = el('div', 'row2'); r1.appendChild(tf('Kürzel (2 bis 6)', o, 'symbol', { max: 6 })); r1.appendChild(tf('Name', o, 'name', { max: 40 })); d.appendChild(r1);
    d.appendChild(tf('Beschreibung', o, 'descr', { max: 120 }));
    d.appendChild(selectf('Risiko', o, 'risk', [['low', 'Ruhig'], ['medium', 'Mittel'], ['high', 'Wild']]));
    const r2_ = el('div', 'row2'); r2_.appendChild(nf('Startkurs', o, 'start_price', { min: 0.5, step: '0.5' })); r2_.appendChild(nf('Schwankung pro Schritt', o, 'volatility', { min: 0, step: '0.001', hint: '0.004 ruhig, 0.014 wild' })); r2_.appendChild(nf('Trend', o, 'drift', { step: '0.0005', hint: '0 = fair' })); d.appendChild(r2_);
    d.appendChild(cbf('Aktiv (handelbar)', o, 'active'));
    if (!isNew) d.appendChild(cbf('Kurs auf Startkurs zurücksetzen', o, 'reset_price'));
    saveRow(d, isNew ? 'Unternehmen erstellen' : 'Speichern', async (err) => { const r = await rpc('admin_save_company', { p_company: o }); if (r.error) err.textContent = errText(r.error); else { toast('Gespeichert'); go('admin', 'stocks'); } },
      isNew ? null : async (err) => { const r = await rpc('admin_delete_company', { p_id: o.id }); if (r.error) err.textContent = errText(r.error); else go('admin', 'stocks'); });
    if (!isNew) {
      const hb = el('button', 'sec small', '📉 Kursverlauf ansehen (7 Tage)'); hb.style.marginTop = '8px'; const ch = el('div');
      hb.onclick = async () => { const r = await rpc('stock_history', { p_company: o.id, p_hours: 168 }); ch.innerHTML = ''; if (r.data) ch.appendChild(lineChart(r.data.map((p) => [p[0], Number(p[1])]), { cls: 'chart' })); };
      d.appendChild(hb); d.appendChild(ch);
    }
    return d;
  };
  a.companies.forEach((c) => { const d = el('details', 'sec2'), s = el('summary'); s.appendChild(el('span', null, (c.active ? '' : '⏸ ') + c.symbol + ' · ' + c.name)); s.appendChild(el('b', null, Number(c.price).toFixed(2))); d.appendChild(s); const b = el('div'); b.appendChild(form(c, false)); d.appendChild(b); list.appendChild(d); });
  const nw = sec(box, '+ Neues Unternehmen', false); nw.appendChild(form({}, true));
}
