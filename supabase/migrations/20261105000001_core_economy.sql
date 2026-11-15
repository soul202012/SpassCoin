-- SpassCoin 2.0, Teil 1: Kernsystem (Konfiguration, Spielprotokoll, Statistiken, Streak-Coins, Rettungsnetz)
-- Rückwärtskompatibel: die bisherige Seite funktioniert weiter.

-- ===================== Transaktionsarten =====================
alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check
  check (kind in ('transfer','reward','grant','game_chest','game_wheel','game_slots','game_bj','game_race',
                  'admin_adjust','rescue','mission','shop','game_plinko','game_scratch','game_hilo','game_poker',
                  'stock_buy','stock_sell'));
create index if not exists transactions_created_idx on public.transactions (created_at);
create index if not exists transactions_receiver_idx on public.transactions (receiver_id, created_at);
create index if not exists transactions_sender_idx on public.transactions (sender_id, created_at);

-- ===================== Zentrale Konfiguration =====================
create table if not exists public.app_config (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;

insert into public.app_config (key, value) values
 ('streak_rewards', '[5,5,7,7,10,10,20]'),
 ('rescue', '{"enabled":true,"threshold":10,"amount":10,"hour":0}'),
 ('missions', '{"slots":["easy","medium","hard"]}'),
 ('plinko', '{"rows":12,"levels":{
    "low":[7.1,4.9,3.2,1.9,1.1,0.6,0.5,0.6,1.1,1.9,3.2,4.9,7.1],
    "medium":[18,10.5,5.5,2.5,1,0.4,0.3,0.4,1,2.5,5.5,10.5,18],
    "high":[43.8,20.5,8.1,2.6,0.6,0.2,0.2,0.2,0.6,2.6,8.1,20.5,43.8]}}'),
 ('scratch', '{"cells":8,"symbols":[
    {"id":"coin","icon":"🪙","name":"Münze"},{"id":"star","icon":"⭐","name":"Stern"},
    {"id":"diamond","icon":"💎","name":"Diamant"},{"id":"crown","icon":"👑","name":"Krone"},
    {"id":"spass","icon":"Ⓢ","name":"SpassCoin"},{"id":"clover","icon":"🍀","name":"Kleeblatt"},
    {"id":"bell","icon":"🔔","name":"Glocke"},{"id":"rocket","icon":"🚀","name":"Rakete"}],
  "tiers":[{"matches":0,"p":0.7135,"mult":0},{"matches":2,"p":0.22,"mult":1.5},{"matches":3,"p":0.055,"mult":5},
           {"matches":4,"p":0.01,"mult":20},{"matches":5,"p":0.0015,"mult":100}]}'),
 ('hilo', '{"ladder":[1.1,1.6,2.3,3.3,4.8,7,10,14.5,21,30],"tie":"lose"}'),
 ('poker', '{"paytable":{"royal":250,"straight_flush":50,"four":25,"full_house":8,"flush":5,"straight":4,"three":3,"two_pair":2,"jacks":1}}')
on conflict (key) do nothing;

-- ===================== Spiele aktivieren, Einsatzgrenzen, Tageslimits =====================
create table if not exists public.game_toggles (
  game text primary key,
  enabled boolean not null default true,
  min_stake int not null default 1 check (min_stake >= 1),
  max_stake int not null default 1000 check (max_stake >= 1),
  daily_round_limit int check (daily_round_limit is null or daily_round_limit >= 1)
);
alter table public.game_toggles enable row level security;
revoke all on public.game_toggles from anon, authenticated;
insert into public.game_toggles (game, max_stake) values
 ('chest',1000),('wheel',1000),('race',1000),('slots',1000),('blackjack',1000),
 ('plinko',100),('scratch',100),('hilo',100),('poker',100),('stocks',1000)
on conflict (game) do nothing;

