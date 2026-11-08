import { rpc } from '../supabase.js';
import { state } from '../state.js';
import { el } from '../ui.js';

// Shop-Artikel einmal laden, damit Farben und Effekte überall gleich dargestellt werden
export async function loadCatalog(force) {
  if (state.catalog && !force) return state.catalog;
  const r = await rpc('shop_list');
  if (r.data) {
    const m = {}; r.data.items.forEach((i) => { m[i.id] = i; });
    state.catalog = m; state.shopData = r.data;
  }
  return state.catalog || {};
}
const cat = (id) => (state.catalog && state.catalog[id] && state.catalog[id].data) || {};

export function avatarEl(p, size) {
  const w = el('span', 'av'); w.style.setProperty('--s', (size || 44) + 'px');
  const a = el('img'); a.alt = ''; a.loading = 'lazy'; a.decoding = 'async';
  a.src = 'assets/avatars/' + (p.avatar || 'avatar-01') + '.svg'; w.appendChild(a);
  if (p.frame && p.frame !== 'frame-none') {
    const f = el('img', 'fr'); f.alt = ''; f.loading = 'lazy'; f.decoding = 'async'; f.src = 'assets/frames/' + p.frame + '.svg'; w.appendChild(f);
  }
  return w;
}
export function styleName(node, p) {
  const d = cat(p.name_color);
  if (d.css && d.css !== 'inherit') {
    if (String(d.css).indexOf('gradient') >= 0) { node.classList.add('gtext'); if (d.animated) node.classList.add('anim'); node.style.backgroundImage = d.css; }
    else node.style.color = d.css;
  }
  const fx = cat(p.rank_effect).class; if (fx) node.classList.add(fx);
  return node;
}
export function nameEl(p, text) { return styleName(el('span', 'pname', text || p.username), p); }
export const colorCss = (p) => cat(p.color).css || '#d4af37';
export function applyBackground(node, p) {
  const d = cat(p.background);
  if (d.css && d.css !== 'var(--card)') { node.style.background = d.css; if (d.size) node.style.backgroundSize = d.size; }
  else node.style.background = 'var(--card)';
}
