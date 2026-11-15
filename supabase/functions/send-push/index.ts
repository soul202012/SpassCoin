// SpassCoin: Push-Nachrichten senden (Supabase Edge Function, Deno)
// Aufrufer: (1) ein Admin aus der Webseite (Anmelde-Token) oder (2) die Datenbank-Zeitplanung mit dem geheimen Header x-cron-secret.
// Die geheimen Push-Schlüssel stehen nur in der Datenbanktabelle push_config und sind für Spieler nie lesbar.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const CATEGORIES = ['race', 'streak', 'missions', 'events', 'news'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: cfg } = await db.from('push_config').select('*').eq('id', 1).single();
    if (!cfg || !cfg.vapid_private || !cfg.vapid_public) return json({ error: 'Push ist noch nicht eingerichtet (VAPID-Schlüssel fehlen).' }, 400);

    // Wer darf senden?
    let allowed = false;
    const secret = req.headers.get('x-cron-secret');
    if (secret && secret === cfg.cron_secret) allowed = true;
    else {
      const jwt = (req.headers.get('Authorization') || '').replace('Bearer ', '');
      if (jwt) {
        const { data: u } = await db.auth.getUser(jwt);
        if (u?.user) {
          const { data: p } = await db.from('profiles').select('is_admin,is_test').eq('id', u.user.id).single();
          allowed = !!(p && (p.is_admin || p.is_test));
        }
      }
    }
    if (!allowed) return json({ error: 'Nicht erlaubt' }, 403);

    const b = await req.json();
    const category = String(b.category || '');
    const title = String(b.title || '').slice(0, 80);
    const body = String(b.body || '').slice(0, 240);
    const url = String(b.url || '/').slice(0, 200);
    if (!CATEGORIES.includes(category) || !title || !body) return json({ error: 'Ungültige Nachricht' }, 400);

    webpush.setVapidDetails(cfg.subject, cfg.vapid_public, cfg.vapid_private);

    const { data: subs } = await db.from('push_subscriptions').select('id,endpoint,p256dh,auth_key,user_id,categories');
    let targets = (subs || []).filter((s) => !s.categories || s.categories[category] !== false);

    // Zielgruppe: nur Spieler, die ihre Tagesbelohnung noch nicht abgeholt haben
    if (b.audience === 'streak_pending') {
      const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Zurich' });
      const { data: pend } = await db.from('profiles').select('id,last_claim,is_admin,is_test');
      const ids = new Set((pend || []).filter((p) => !p.is_admin && !p.is_test && (!p.last_claim || p.last_claim < today)).map((p) => p.id));
      targets = targets.filter((s) => ids.has(s.user_id));
    }

    const payload = JSON.stringify({ title, body, url, category });
    let sent = 0, failed = 0;
    const dead: number[] = [];
    await Promise.all(targets.map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } }, payload, { TTL: 3600 });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) dead.push(s.id); else failed++;
      }
    }));
    if (dead.length) await db.from('push_subscriptions').delete().in('id', dead); // abgelaufene Abos entfernen
    if (sent) await db.from('push_subscriptions').update({ last_success: new Date().toISOString() }).in('id', targets.map((t) => t.id).filter((i) => !dead.includes(i)));
    return json({ sent, failed, removed: dead.length });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
