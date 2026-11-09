import { sb, rpc } from '../supabase.js';
import { go } from '../state.js';
import { el, toast, errText } from '../ui.js';
import { nf, tf, cbf, selectf, listEditor, sec, liveInfo } from './forms.js';

export async function render(box, a, tab) {
  if (tab === 'rewards') return rewards(box, a);
  return push(box, a);
}

function rewards(box, a) {
  // ----- Daily Streak -----
  const rw = (a.config.streak_rewards || []).map((v) => ({ v: Number(v) }));
  const s = sec(box, '🔥 Tägliche Belohnung (Streak)', true);
  s.appendChild(el('p', 'adm-help', 'Coins pro Streak-Tag. Nach dem letzten Tag beginnt die Reihe von vorn, die Serie selbst läuft weiter. Die Coins zahlt die Bank.'));
  const infos = [];
  s.appendChild(listEditor(rw, [{ key: 'v', label: 'Coins an diesem Tag', min: 0, step: 1 }], () => ({ v: 5 }), false, () => infos.forEach((f) => f())));
  liveInfo(s, infos, () => 'Pro Durchlauf (' + rw.length + ' Tage): ' + rw.reduce((x, y) => x + (Number(y.v) || 0), 0) + ' Coins pro Spieler.');
  const e1 = el('p', 'err'); s.appendChild(e1);
  const b1 = el('button', 'full', 'Streak speichern');
  b1.onclick = async () => { e1.textContent = ''; const r = await rpc('admin_save_config', { p_key: 'streak_rewards', p_value: rw.map((x) => Number(x.v)) }); if (r.error) e1.textContent = errText(r.error); else toast('Gespeichert'); };
  s.appendChild(b1);

  // ----- Rettungsnetz -----
  const rs = Object.assign({ enabled: true, threshold: 10, amount: 10, hour: 0 }, a.config.rescue || {});
  const r = sec(box, '🛟 Rettungsnetz (nicht öffentlich sichtbar)', true);
  r.appendChild(el('p', 'adm-help', 'Wer zur eingestellten Stunde (Schweizer Zeit) weniger als das Mindestguthaben hat, bekommt einmal pro Tag den Betrag aus der Bank. Die Spieler sehen davon nur den Eintrag im Verlauf.'));
  r.appendChild(cbf('Rettungsnetz aktiv', rs));
  const row = el('div', 'row2');
  row.appendChild(nf('Mindestguthaben (Coins)', rs, 'threshold', { min: 1 })); row.appendChild(nf('Unterstützung (Coins)', rs, 'amount', { min: 1 })); row.appendChild(nf('Ab Stunde (0 = Mitternacht)', rs, 'hour', { min: 0, max: 23 }));
  r.appendChild(row);
  const e2 = el('p', 'err'); r.appendChild(e2);
  const b2 = el('button', 'full', 'Rettungsnetz speichern');
  b2.onclick = async () => { e2.textContent = ''; const x = await rpc('admin_save_config', { p_key: 'rescue', p_value: rs }); if (x.error) e2.textContent = errText(x.error); else toast('Gespeichert'); };
  r.appendChild(b2);
  const b3 = el('button', 'sec full', 'Jetzt prüfen und auszahlen'); b3.style.marginTop = '8px';
  b3.onclick = async () => { b3.disabled = true; const x = await rpc('admin_run_rescue'); b3.disabled = false; if (x.error) toast(errText(x.error), true); else toast(x.data + ' Spieler unterstützt'); };
  r.appendChild(b3);
}

async function push(box, a) {
  const c = el('div', 'card'); c.appendChild(el('h2', null, 'Push-Benachrichtigungen'));
  c.appendChild(el('p', null, 'Abonnierte Geräte: ' + (a.push.subscriptions || 0)));
  if (!a.push.ready) c.appendChild(el('p', 'err', 'Push ist noch nicht eingerichtet: Der geheime Push-Schlüssel fehlt in der Datenbank. Siehe README, Abschnitt «Push-Benachrichtigungen».'));
  c.appendChild(el('p', 'hint', 'Automatisch gesendet werden: Missionen (8:00), Streak-Erinnerung (18:00, nur wer noch nicht abgeholt hat) und Pferderennen (18:45), höchstens einmal pro Tag. Hier kannst du eigene Nachrichten schicken.'));
  box.appendChild(c);
  const f = el('div', 'card'); f.appendChild(el('h2', null, 'Nachricht senden'));
  const o = { title: '', body: '', category: 'events', url: '/' };
  f.appendChild(tf('Titel', o, 'title', { max: 60 })); f.appendChild(tf('Text', o, 'body', { area: true, max: 200 }));
  f.appendChild(selectf('Art', o, 'category', [['events', '🎉 Event / Herausforderung'], ['news', '🆕 Neue Funktion oder neues Spiel'], ['race', '🏇 Pferderennen'], ['streak', '🔥 Streak'], ['missions', '🎯 Missionen']]));
  f.appendChild(selectf('Öffnet', o, 'url', [['/', 'Startseite'], ['/?tab=games', 'Spiele'], ['/?tab=missions', 'Missionen'], ['/?tab=shop', 'Shop'], ['/?tab=rank', 'Rangliste']]));
  const err = el('p', 'err'); f.appendChild(err);
  const b = el('button', 'full', '🔔 Jetzt an alle senden');
  b.onclick = async () => {
    err.textContent = '';
    if (!o.title.trim() || !o.body.trim()) return (err.textContent = 'Bitte Titel und Text eingeben.');
    b.disabled = true;
    const r = await sb.functions.invoke('send-push', { body: { category: o.category, title: o.title.trim(), body: o.body.trim(), url: o.url, audience: 'all' } });
    b.disabled = false;
    if (r.error) { err.textContent = 'Senden hat nicht geklappt: ' + errText(r.error) + '. Ist die Funktion «send-push» in Supabase veröffentlicht? (siehe README)'; return; }
    const d = r.data || {}; toast('Gesendet an ' + (d.sent || 0) + ' Geräte' + (d.removed ? ', ' + d.removed + ' abgelaufene entfernt' : ''));
  };
  f.appendChild(b); box.appendChild(f);
}
