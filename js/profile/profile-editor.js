import { rpc } from '../supabase.js';
import { state, go } from '../state.js';
import { el, inp, toast, errText } from '../ui.js';
import { loadCatalog, avatarEl } from './cosmetics.js';

const CATS = [['avatar', 'Avatar', 'p_avatar'], ['frame', 'Profilrahmen', 'p_frame'], ['color', 'Profilfarbe', 'p_color'],
  ['background', 'Hintergrund', 'p_background'], ['name_color', 'Namensfarbe', 'p_name_color'], ['rank_effect', 'Ranglisten-Effekt', 'p_rank_effect']];

function preview(it, me) {
  const d = it.data || {}, p = el('div', 'prev');
  if (it.category === 'avatar') { const i = el('img'); i.src = d.file; i.style.cssText = 'width:44px;height:44px;border-radius:50%'; p.appendChild(i); }
  else if (it.category === 'frame') { p.appendChild(avatarEl({ avatar: state.shopData.equipped.avatar, frame: it.id }, 40)); }
  else if (it.category === 'color') { p.style.background = d.css; }
  else if (it.category === 'background') { p.style.background = d.css || 'var(--card)'; if (d.size) p.style.backgroundSize = d.size; }
  else if (it.category === 'name_color') { p.textContent = 'Aa'; p.style.fontWeight = '800'; if (String(d.css).indexOf('gradient') >= 0) { p.classList.add('gtext'); p.style.backgroundImage = d.css; } else p.style.color = d.css; }
  else { p.textContent = it.name.slice(0, 2); }
  return p;
}

export async function renderEditor(box) {
  await loadCatalog(true);
  const data = state.shopData, sel = { ...data.equipped };
  const back = el('button', 'sec back', '← Zurück zum Profil'); back.onclick = () => go('profile'); box.appendChild(back);

  CATS.forEach(([cat, label]) => {
    const c = el('div', 'card'); c.appendChild(el('h2', null, label));
    const grid = el('div', 'pick');
    data.items.filter((i) => i.category === cat).forEach((it) => {
      const b = el('button', (sel[cat] === it.id ? 'on' : '') + (it.owned ? '' : ' locked'));
      b.appendChild(preview(it)); b.appendChild(el('span', null, it.name));
      if (!it.owned) b.appendChild(el('span', null, '🔒 ' + it.price));
      b.onclick = () => {
        if (!it.owned) return toast('Das gibt es im Shop für ' + it.price + ' Coins', true);
        sel[cat] = it.id; grid.querySelectorAll('button').forEach((x) => x.classList.remove('on')); b.classList.add('on');
      };
      grid.appendChild(b);
    });
    c.appendChild(grid); box.appendChild(c);
  });
  const save = el('button', 'full', 'Auswahl speichern');
  save.onclick = async () => {
    save.disabled = true;
    const args = {}; CATS.forEach(([cat, , param]) => { args[param] = sel[cat]; });
    const r = await rpc('update_profile', args);
    if (r.error) { toast(errText(r.error), true); save.disabled = false; } else { toast('Gespeichert'); state.catalog = null; go('profile'); }
  };
  box.appendChild(save);
  const shopBtn = el('button', 'sec full', '🛍️ Mehr im Shop'); shopBtn.style.marginTop = '8px'; shopBtn.onclick = () => go('shop'); box.appendChild(shopBtn);

  const u = el('div', 'card'); u.style.marginTop = '14px'; u.appendChild(el('h2', null, 'Benutzername ändern'));
  const ni = inp('Neuer Benutzername'); ni.value = state.me.username; ni.autocapitalize = 'none'; u.appendChild(ni);
  u.appendChild(el('p', 'hint', '3 bis 20 Zeichen (Buchstaben, Zahlen, _ . -). Nur einmal pro Woche möglich. Dein sechsstelliger Code bleibt gleich.'));
  const nb = el('button', 'full', 'Namen ändern'); nb.style.marginTop = '8px';
  nb.onclick = async () => {
    nb.disabled = true; const r = await rpc('change_username', { p_name: ni.value });
    if (r.error) { toast(errText(r.error), true); nb.disabled = false; } else { state.me.username = r.data; toast('Name geändert'); state.profileUser = null; go('profile'); }
  };
  u.appendChild(nb); box.appendChild(u);
}
