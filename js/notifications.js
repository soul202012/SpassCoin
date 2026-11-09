import { VAPID_PUBLIC_KEY } from '../config.js';
import { rpc } from './supabase.js';
import { state } from './state.js';
import { el, toast, errText } from './ui.js';

export const CATEGORIES = [
  ['race', '🏇 Pferderennen startet bald'],
  ['streak', '🔥 Deine Streak wartet'],
  ['missions', '🎯 Tägliche Missionen sind da'],
  ['events', '🎉 Events und Herausforderungen'],
  ['news', '🆕 Neue Funktionen und Spiele'],
];
export const isIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
export const isStandalone = () => window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
export const pushSupported = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

function urlB64ToUint8(b64) {
  const pad = '='.repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}
async function reg() { return navigator.serviceWorker.ready; }
export async function currentSubscription() {
  if (!pushSupported()) return null;
  try { return await (await reg()).pushManager.getSubscription(); } catch (e) { return null; }
}
export async function enablePush(categories) {
  if (!pushSupported()) throw new Error('Dieser Browser unterstützt keine Push-Nachrichten.');
  if (isIOS() && !isStandalone()) throw new Error('Auf dem iPhone musst du SpassCoin zuerst zum Home-Bildschirm hinzufügen und von dort öffnen.');
  const perm = await Notification.requestPermission();
  if (perm !== 'granted') throw new Error('Benachrichtigungen wurden nicht erlaubt.');
  const r = await reg();
  let sub = await r.pushManager.getSubscription();
  if (!sub) sub = await r.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlB64ToUint8(VAPID_PUBLIC_KEY) });
  const j = sub.toJSON();
  const res = await rpc('save_push_subscription', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_categories: categories || null, p_ua: navigator.userAgent });
  if (res.error) throw new Error(errText(res.error));
  return sub;
}
export async function disablePush() {
  const sub = await currentSubscription();
  if (!sub) return;
  await rpc('remove_push_subscription', { p_endpoint: sub.endpoint });
  await sub.unsubscribe();
}

// Bereich "Benachrichtigungen" für die Einstellungen
export async function renderPushSettings(box) {
  const card = el('div', 'card'); card.appendChild(el('h2', null, 'Benachrichtigungen'));
  box.appendChild(card);
  if (!pushSupported()) {
    card.appendChild(el('p', 'hint', isIOS() ? 'Auf dem iPhone gehen Benachrichtigungen nur, wenn du SpassCoin zum Home-Bildschirm hinzufügst (Teilen-Symbol, dann «Zum Home-Bildschirm») und die App von dort öffnest.' : 'Dein Browser unterstützt keine Push-Nachrichten.'));
    return;
  }
  if (isIOS() && !isStandalone()) {
    card.appendChild(el('p', 'hint', 'iPhone: Tippe im Safari auf das Teilen-Symbol, dann auf «Zum Home-Bildschirm». Öffne SpassCoin danach vom Home-Bildschirm und aktiviere die Benachrichtigungen hier.'));
    return;
  }
  const sub = await currentSubscription();
  const status = sub ? await rpc('my_push_status', { p_endpoint: sub.endpoint }) : { data: null };
  const cats = status.data || { race: true, streak: true, missions: true, events: true, news: true };
  const on = !!(sub && status.data);
  const row = el('div', 'srow'); row.appendChild(el('span', null, 'Benachrichtigungen erhalten'));
  const cb = el('input'); cb.type = 'checkbox'; cb.checked = on;
  cb.onchange = async () => {
    cb.disabled = true;
    try {
      if (cb.checked) { await enablePush(cats); toast('Benachrichtigungen sind an'); }
      else { await disablePush(); toast('Benachrichtigungen sind aus'); }
    } catch (e) { cb.checked = !cb.checked; toast(errText(e), true); }
    box.innerHTML = ''; renderPushSettings(box);
  };
  row.appendChild(cb); card.appendChild(row);
  if (on) {
    CATEGORIES.forEach(([k, label]) => {
      const r = el('div', 'srow'); r.appendChild(el('span', null, label));
      const c = el('input'); c.type = 'checkbox'; c.checked = cats[k] !== false;
      c.onchange = async () => {
        cats[k] = c.checked;
        const s = await currentSubscription();
        if (s) await rpc('set_push_categories', { p_endpoint: s.endpoint, p_categories: cats });
      };
      r.appendChild(c); card.appendChild(r);
    });
  }
  card.appendChild(el('p', 'hint', 'Es gibt nie mehr als eine Nachricht pro Art und Tag.'));
}
