-- SpassCoin: Login sicherer machen
-- 1) E-Mail-Suche per Benutzername nicht mehr öffentlich aufrufbar (macht jetzt die Edge Function login-username auf dem Server)
revoke execute on function public.email_for_username(text) from public, anon, authenticated;
-- Trigger-Funktion braucht niemand über die API (Trigger laufen trotzdem weiter)
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- 2) Sperre nach zu vielen falschen Passwörtern beim Login mit Benutzername (5 Fehlversuche -> 15 Minuten gesperrt)
create table if not exists public.login_attempts (
  username text primary key,
  fails int not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.login_attempts enable row level security;

-- Alte Einträge täglich aufräumen
select cron.schedule('spasscoin-login-attempts-cleanup', '17 3 * * *', $$delete from public.login_attempts where updated_at < now() - interval '1 day'$$);
