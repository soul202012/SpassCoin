-- SpassCoin Erweiterung: im Supabase "SQL Editor" einfügen und "Run" klicken.
-- Voraussetzung: supabase-setup.sql wurde schon ausgeführt.

-- 0) Altes, unsicheres "Coins einfach kaufen" entfernen (ersetzt durch Anfragen)
drop function if exists public.buy_coins(int);

-- 1) Neue Spalten im Profil: Code, Serie, letzter Abholtag
alter table public.profiles
  add column if not exists code text unique,
  add column if not exists streak int not null default 0,
  add column if not exists last_claim date;

-- 2) Eindeutigen sechsstelligen Code erzeugen
create or replace function public.gen_code() returns text
language plpgsql set search_path = public as $$
declare c text;
begin
  loop
    c := (floor(random() * 900000) + 100000)::int::text;
    exit when not exists (select 1 from public.profiles where code = c);
  end loop;
  return c;
end $$;

-- Codes für schon vorhandene Konten nachtragen
do $$
declare r record;
begin
  for r in select id from public.profiles where code is null loop
    update public.profiles set code = public.gen_code() where id = r.id;
  end loop;
end $$;
alter table public.profiles alter column code set not null;

-- 3) Neue Konten bekommen automatisch einen Code
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, email, code)
  values (new.id, lower(new.raw_user_meta_data->>'username'), new.email, public.gen_code());
  return new;
end $$;

-- 4) Tabelle: Transaktionen
create table if not exists public.transactions (
  id bigint generated always as identity primary key,
  sender_id uuid references public.profiles(id) on delete set null,
  receiver_id uuid references public.profiles(id) on delete set null,
  amount bigint not null check (amount > 0),
  kind text not null check (kind in ('transfer','reward','grant')),
  created_at timestamptz not null default now()
);
alter table public.transactions enable row level security;
drop policy if exists "eigene Transaktionen lesen" on public.transactions;
create policy "eigene Transaktionen lesen" on public.transactions
  for select using (auth.uid() in (sender_id, receiver_id) or public.is_admin());

-- 5) Tabelle: Coin-Anfragen
create table if not exists public.coin_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount int not null check (amount between 1 and 100000),
  status text not null default 'open' check (status in ('open','approved','rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id) on delete set null
);
alter table public.coin_requests enable row level security;
drop policy if exists "eigene Anfragen lesen" on public.coin_requests;
create policy "eigene Anfragen lesen" on public.coin_requests
  for select using (auth.uid() = user_id or public.is_admin());

-- 6) Direktes Schreiben auf die Tabellen verbieten: Änderungen laufen NUR über die Funktionen unten
revoke all on public.profiles, public.transactions, public.coin_requests from anon;
revoke insert, update, delete on public.profiles, public.transactions, public.coin_requests from authenticated;

-- 7) Funktionen --------------------------------------------------------------

-- Coins an einen anderen Nutzer senden (atomar, mit Sperre gegen Doppelausgabe)
create or replace function public.send_coins(p_code text, p_amount int) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rid uuid; neu bigint;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Ungültige Anzahl'; end if;
  select id into rid from public.profiles where code = trim(p_code);
  if rid is null then raise exception 'Diesen Code gibt es nicht'; end if;
  if rid = me then raise exception 'Du kannst dir nicht selbst Coins senden'; end if;
  perform 1 from public.profiles where id in (me, rid) order by id for update;
  update public.profiles set balance = balance - p_amount
    where id = me and balance >= p_amount returning balance into neu;
  if neu is null then raise exception 'Nicht genug Coins'; end if;
  update public.profiles set balance = balance + p_amount where id = rid;
  insert into public.transactions (sender_id, receiver_id, amount, kind)
    values (me, rid, p_amount, 'transfer');
  return neu;
end $$;

-- Tägliche Belohnung (Tag wird nach Schweizer Zeit gezählt)
create or replace function public.claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p public.profiles%rowtype;
        today date := (now() at time zone 'Europe/Zurich')::date; ns int; rew int;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into p from public.profiles where id = me for update;
  if p.last_claim = today then raise exception 'Heute schon abgeholt'; end if;
  if p.last_claim = today - 1 then ns := p.streak + 1; else ns := 1; end if;
  rew := case when ns >= 14 then 4 when ns >= 7 then 2 else 1 end;
  update public.profiles set balance = balance + rew, streak = ns, last_claim = today where id = me;
  insert into public.transactions (sender_id, receiver_id, amount, kind) values (null, me, rew, 'reward');
  return json_build_object('reward', rew, 'streak', ns, 'balance', p.balance + rew);
