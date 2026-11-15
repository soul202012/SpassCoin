import { rpc } from '../supabase.js';
import { state, go } from '../state.js';
import { el, toast, errText, confirmBox } from '../ui.js';
import { sfx } from '../audio.js';
import { loadCatalog, avatarEl, applyFx } from '../profile/cosmetics.js';

const LABEL = { avatar: 'Avatare', frame: 'Rahmen', color: 'Profilfarben', background: 'Hintergründe', name_color: 'Namensfarben', rank_effect: 'Effekte' };
const PARAM = { avatar: 'p_avatar', frame: 'p_frame', color: 'p_color', background: 'p_background', name_color: 'p_name_color', rank_effect: 'p_rank_effect' };
let cat = 'avatar';

function preview(it, equipped) {
  const d = it.data || {}, p = el('div', 'prev');
  if (it.category === 'avatar') { const i = el('img'); i.src = d.file; i.loading = 'lazy'; i.style.cssText = 'width:60px;height:60px;border-radius:50%'; p.appendChild(i); }
  else if (it.category === 'frame') p.appendChild(avatarEl({ avatar: equipped.avatar, frame: it.id }, 56));
  else if (it.category === 'color') { p.style.background = d.css; if (d.animated) { p.classList.add('anim'); p.style.backgroundSize = '200% 100%'; } }
  else if (it.category === 'background') { p.style.background = d.css || 'var(--card)'; if (d.size) p.style.backgroundSize = d.size; if (d.class) p.classList.add(d.class); p.style.border = '1px solid var(--line)'; }
  else if (it.category === 'name_color') {
    p.textContent = 'Name'; p.style.fontWeight = '800';
    if (String(d.css).indexOf('gradient') >= 0) { p.classList.add('gtext'); if (d.animated) p.classList.add('anim'); p.style.backgroundImage = d.css; } else p.style.color = d.css;
  } else { const s = el('span', null, 'Name'); s.style.fontWeight = '800'; p.appendChild(applyFx(s, d)); }
  return p;
}

export async function renderShop(box) {
  await loadCatalog(true);
  const data = state.shopData, eq = data.equipped;
  const seg = el('div', 'chips');
  Object.keys(LABEL).forEach((k) => { const bt = el('button', cat === k ? 'on' : '', LABEL[k]); bt.onclick = () => { cat = k; go('shop'); }; seg.appendChild(bt); });
  box.appendChild(seg);
  const grid = el('div', 'shopgrid');
  data.items.filter((i) => i.category === cat).forEach((it) => {
    const card = el('div', 'shopitem ' + it.rarity);
    card.appendChild(preview(it, eq));
    card.appendChild(el('div', 'nm', it.name));
    card.appendChild(el('div', 'rar ' + it.rarity, { common: 'Normal', rare: 'Selten', epic: 'Episch', legendary: 'Legendär' }[it.rarity]));
    const active = eq[cat] === it.id;
    if (it.owned) {
      const bt = el('button', active ? 'sec small' : 'small', active ? '✓ Aktiv' : 'Ausrüsten'); bt.disabled = active;
      bt.onclick = async () => {
        bt.disabled = true; const r = await rpc('update_profile', { [PARAM[cat]]: it.id });
        if (r.error) { toast(errText(r.error), true); bt.disabled = false; } else { toast(it.name + ' ist aktiv'); state.catalog = null; go('shop'); }
      };
      card.appendChild(bt);
    } else {
      card.appendChild(el('div', 'price', it.price + ' Coins'));
      const bt = el('button', 'small', 'Kaufen'); bt.disabled = state.me.balance < it.price;
      bt.onclick = async () => {
        if (!(await confirmBox(it.name + ' kaufen?', 'Das kostet ' + it.price + ' Coins.', 'Kaufen'))) return;
        bt.disabled = true; const r = await rpc('buy_item', { p_item: it.id });
        if (r.error) { toast(errText(r.error), true); bt.disabled = false; return; }
        state.me.balance = Number(r.data.balance); sfx.buy(); toast('Gekauft: ' + it.name); state.catalog = null; go('shop');
      };
      card.appendChild(bt);
    }
    grid.appendChild(card);
  });
  if (!grid.childNodes.length) grid.appendChild(el('p', 'hint', 'In dieser Kategorie gibt es gerade nichts.'));
  box.appendChild(grid);
}
