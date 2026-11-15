// SpassCoin: Anmelden mit Benutzername (Supabase Edge Function, Deno)
// Sucht die E-Mail zum Benutzernamen nur hier auf dem Server und gibt nie die E-Mail, sondern nur die Sitzung zurück.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const FAIL = { error: 'login_failed' };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(FAIL, 405);
  try {
    const b = await req.json().catch(() => ({}));
    const username = String(b.username || '').trim().toLowerCase().slice(0, 64);
    const password = String(b.password || '').slice(0, 200);
    if (!username || !password) return json(FAIL, 400);

    const url = Deno.env.get('SUPABASE_URL')!;
    const db = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

    // Nach 5 Fehlversuchen ist der Name 15 Minuten gesperrt (gilt auch für unbekannte Namen, damit man sie nicht unterscheiden kann)
    const { data: att } = await db.from('login_attempts').select('fails,locked_until').eq('username', username).maybeSingle();
    if (att?.locked_until && new Date(att.locked_until) > new Date()) return json({ error: 'locked' }, 429);
    const fail = async () => {
      const fails = (att?.fails || 0) + 1, lock = fails >= 5;
      await db.from('login_attempts').upsert({ username, fails: lock ? 0 : fails, locked_until: lock ? new Date(Date.now() + 15 * 60000).toISOString() : null, updated_at: new Date().toISOString() });
      return json(lock ? { error: 'locked' } : FAIL, lock ? 429 : 401);
    };

    const { data: p } = await db.from('profiles').select('email').eq('username', username).maybeSingle();
    // Gleiche Antwort wie bei falschem Passwort, damit man nicht herausfinden kann, welche Namen es gibt
    if (!p?.email) return await fail();

    const anon = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { auth: { persistSession: false } });
    const { data, error } = await anon.auth.signInWithPassword({ email: p.email, password });
    if (error || !data.session) return await fail();
    if (att) await db.from('login_attempts').delete().eq('username', username);
    return json({ access_token: data.session.access_token, refresh_token: data.session.refresh_token });
  } catch (_e) {
    return json(FAIL, 500);
  }
});