-- ===================== Spielprotokoll und Statistiken =====================
create table if not exists public.game_rounds (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  game text not null,
  stake int not null,
  payout int not null,
  net int not null,
  win boolean not null,
  detail jsonb,
  day date not null default ((now() at time zone 'Europe/Zurich')::date),
  created_at timestamptz not null default now()
);
create index if not exists game_rounds_user_idx on public.game_rounds (user_id, created_at desc);
create index if not exists game_rounds_created_idx on public.game_rounds (created_at);
create index if not exists game_rounds_game_idx on public.game_rounds (game, created_at);
create index if not exists game_rounds_day_idx on public.game_rounds (day);
alter table public.game_rounds enable row level security;
revoke all on public.game_rounds from anon, authenticated;

create table if not exists public.player_stats (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  rounds int not null default 0,
  wins int not null default 0,
  losses int not null default 0,
  earned bigint not null default 0,
  spent bigint not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.player_stats enable row level security;
revoke all on public.player_stats from anon, authenticated;

create table if not exists public.player_day_games (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  games text[] not null default '{}',
  primary key (user_id, day)
);
alter table public.player_day_games enable row level security;
revoke all on public.player_day_games from anon, authenticated;

create table if not exists public.economy_snapshots (
  day date primary key,
  bank bigint not null,
  circulation bigint not null,
  players int not null,
  rounds int not null,
  staked bigint not null,
  paid bigint not null,
  created_at timestamptz not null default now()
);
alter table public.economy_snapshots enable row level security;
revoke all on public.economy_snapshots from anon, authenticated;

create or replace function public.mission_progress(p_user uuid, p_game text, p_win boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  null;  -- wird in Teil 3 durch die echte Missionslogik ersetzt
end $$;

create or replace function public.stat_add(p_user uuid, p_earned bigint, p_spent bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles where id = p_user and (is_test or is_admin)) then return; end if;
  insert into public.player_stats (user_id, earned, spent) values (p_user, greatest(p_earned, 0), greatest(p_spent, 0))
  on conflict (user_id) do update set earned = public.player_stats.earned + greatest(p_earned, 0),
    spent = public.player_stats.spent + greatest(p_spent, 0), updated_at = now();
end $$;

-- Jede abgeschlossene Spielrunde wird hier festgehalten (Test- und Admin-Konten erscheinen in keiner Statistik)
create or replace function public.record_round(p_user uuid, p_game text, p_stake bigint, p_payout bigint, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare t boolean; today date := (now() at time zone 'Europe/Zurich')::date; w boolean := p_payout > p_stake;
begin
  insert into public.player_day_games (user_id, day, games) values (p_user, today, array[p_game])
  on conflict (user_id, day) do update set games = (select array_agg(distinct x) from unnest(public.player_day_games.games || p_game) x);
  perform public.mission_progress(p_user, p_game, w);
  select (is_test or is_admin) into t from public.profiles where id = p_user;
  if coalesce(t, true) then return; end if;
  insert into public.game_rounds (user_id, game, stake, payout, net, win, detail, day)
    values (p_user, p_game, p_stake, p_payout, p_payout - p_stake, w, p_detail, today);
  insert into public.player_stats (user_id, rounds, wins, losses, earned, spent)
    values (p_user, 1, case when w then 1 else 0 end, case when p_payout < p_stake then 1 else 0 end, p_payout, p_stake)
  on conflict (user_id) do update set rounds = public.player_stats.rounds + 1,
    wins = public.player_stats.wins + case when w then 1 else 0 end,
    losses = public.player_stats.losses + case when p_payout < p_stake then 1 else 0 end,
    earned = public.player_stats.earned + p_payout, spent = public.player_stats.spent + p_stake, updated_at = now();
end $$;

-- Aktivierung, Einsatzgrenzen und Tageslimit prüfen
create or replace function public.game_check(p_game text, p_user uuid, p_stake bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare g public.game_toggles%rowtype; n int;
begin
  select * into g from public.game_toggles where game = p_game;
  if not found then return; end if;
  if not g.enabled then raise exception 'Dieses Spiel ist gerade ausgeschaltet'; end if;
  if p_stake is not null and p_stake < g.min_stake then raise exception 'Der Mindesteinsatz ist % Coins', g.min_stake; end if;
  if p_stake is not null and p_stake > g.max_stake then raise exception 'Der Höchsteinsatz ist % Coins', g.max_stake; end if;
  if g.daily_round_limit is not null then
    select count(*) into n from public.game_rounds where user_id = p_user and game = p_game
      and day = (now() at time zone 'Europe/Zurich')::date;
    if n >= g.daily_round_limit then raise exception 'Das Tageslimit für dieses Spiel ist erreicht'; end if;
  end if;
end $$;

-- Alle Spiele sind immer verfügbar (kein Streak-Zwang mehr)
drop function if exists public.require_player(text);
create or replace function public.require_player(p_game text, p_stake bigint default null) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p public.profiles%rowtype;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into p from public.profiles where id = me for update;
  if p.is_admin and not p.is_test then
    raise exception 'Admins können nicht mitspielen. Nimm dafür das Test-Konto';
  end if;
  perform public.game_check(p_game, p.id, p_stake);
  return p;
end $$;

-- ===================== Bestehende Spiele erweitern (Spielprotokoll, Missionen, Tageslimits) =====================
-- Die vorhandenen Funktionen werden direkt in der Datenbank angepasst. Das ist wiederholbar: schon angepasste Stellen werden übersprungen.
create or replace function pg_temp.patch_fn(p_name text, p_old text, p_new text) returns void language plpgsql as $f$
declare def text; fid oid;
begin
  select p.oid into fid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = p_name;
  if fid is null then raise exception 'Funktion % nicht gefunden', p_name; end if;
  def := pg_get_functiondef(fid);
  if position(p_new in def) > 0 then return; end if;
  if position(p_old in def) = 0 then raise exception 'Stelle in % nicht gefunden: %', p_name, p_old; end if;
  execute replace(def, p_old, p_new);
end $f$;

select pg_temp.patch_fn('wheel_spin', $o$perform public.log_tx(p.id, net, 'game_wheel');$o$,
  $n$perform public.log_tx(p.id, net, 'game_wheel');
  perform public.record_round(p.id, 'wheel', s.wheel_stake, credit, jsonb_build_object('index', idx - 1));$n$);
select pg_temp.patch_fn('chest_open', $o$perform public.log_tx(me, -g.stake, 'game_chest');$o$,
  $n$perform public.log_tx(me, -g.stake, 'game_chest');
    perform public.record_round(me, 'chest', g.stake, 0, null);$n$);
select pg_temp.patch_fn('chest_cashout', $o$perform public.log_tx(me, net, 'game_chest');$o$,
  $n$perform public.log_tx(me, net, 'game_chest');
  perform public.record_round(me, 'chest', g.stake, credit, null);$n$);
select pg_temp.patch_fn('slot_spin', $o$p := public.require_player('slots');$o$, $n$p := public.require_player('slots', p_stake);$n$);
select pg_temp.patch_fn('slot_spin', $o$perform public.log_tx(p.id, net, 'game_slots');$o$,
  $n$perform public.log_tx(p.id, net, 'game_slots');
  perform public.record_round(p.id, 'slots', p_stake, credit, jsonb_build_object('reels', json_build_array(a - 1, b - 1, c - 1)));$n$);
select pg_temp.patch_fn('bj_settle', $o$perform public.log_tx(p.id, credit - g.stake, 'game_bj');$o$,
  $n$perform public.log_tx(p.id, credit - g.stake, 'game_bj');
  perform public.record_round(p.id, 'blackjack', g.stake, credit, jsonb_build_object('result', p_result));$n$);
select pg_temp.patch_fn('bj_start', $o$p := public.require_player('blackjack');$o$, $n$p := public.require_player('blackjack', p_stake);$n$);
select pg_temp.patch_fn('race_settle', $o$perform public.log_tx(p.id, credit - b.stake, 'game_race');$o$,
  $n$perform public.log_tx(p.id, credit - b.stake, 'game_race');
        perform public.record_round(p.id, 'race', b.stake, credit, jsonb_build_object('horse', b.horse));$n$);
select pg_temp.patch_fn('race_settle', $o$perform public.log_tx(p.id, -b.stake, 'game_race');$o$,
  $n$perform public.log_tx(p.id, -b.stake, 'game_race');
        perform public.record_round(p.id, 'race', b.stake, 0, jsonb_build_object('horse', b.horse));$n$);
select pg_temp.patch_fn('place_bet', $o$p := public.require_player('race');$o$, $n$p := public.require_player('race', p_stake);$n$);

-- ===================== Daily Streak: Coins statt Freischaltung =====================
create or replace function public.claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p public.profiles%rowtype;
        today date := (now() at time zone 'Europe/Zurich')::date; ns int; rewards jsonb; len int; reward int; credit bigint; nxt int;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into p from public.profiles where id = me for update;
  if p.last_claim = today then raise exception 'Heute schon abgeholt'; end if;
  if p.last_claim = today - 1 then ns := p.streak + 1; else ns := 1; end if;
  select value into rewards from public.app_config where key = 'streak_rewards';
  len := jsonb_array_length(rewards);
  reward := (rewards->((ns - 1) % len))::text::int;
  nxt := (rewards->((ns) % len))::text::int;
  credit := public.payout_cap(p.is_test, reward);
  update public.profiles set streak = ns, last_claim = today, balance = balance + credit where id = me;
  perform public.log_tx(me, credit, 'reward');
  perform public.stat_add(me, credit, 0);
  return json_build_object('streak', ns, 'reward', credit, 'next_reward', nxt);
end $$;

-- ===================== Rettungsnetz =====================
create table if not exists public.rescue_log (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  amount int not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table public.rescue_log enable row level security;
revoke all on public.rescue_log from anon, authenticated;

-- Wer unter dem Mindestguthaben liegt, bekommt höchstens einmal pro Tag Coins aus der Bank
create or replace function public.run_rescue(p_force boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; thr int; amt int; hr int; today date := (now() at time zone 'Europe/Zurich')::date;
        r record; give bigint; paid int := 0;
begin
  select value into cfg from public.app_config where key = 'rescue';
  if not coalesce((cfg->>'enabled')::boolean, false) then return 0; end if;
  thr := (cfg->>'threshold')::int; amt := (cfg->>'amount')::int; hr := (cfg->>'hour')::int;
  if not p_force and extract(hour from (now() at time zone 'Europe/Zurich')) < hr then return 0; end if;
  perform 1 from public.game_settings where id = 1 for update;
  for r in select id from public.profiles p
           where not p.is_admin and not p.is_test and p.balance < thr
             and not exists (select 1 from public.rescue_log l where l.user_id = p.id and l.day = today)
           order by p.balance, p.created_at loop
    give := least(amt, public.bank_balance());
    exit when give < 1;
    update public.profiles set balance = balance + give where id = r.id;
    insert into public.rescue_log (user_id, day, amount) values (r.id, today, give);
    perform public.log_tx(r.id, give, 'rescue');
    paid := paid + 1;
  end loop;
  return paid;
end $$;

-- Tagesschnappschuss der Coin-Wirtschaft
create or replace function public.snapshot_economy() returns void
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Europe/Zurich')::date; circ bigint; pl int; rc int; st bigint; pd bigint;
begin
  select coalesce(sum(balance), 0), count(*) into circ, pl from public.profiles where not is_admin and not is_test;
  select count(*), coalesce(sum(stake), 0), coalesce(sum(payout), 0) into rc, st, pd from public.game_rounds where day = today;
  insert into public.economy_snapshots (day, bank, circulation, players, rounds, staked, paid)
    values (today, public.bank_balance(), circ, pl, rc, st, pd)
  on conflict (day) do update set bank = excluded.bank, circulation = excluded.circulation, players = excluded.players,
    rounds = excluded.rounds, staked = excluded.staked, paid = excluded.paid, created_at = now();
end $$;

-- ===================== Rechte =====================
revoke all on function public.mission_progress(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.stat_add(uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.record_round(uuid, text, bigint, bigint, jsonb) from public, anon, authenticated;
revoke all on function public.game_check(text, uuid, bigint) from public, anon, authenticated;
revoke all on function public.require_player(text, bigint) from public, anon, authenticated;
revoke all on function public.run_rescue(boolean) from public, anon, authenticated;
revoke all on function public.snapshot_economy() from public, anon, authenticated;
