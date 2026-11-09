import { el, r2 } from '../ui.js';

// Zahlenfeld, das direkt in ein Objekt schreibt
export function nf(label, obj, key, opt, onChange) {
  opt = opt || {};
  const w = el('div', 'fld'); w.appendChild(el('div', 'lbl', label));
  const i = el('input'); i.type = 'number'; i.inputMode = 'decimal'; i.style.marginBottom = '0';
  if (opt.min != null) i.min = opt.min; if (opt.max != null) i.max = opt.max; if (opt.step) i.step = opt.step;
  i.value = obj[key];
  i.oninput = () => { obj[key] = i.value === '' ? NaN : Number(i.value); if (onChange) onChange(); };
  w.appendChild(i); if (opt.hint) w.appendChild(el('div', 'hint', opt.hint));
  return w;
}
export function tf(label, obj, key, opt, onChange) {
  opt = opt || {};
  const w = el('div', 'fld'); w.appendChild(el('div', 'lbl', label));
  const i = el(opt.area ? 'textarea' : 'input'); i.value = obj[key] == null ? '' : obj[key]; i.style.marginBottom = '0'; if (opt.max) i.maxLength = opt.max;
  i.oninput = () => { obj[key] = i.value; if (onChange) onChange(); };
  w.appendChild(i); if (opt.hint) w.appendChild(el('div', 'hint', opt.hint));
  return w;
}
export function cbf(label, obj, key, onChange) {
  const r = el('div', 'srow'); r.appendChild(el('span', null, label));
  const c = el('input'); c.type = 'checkbox'; c.checked = !!obj[key]; c.onchange = () => { obj[key] = c.checked; if (onChange) onChange(); };
  r.appendChild(c); return r;
}
export function selectf(label, obj, key, options, onChange) {
  const w = el('div', 'fld'); w.appendChild(el('div', 'lbl', label));
  const s = el('select'); s.style.marginBottom = '0';
  options.forEach(([v, t]) => { const o = el('option', null, t); o.value = v; s.appendChild(o); });
  s.value = obj[key]; s.onchange = () => { obj[key] = s.value; if (onChange) onChange(); };
  w.appendChild(s); return w;
}
// Liste mit Zeilen (hinzufügen, löschen)
export function listEditor(arr, cols, newItem, fixed, onChange) {
  const wrap = el('div');
  function draw() {
    wrap.innerHTML = '';
    const head = el('div', 'row2'); head.style.marginBottom = '4px';
    cols.forEach((c) => head.appendChild(el('div', 'hint', c.label)));
    if (!fixed) { const sp = el('div'); sp.style.flex = '0 0 44px'; head.appendChild(sp); }
    wrap.appendChild(head);
    arr.forEach((item, idx) => {
      const row = el('div', 'row2'); row.style.marginBottom = '6px';
      cols.forEach((c) => {
        const i = el('input'); i.type = c.type || 'number'; if (c.step) i.step = c.step; if (c.min != null) i.min = c.min; if (c.type === 'text') i.maxLength = c.max || 20;
        i.value = item[c.key];
        i.oninput = () => { item[c.key] = (c.type === 'text' || c.type === 'color') ? i.value : (i.value === '' ? NaN : Number(i.value)); onChange(); };
        row.appendChild(i);
      });
      if (!fixed) { const d = el('button', 'sec small', '✗'); d.style.flex = '0 0 44px'; d.onclick = () => { arr.splice(idx, 1); draw(); onChange(); }; row.appendChild(d); }
      wrap.appendChild(row);
    });
    if (!fixed) { const add = el('button', 'sec small', '+ hinzufügen'); add.onclick = () => { arr.push(newItem()); draw(); onChange(); }; wrap.appendChild(add); }
  }
  draw(); return wrap;
}
// Aufklappbarer Abschnitt
export function sec(parent, title, open) {
  const d = el('details', 'sec2'); if (open) d.open = true;
  const s = el('summary'); s.appendChild(el('span', null, title)); d.appendChild(s);
  const b = el('div'); d.appendChild(b); parent.appendChild(d); return b;
}
// Live berechneter Hinweis (Erwartungswert usw.)
export function liveInfo(box, infos, fn) { const p = el('div', 'ev'); infos.push(() => { p.textContent = fn(); }); box.appendChild(p); return p; }
export const sum = (a, k) => a.reduce((s, x) => s + Number(x[k]), 0);
export { r2 };
