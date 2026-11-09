import { state } from './state.js';

/* ---------- Soundeffekte: selbst mit der Web Audio API erzeugt (keine Fremddateien, keine Lizenz nötig) ---------- */
let AC = null;
function ac() {
  if (!AC) { const C = window.AudioContext || window.webkitAudioContext; if (C) AC = new C(); }
  if (AC && AC.state === 'suspended') AC.resume();
  return AC;
}
function tone(f, d, type, v, when, slide) {
  if (!state.S.sfx_on) return;
  const a = ac(); if (!a) return;
  const t = a.currentTime + (when || 0), o = a.createOscillator(), g = a.createGain();
  o.type = type || 'sine'; o.frequency.setValueAtTime(f, t);
  if (slide) o.frequency.exponentialRampToValueAtTime(slide, t + d);
  g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime((v || 0.2) * 0.8, t + 0.01); g.gain.exponentialRampToValueAtTime(0.0001, t + d);
  o.connect(g); g.connect(a.destination); o.start(t); o.stop(t + d + 0.03);
}
function noise(d, v, when, ft, f) {
  if (!state.S.sfx_on) return;
  const a = ac(); if (!a) return;
  const t = a.currentTime + (when || 0), n = Math.floor(a.sampleRate * d), buf = a.createBuffer(1, n, a.sampleRate), dt = buf.getChannelData(0);
  for (let i = 0; i < n; i++) dt[i] = Math.random() * 2 - 1;
  const s = a.createBufferSource(); s.buffer = buf;
  const fl = a.createBiquadFilter(); fl.type = ft || 'lowpass'; fl.frequency.value = f || 1000;
  const g = a.createGain(); g.gain.setValueAtTime((v || 0.3) * 0.8, t); g.gain.exponentialRampToValueAtTime(0.0001, t + d);
  s.connect(fl); fl.connect(g); g.connect(a.destination); s.start(t);
}
export const sfx = {
  click: () => tone(640, 0.05, 'square', 0.07),
  tick: () => tone(900, 0.03, 'square', 0.05),
  stop: () => tone(180, 0.12, 'triangle', 0.25, 0, 90),
  chest: () => tone(260, 0.12, 'triangle', 0.18, 0, 520),
  coin: () => { tone(1318, 0.08, 'square', 0.1); tone(1760, 0.2, 'square', 0.1, 0.08); },
  win: () => { [523, 659, 784, 1047].forEach((f, i) => tone(f, 0.18, 'triangle', 0.18, i * 0.1)); sfx.coin(); },
  big: () => [523, 659, 784, 1047, 1319, 1568].forEach((f, i) => tone(f, 0.2, 'triangle', 0.2, i * 0.09)),
  lose: () => tone(300, 0.4, 'sawtooth', 0.14, 0, 110),
  bomb: () => { noise(0.8, 0.6, 0, 'lowpass', 500); tone(110, 0.6, 'sawtooth', 0.3, 0, 35); },
  card: () => noise(0.07, 0.3, 0, 'highpass', 2500),
  flip: () => { noise(0.05, 0.25, 0, 'highpass', 3500); tone(420, 0.06, 'triangle', 0.08); },
  spin: () => { for (let i = 0; i < 10; i++) tone(500 + i * 40, 0.05, 'square', 0.04, i * 0.12); },
  gun: () => { noise(0.25, 0.5, 0, 'highpass', 1200); tone(880, 0.3, 'square', 0.1, 0.05); },
  hoof: () => { tone(110, 0.06, 'sine', 0.18, 0, 70); tone(95, 0.06, 'sine', 0.14, 0.09, 60); },
  ping: (i) => tone(700 + (i % 7) * 60, 0.07, 'triangle', 0.1),
  scratch: () => noise(0.06, 0.12, 0, 'bandpass', 3000),
  buy: () => { tone(880, 0.07, 'square', 0.1); tone(1175, 0.12, 'square', 0.1, 0.07); },
};
document.addEventListener('click', (e) => {
  if (e.target.closest && e.target.closest('button,.tile:not(.off),.horse')) sfx.click();
}, true);

/* ---------- Hintergrundmusik: mehrere Dateien aus assets/music, Liste in assets/music/music.json ---------- */
const music = new Audio();
music.preload = 'none';
let tracks = [], idx = 0, started = false, loaded = false;
export const musicInfo = { missing: false, credit: null };

export async function loadTracks() {
  if (loaded) return tracks;
  loaded = true;
  try {
    const r = await fetch('assets/music/music.json', { cache: 'no-cache' });
    if (!r.ok) throw new Error('keine music.json');
    const j = await r.json();
    tracks = (j.tracks || []).filter((t) => t && t.file);
    musicInfo.credit = j.credit || null;
  } catch (e) { tracks = []; }
  musicInfo.missing = tracks.length === 0;
  return tracks;
}
export const getTracks = () => tracks;
export const currentTrack = () => tracks[idx] || null;

function setSrc() {
  const t = tracks[idx];
  if (t) music.src = 'assets/music/' + encodeURIComponent(t.file);
}
music.addEventListener('ended', () => {
  if (state.S.music_mode === 'track') { music.currentTime = 0; music.play().catch(() => {}); return; }
  nextTrack();
});
music.addEventListener('error', () => { if (tracks.length > 1) setTimeout(nextTrack, 500); });
export function nextTrack() {
  if (!tracks.length) return;
  idx = (idx + 1) % tracks.length; state.S.music_track = tracks[idx].file; setSrc();
  if (state.S.music_on && started) music.play().catch(() => {});
  const n = document.getElementById('nowplaying'); if (n) n.textContent = trackLabel(tracks[idx]);
}
export const trackLabel = (t) => (t ? (t.title || t.file) + (t.artist ? ' – ' + t.artist : '') : 'Keine Musik');
export function selectTrack(file) {
  const i = tracks.findIndex((t) => t.file === file);
  if (i < 0) return;
  idx = i; setSrc(); applyMusic();
}
export async function applyMusic() {
  await loadTracks();
  music.volume = Math.max(0, Math.min(1, Number(state.S.music_vol) || 0));
  if (!tracks.length) return;
  if (state.S.music_mode === 'track' && state.S.music_track) {
    const i = tracks.findIndex((t) => t.file === state.S.music_track); if (i >= 0) idx = i;
  }
  if (!music.src) setSrc();
  if (state.S.music_on && started) music.play().catch(() => {}); else music.pause();
}
// Browser erlauben Ton erst nach der ersten Berührung
document.addEventListener('pointerdown', () => { if (!started) { started = true; applyMusic(); } }, { capture: true });
export function stopMusic() { music.pause(); }
