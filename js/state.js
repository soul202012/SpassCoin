import { sb, rpc } from './supabase.js';

export const DEFAULTS = { music_on: true, music_vol: 0.4, music_mode: 'auto', music_track: '', sfx_on: true, theme: 'dark', accent: '#d4af37' };

export const state = {
  me: null,
  S: { ...DEFAULTS },
  tab: 'home',
  sub: null,
  profileUser: null,
  config: null, configAt: 0,
  catalog: null,
  navigate: null,
  dirty: false,
};

export const canAdmin = () => !!(state.me && (state.me.is_admin || state.me.is_test));

let meAt = 0;
export async function refreshMe(force) {
  if (!force && state.me && Date.now() - meAt < 2500) return state.me;
  let id = state.me && state.me.id;
  if (!id) { const s = await sb.auth.getSession(); if (!s.data.session) return null; id = s.data.session.user.id; }
  const r = await sb.from('profiles').select('*').eq('id', id).single();
  if (r.data) { state.me = r.data; meAt = Date.now(); }
  return state.me;
}
export function setBal() {
  if (!state.me) return;
  document.querySelectorAll('[data-bal]').forEach((n) => { n.textContent = state.me.balance; });
}
export async function getConfig(force) {
  if (!force && state.config && Date.now() - state.configAt < 60000) return state.config;
  const r = await rpc('get_public_config');
  if (r.data) { state.config = r.data; state.configAt = Date.now(); }
  return state.config;
}
export function invalidateConfig() { state.config = null; }
export function go(tab, sub) { if (state.navigate) state.navigate(tab, sub); }
