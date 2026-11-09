import { sb, rpc } from './supabase.js';

export const DEFAULTS = { music_on: true, music_vol: 0.4, music_mode: 'auto', music_track: '', sfx_on: true, theme: 'dark', accent: '#d4af37' };

// Gemeinsamer Zustand der App (kein globales Chaos, alles an einem Ort)
export const state = {
  me: null,            // eigenes Profil
  S: { ...DEFAULTS },  // Einstellungen
  tab: 'home',
  sub: null,           // Unterseite (z. B. Spiel, Admin-Reiter)
  profileUser: null,   // Benutzername für die Profilseite
  config: null, configAt: 0,
  catalog: null,       // Shop-Artikel nach ID (für Darstellung von Kosmetik)
  navigate: null,      // wird von app.js gesetzt
};

export const canAdmin = () => !!(state.me && (state.me.is_admin || state.me.is_test));

export async function refreshMe() {
  const s = await sb.auth.getSession();
  if (!s.data.session) return null;
  const r = await sb.from('profiles').select('*').eq('id', s.data.session.user.id).single();
  if (r.data) state.me = r.data;
  return state.me;
}
export function setBal() {
  const b = document.getElementById('gbal');
  if (b && state.me) b.textContent = state.me.balance;
}
export async function getConfig(force) {
  if (!force && state.config && Date.now() - state.configAt < 60000) return state.config;
  const r = await rpc('get_public_config');
  if (r.data) { state.config = r.data; state.configAt = Date.now(); }
  return state.config;
}
export function invalidateConfig() { state.config = null; }
export function go(tab, sub) { if (state.navigate) state.navigate(tab, sub); }
