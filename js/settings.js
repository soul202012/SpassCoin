import { rpc } from './supabase.js';
import { state, DEFAULTS } from './state.js';
import { el } from './ui.js';
import { applyMusic, loadTracks, getTracks, selectTrack, nextTrack, musicInfo, currentTrack, trackLabel, sfx } from './audio.js';
import { renderPushSettings } from './notifications.js';

export function applyTheme() {
  const h = document.documentElement, S = state.S;
  h.setAttribute('data-theme', S.theme === 'light' ? 'light' : 'dark');
  const c = /^#[0-9a-f]{6}$/i.test(S.accent) ? S.accent : DEFAULTS.accent;
  const r = parseInt(c.substr(1, 2), 16), g = parseInt(c.substr(3, 2), 16), b = parseInt(c.substr(5, 2), 16);
  const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  h.style.setProperty('--accent', c); h.style.setProperty('--accent-t', lum > 0.6 ? '#111111' : '#ffffff');
  const m = document.querySelector('meta[name=theme-color]'); if (m) m.content = S.theme === 'light' ? '#ffffff' : '#0a0a0a';
}
let timer = null;
export function saveSettings() {
  applyTheme(); applyMusic();
  try { if (state.me) localStorage.setItem('sc_set_' + state.me.id, JSON.stringify(state.S)); } catch (e) { /* ignore */ }
  clearTimeout(timer);
  timer = setTimeout(() => { if (state.me) rpc('save_my_settings', { p_settings: state.S }).then(() => {}, () => {}); }, 600);
}
export function loadSettings() {
  let local = {};
  try { local = JSON.parse(localStorage.getItem('sc_set_' + state.me.id) || '{}'); } catch (e) { /* ignore */ }
  const remote = state.me.settings && typeof state.me.settings === 'object' ? state.me.settings : {};
  state.S = { ...DEFAULTS, ...local, ...remote };
  applyTheme(); applyMusic();
}

const ACCENTS = [['#d4af37', 'Gold'], ['#8b5cf6', 'Violett'], ['#22c55e', 'Grün'], ['#3b82f6', 'Blau'], ['#ef4444', 'Rot'], ['#ec4899', 'Pink'],
  ['#f97316', 'Orange'], ['#14b8a6', 'Türkis'], ['#06b6d4', 'Cyan'], ['#84cc16', 'Limette'], ['#fb7185', 'Rosa'], ['#e5e7eb', 'Silber']];