end $$;

-- Coins anfragen
create or replace function public.request_coins(p_amount int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000 then raise exception 'Ungültige Anzahl'; end if;
  if (select count(*) from public.coin_requests where user_id = auth.uid() and status = 'open') >= 5 then
    raise exception 'Du hast schon 5 offene Anfragen';
  end if;
  insert into public.coin_requests (user_id, amount) values (auth.uid(), p_amount);
end $$;

-- Admin: offene Anfragen ansehen
create or replace function public.admin_requests()
returns table(req_id bigint, username text, email text, amount int, created_at timestamptz)
language plpgsql security definer set search_path = public stable as $$
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  return query select r.id, p.username, p.email, r.amount, r.created_at
    from public.coin_requests r join public.profiles p on p.id = r.user_id
    where r.status = 'open' order by r.created_at;
end $$;

-- Admin: Anfrage bestätigen oder ablehnen (bei Bestätigung werden die Coins gutgeschrieben)
create or replace function public.decide_request(p_id bigint, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r public.coin_requests%rowtype;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  select * into r from public.coin_requests where id = p_id for update;
  if not found or r.status <> 'open' then raise exception 'Anfrage nicht mehr offen'; end if;
  if p_approve then
    update public.profiles set balance = balance + r.amount where id = r.user_id;
    insert into public.transactions (sender_id, receiver_id, amount, kind)
      values (null, r.user_id, r.amount, 'grant');
  end if;
  update public.coin_requests
    set status = case when p_approve then 'approved' else 'rejected' end,
        decided_at = now(), decided_by = auth.uid()
    where id = p_id;
end $$;

-- Verlauf: eigene Transaktionen mit Benutzernamen
create or replace function public.my_transactions()
returns table(tx_id bigint, tx_time timestamptz, tx_amount bigint, tx_kind text, direction text, other_name text)
language sql security definer set search_path = public stable as $$
  select t.id, t.created_at, t.amount, t.kind,
         case when t.receiver_id = auth.uid() then 'in' else 'out' end,
         case when t.receiver_id = auth.uid() then s.username else r.username end
  from public.transactions t
  left join public.profiles s on s.id = t.sender_id
  left join public.profiles r on r.id = t.receiver_id
  where t.sender_id = auth.uid() or t.receiver_id = auth.uid()
  order by t.created_at desc, t.id desc limit 100
$$;

-- Rangliste: NUR Benutzername und Coins, keine E-Mail
create or replace function public.leaderboard()
returns table(username text, balance bigint)
language sql security definer set search_path = public stable as $$
  select p.username, p.balance from public.profiles p
  where auth.uid() is not null
  order by p.balance desc, p.username limit 200
$$;

-- 8) Wer darf welche Funktion aufrufen: nur angemeldete Nutzer
revoke all on function public.gen_code() from public, anon, authenticated;
revoke all on function public.send_coins(text,int) from public, anon;
revoke all on function public.claim_daily() from public, anon;
revoke all on function public.request_coins(int) from public, anon;
revoke all on function public.admin_requests() from public, anon;
revoke all on function public.decide_request(bigint,boolean) from public, anon;
revoke all on function public.my_transactions() from public, anon;
revoke all on function public.leaderboard() from public, anon;
grant execute on function public.send_coins(text,int) to authenticated;
grant execute on function public.claim_daily() to authenticated;
grant execute on function public.request_coins(int) to authenticated;
grant execute on function public.admin_requests() to authenticated;
grant execute on function public.decide_request(bigint,boolean) to authenticated;
grant execute on function public.my_transactions() to authenticated;
grant execute on function public.leaderboard() to authenticated;

-- 9) Admin anlegen (nur hier im SQL Editor möglich, NICHT über die Webseite):
--    Zuerst auf der Seite normal registrieren, dann diese Zeile mit deiner E-Mail ausführen:
-- update public.profiles set is_admin = true where email = 'deine@email.ch';
