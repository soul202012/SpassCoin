// Supabase-Client liegt lokal (vendor/supabase-2.45.4.js, offizielle Datei von npm), wird in index.html vor der App geladen.
// So läuft kein Code von fremden Servern und es gibt beim Start weniger Anfragen.
import { SUPABASE_URL, SUPABASE_KEY } from '../config.js';

export const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
});

export const rpc = (name, args) => Promise.resolve(sb.rpc(name, args || {}));