export async function renderSettings(box) {
  const S = state.S, row = (label, ctrl) => { const r = el('div', 'srow'); r.appendChild(el('span', null, label)); r.appendChild(ctrl); return r; };
  await loadTracks();
  const m = el('div', 'card'); m.appendChild(el('h2', null, 'Musik'));
  const mon = el('input'); mon.type = 'checkbox'; mon.checked = !!S.music_on; mon.onchange = () => { S.music_on = mon.checked; saveSettings(); };
  m.appendChild(row('Hintergrundmusik', mon));
  const vol = el('input'); vol.type = 'range'; vol.min = '0'; vol.max = '100'; vol.value = Math.round((Number(S.music_vol) || 0) * 100); vol.style.maxWidth = '180px'; vol.style.margin = '0';
  vol.oninput = () => { S.music_vol = vol.value / 100; saveSettings(); };
  m.appendChild(row('Lautstärke', vol));
  const tracks = getTracks();
  if (tracks.length) {
    const mode = el('select'); mode.style.maxWidth = '200px'; mode.style.margin = '0';
    [['auto', 'Automatisch wechseln'], ['track', 'Ein Lied wiederholen']].forEach(([v, t]) => { const o = el('option', null, t); o.value = v; mode.appendChild(o); });
    mode.value = S.music_mode || 'auto'; mode.onchange = () => { S.music_mode = mode.value; saveSettings(); };
    m.appendChild(row('Wiedergabe', mode));
    const sel = el('select'); sel.style.maxWidth = '200px'; sel.style.margin = '0';
    tracks.forEach((t) => { const o = el('option', null, trackLabel(t)); o.value = t.file; sel.appendChild(o); });
    sel.value = S.music_track || tracks[0].file;
    sel.onchange = () => { S.music_track = sel.value; selectTrack(sel.value); saveSettings(); };
    m.appendChild(row('Lied', sel));
    const nx = el('button', 'sec small', 'Nächstes Lied'); nx.onclick = () => nextTrack();
    const np = el('span', 'hint', currentTrack() ? trackLabel(currentTrack()) : ''); np.id = 'nowplaying';
    const r2 = el('div', 'srow'); r2.appendChild(np); r2.appendChild(nx); m.appendChild(r2);
  } else {
    m.appendChild(el('p', 'hint', 'Noch keine Musikdateien. Lege MP3-Dateien in den Ordner assets/music und trage sie in assets/music/music.json ein.'));
  }
  m.appendChild(el('p', 'hint', 'Die Musik startet nach dem ersten Tippen auf der Seite, so verlangt es der Browser.'));
  box.appendChild(m);

  const s = el('div', 'card'); s.appendChild(el('h2', null, 'Soundeffekte'));
  const sx = el('input'); sx.type = 'checkbox'; sx.checked = !!S.sfx_on; sx.onchange = () => { S.sfx_on = sx.checked; saveSettings(); if (S.sfx_on) sfx.coin(); };
  s.appendChild(row('Soundeffekte (Klicks, Gewinne, Spiele)', sx));
  box.appendChild(s);

  const d = el('div', 'card'); d.appendChild(el('h2', null, 'Aussehen'));
  const seg = el('div', 'seg');
  [['dark', '🌙 Dunkel (Schwarz)'], ['light', '☀️ Hell (Weiss)']].forEach(([k, t]) => {
    const b = el('button', S.theme === k ? 'on' : '', t); b.onclick = () => { S.theme = k; saveSettings(); box.innerHTML = ''; renderSettings(box); }; seg.appendChild(b);
  });
  d.appendChild(seg);
  d.appendChild(el('div', 'lbl', 'Akzentfarbe'));
  const sw = el('div', 'swatches');
  ACCENTS.forEach(([c, name]) => {
    const b = el('button', 'sw' + (S.accent.toLowerCase() === c ? ' on' : '')); b.style.background = c; b.title = name;
    b.onclick = () => { S.accent = c; saveSettings(); box.innerHTML = ''; renderSettings(box); }; sw.appendChild(b);
  });
  const pick = el('input'); pick.type = 'color'; pick.value = /^#[0-9a-f]{6}$/i.test(S.accent) ? S.accent : '#d4af37'; pick.style.width = '60px'; pick.style.margin = '0'; pick.title = 'Eigene Farbe';
  pick.onchange = () => { S.accent = pick.value; saveSettings(); box.innerHTML = ''; renderSettings(box); };
  sw.appendChild(pick); d.appendChild(sw);
  d.appendChild(el('p', 'hint', 'Die Basis bleibt Schwarz oder Weiss, nur die Akzentfarbe ändert sich. Weitere Profilfarben, Rahmen und Avatare gibt es im Shop.'));
  box.appendChild(d);

  const pushBox = el('div'); box.appendChild(pushBox); await renderPushSettings(pushBox);

  const rs = el('button', 'sec full', 'Einstellungen zurücksetzen'); rs.onclick = () => { state.S = { ...DEFAULTS }; saveSettings(); box.innerHTML = ''; renderSettings(box); };
  box.appendChild(rs);

  const cr = el('div', 'card'); cr.style.marginTop = '14px'; cr.appendChild(el('h2', null, 'Credits'));
  cr.appendChild(el('p', null, 'Produziert und erstellt von Laurel und Florian mit Hilfe der KI Claude.'));
  const credit = musicInfo.credit || { text: 'Musik: 8bit auf Spotify', url: 'https://open.spotify.com/search/8bit' };
  const p = el('p');
  if (credit.url) { const a = el('a', null, credit.text); a.href = credit.url; a.target = '_blank'; a.rel = 'noopener noreferrer'; p.appendChild(a); } else p.textContent = credit.text;
  cr.appendChild(p);
  cr.appendChild(el('p', 'hint', 'Soundeffekte werden direkt im Browser erzeugt und stammen von uns.'));
  box.appendChild(cr);
}
