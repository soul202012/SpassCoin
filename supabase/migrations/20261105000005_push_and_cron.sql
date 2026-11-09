-- SpassCoin 2.0, Teil 5: Push-Benachrichtigungen und geplante Aufgaben (Rettungsnetz, Boerse, Erinnerungen)

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create table if not exists public.push_subscriptions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text unique not null,
  p256dh text not null,
  auth_key text not null,
  categories jsonb not null default '{"race":true,"streak":true,"missions":true,"events":true,"news":true}'::jsonb,
  user_agent text,
  created_at timestamptz not null default now(),
  last_success timestamptz
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

-- Geheime Push-Einstellungen: nur die Edge Function (Service-Rolle) und Datenbank-Funktionen duerfen das lesen
create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  vapid_public text,
  vapid_private text,
  subject text not null default 'mailto:admin@spasscoin.example',
  cron_secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  function_url text
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (id, function_url)
  values (1, 'https://aghqqdpdtxeajuhfcveq.supabase.co/functions/v1/send-push')
  on conflict (id) do update set function_url = excluded.function_url;

create table if not exists public.push_log (
  kind text not null,
  day date not null,
  created_at timestamptz not null default now(),
  primary key (kind, day)
);
alter table public.push_log enable row level security;
revoke all on public.push_log from anon, authenticated;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text,
  p_categories jsonb default null, p_ua text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  if p_endpoint is null or length(p_endpoint) < 20 or p_p256dh is null or p_auth is null then raise exception 'Ungültiges Abo'; end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth_key, categories, user_agent)
    values (me, p_endpoint, p_p256dh, p_auth,
            coalesce(p_categories, '{"race":true,"streak":true,"missions":true,"events":true,"news":true}'::jsonb), left(p_ua, 200))
  on conflict (endpoint) do update set user_id = me, p256dh = excluded.p256dh, auth_key = excluded.auth_key,
    categories = coalesce(p_categories, public.push_subscriptions.categories), user_agent = excluded.user_agent;
end $$;

create or replace function public.remove_push_subscription(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
end $$;

create or replace function public.set_push_categories(p_endpoint text, p_categories jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if jsonb_typeof(p_categories) <> 'object' then raise exception 'Ungültige Auswahl'; end if;
  update public.push_subscriptions set categories = p_categories where endpoint = p_endpoint and user_id = auth.uid();
end $$;

create or replace function public.my_push_status(p_endpoint text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  return (select categories from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid());
end $$;

-- Ruft die Edge Function auf (nur fuer geplante Aufgaben in der Datenbank)
create or replace function public.push_notify(p_category text, p_title text, p_body text, p_url text default '/', p_audience text default 'all')
returns void language plpgsql security definer set search_path = public as $$
declare cfg public.push_config%rowtype;
begin
  select * into cfg from public.push_config where id = 1;
  if cfg.function_url is null or cfg.vapid_private is null then return; end if;
  perform net.http_post(
    url := cfg.function_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cfg.cron_secret),
    body := jsonb_build_object('category', p_category, 'title', p_title, 'body', p_body, 'url', p_url, 'audience', p_audience));
end $$;

-- Laeuft alle 5 Minuten. Pro Art und Tag wird hoechstens einmal gesendet (kein Spam).
create or replace function public.run_scheduled_pushes() returns void
language plpgsql security definer set search_path = public as $$
declare lt timestamp := now() at time zone 'Europe/Zurich'; today date := (now() at time zone 'Europe/Zurich')::date;
        mins int; did boolean;
begin
  mins := extract(hour from lt)::int * 60 + extract(minute from lt)::int;
  did := null;
  if mins >= 480 and mins < 510 then
    insert into public.push_log (kind, day) values ('missions', today) on conflict do nothing returning true into did;
    if did then perform public.push_notify('missions', 'Neue Missionen', 'Deine täglichen Missionen warten auf dich.', '/?tab=missions'); end if;
  end if;
  did := null;
  if mins >= 1080 and mins < 1110 then
    insert into public.push_log (kind, day) values ('streak', today) on conflict do nothing returning true into did;
    if did then perform public.push_notify('streak', 'Deine Streak wartet', 'Hol dir heute noch deine Tagesbelohnung.', '/?tab=home', 'streak_pending'); end if;
  end if;
  did := null;
  if mins >= 1125 and mins < 1155 then
    insert into public.push_log (kind, day) values ('race', today) on conflict do nothing returning true into did;
    if did then perform public.push_notify('race', 'Pferderennen um 19:00 Uhr', 'Das Rennen startet bald. Jetzt noch wetten!', '/?tab=games&game=race'); end if;
  end if;
end $$;

revoke all on function public.push_notify(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.run_scheduled_pushes() from public, anon, authenticated;
revoke all on function public.save_push_subscription(text, text, text, jsonb, text) from public, anon;
revoke all on function public.remove_push_subscription(text) from public, anon;
revoke all on function public.set_push_categories(text, jsonb) from public, anon;
revoke all on function public.my_push_status(text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, jsonb, text) to authenticated;
grant execute on function public.remove_push_subscription(text) to authenticated;
grant execute on function public.set_push_categories(text, jsonb) to authenticated;
grant execute on function public.my_push_status(text) to authenticated;

-- Geplante Aufgaben: Erinnerungen (alle 5 Minuten), Rettungsnetz + Tagesschnappschuss (stuendlich), Boerse (jede Minute, nur wenn faellig)
select cron.schedule('spasscoin-push', '*/5 * * * *', 'select public.run_scheduled_pushes()');
select cron.schedule('spasscoin-hourly', '5 * * * *', 'select public.run_rescue(false); select public.snapshot_economy()');
select cron.schedule('spasscoin-stocks', '* * * * *', 'select public.stock_tick(false)');
