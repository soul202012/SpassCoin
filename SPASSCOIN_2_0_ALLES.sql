-- SpassCoin 2.0: ALLES IN EINER DATEI. Im Supabase SQL Editor einfügen und auf Run klicken.
-- Läuft in einer einzigen Transaktion: Wenn etwas schiefgeht, wird nichts geändert.
-- Kann gefahrlos mehrmals ausgeführt werden.

begin;

-- ===================================================================
-- 20261105000001_core_economy.sql
-- ===================================================================
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


-- ===================================================================
-- 20261105000002_new_games.sql
-- ===================================================================
-- SpassCoin 2.0, Teil 2: Plinko, Rubbellose, Higher or Lower, Video Poker (alles serverseitig)

create or replace function public.round_payout(p_value numeric) returns bigint
language sql volatile set search_path = public as $$
  select floor(p_value)::bigint + case when random() < (p_value - floor(p_value)) then 1 else 0 end
$$;

create or replace function public.shuffled_deck() returns int[]
language sql volatile set search_path = public as $$
  select array_agg(x order by random()) from generate_series(0, 51) x
$$;

-- Kartenwert fuer Higher or Lower: 2 bis 14, Ass ist 14. Karten: 0..51, Rang = Karte % 13 (0 = Ass)
create or replace function public.card_value(c int) returns int
language sql immutable set search_path = public as $$
  select case when c % 13 = 0 then 14 else c % 13 + 1 end
$$;

-- Oeffentliche Spiel-Konfiguration (ohne Wahrscheinlichkeiten, ohne Rettungsnetz)
create or replace function public.get_public_config() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  return jsonb_build_object(
    'streak_rewards', (select value from public.app_config where key = 'streak_rewards'),
    'plinko', (select value from public.app_config where key = 'plinko'),
    'scratch', (select jsonb_set(value, '{tiers}',
                  (select coalesce(jsonb_agg(t - 'p' order by ord), '[]'::jsonb) from jsonb_array_elements(value->'tiers') with ordinality as x(t, ord)))
                from public.app_config where key = 'scratch'),
    'hilo', (select value from public.app_config where key = 'hilo'),
    'poker', (select value from public.app_config where key = 'poker'),
    'toggles', (select coalesce(jsonb_object_agg(game, jsonb_build_object('enabled', enabled, 'min_stake', min_stake,
                  'max_stake', max_stake, 'daily_limit', daily_round_limit)), '{}'::jsonb) from public.game_toggles)
  );
end $$;

-- ===================== Plinko =====================
create or replace function public.plinko_drop(p_stake int, p_risk text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; cfg jsonb; n_rows int; arr jsonb;
        k int := 0; pth int[] := '{}'; i int; d int; m numeric; payout bigint; credit bigint; net bigint; neu bigint;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('plinko', p_stake);
  if p_stake is null or p_stake < 1 then raise exception 'Ungültiger Einsatz'; end if;
  if p_stake > p.balance then raise exception 'Nicht genug Coins'; end if;
  select value into cfg from public.app_config where key = 'plinko';
  n_rows := (cfg->>'rows')::int;
  arr := cfg->'levels'->p_risk;
  if arr is null or jsonb_typeof(arr) <> 'array' then raise exception 'Ungültige Risikostufe'; end if;
  for i in 1..n_rows loop
    d := case when random() < 0.5 then 1 else 0 end;
    k := k + d;
    pth := pth || d;
  end loop;
  m := (arr->>k)::numeric;
  payout := public.round_payout(p_stake * m);
  update public.profiles set balance = balance - p_stake where id = p.id;
  credit := public.payout_cap(p.is_test, payout);
  update public.profiles set balance = balance + credit where id = p.id returning balance into neu;
  net := credit - p_stake;
  perform public.log_tx(p.id, net, 'game_plinko');
  perform public.record_round(p.id, 'plinko', p_stake, credit, jsonb_build_object('risk', p_risk, 'slot', k));
  return jsonb_build_object('path', to_jsonb(pth), 'slot', k, 'mult', m, 'payout', credit, 'stake', p_stake,
                            'net', net, 'balance', neu, 'rows', n_rows);
end $$;

-- ===================== Rubbellose =====================
create table if not exists public.scratch_cards (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  stake int not null,
  cells text[] not null,
  matches int not null,
  symbol text,
  payout int not null,
  created_at timestamptz not null default now()
);
alter table public.scratch_cards enable row level security;
revoke all on public.scratch_cards from anon, authenticated;

-- Das Los wird beim Kauf komplett festgelegt und sofort ausgezahlt. Das Freirubbeln ist nur die Anzeige.
create or replace function public.scratch_buy(p_stake int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; cfg jsonb; n int; pool text[]; tiers jsonb;
        tot numeric; r numeric; acc numeric := 0; i int; tier jsonb; m int; mult numeric; win text; others text[]; cells text[];
        payout bigint; credit bigint; net bigint; neu bigint; cid bigint;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('scratch', p_stake);
  if p_stake is null or p_stake < 1 then raise exception 'Ungültiger Einsatz'; end if;
  if p_stake > p.balance then raise exception 'Nicht genug Coins'; end if;
  select value into cfg from public.app_config where key = 'scratch';
  n := (cfg->>'cells')::int;
  select array_agg(e->>'id' order by ord) into pool from jsonb_array_elements(cfg->'symbols') with ordinality as t(e, ord);
  if array_length(pool, 1) < n then raise exception 'Rubbellos ist falsch eingestellt (zu wenige Symbole)'; end if;
  tiers := cfg->'tiers';
  select sum((t->>'p')::numeric) into tot from jsonb_array_elements(tiers) t;
  r := random() * tot;
  for i in 0..jsonb_array_length(tiers) - 1 loop
    acc := acc + (tiers->i->>'p')::numeric;
    if r < acc then tier := tiers->i; exit; end if;
  end loop;
  if tier is null then tier := tiers->(jsonb_array_length(tiers) - 1); end if;
  m := (tier->>'matches')::int; mult := (tier->>'mult')::numeric;
  if m > n then raise exception 'Rubbellos ist falsch eingestellt (zu viele gleiche Symbole)'; end if;
  if m = 0 then
    select array_agg(x) into cells from (select x from unnest(pool) x order by random() limit n) q;
    win := null;
  else
    select x into win from unnest(pool) x order by random() limit 1;
    select array_agg(x) into others from (select x from unnest(pool) x where x <> win order by random() limit (n - m)) q;
    if coalesce(array_length(others, 1), 0) < n - m then raise exception 'Rubbellos ist falsch eingestellt (zu wenige Symbole)'; end if;
    select array_agg(x order by random()) into cells from unnest(array_fill(win, array[m]) || coalesce(others, '{}'::text[])) x;
  end if;
  payout := public.round_payout(p_stake * mult);
  update public.profiles set balance = balance - p_stake where id = p.id;
  credit := public.payout_cap(p.is_test, payout);
  update public.profiles set balance = balance + credit where id = p.id returning balance into neu;
  net := credit - p_stake;
  insert into public.scratch_cards (user_id, stake, cells, matches, symbol, payout)
    values (p.id, p_stake, cells, m, win, credit) returning id into cid;
  perform public.log_tx(p.id, net, 'game_scratch');
  perform public.record_round(p.id, 'scratch', p_stake, credit, jsonb_build_object('matches', m));
  return jsonb_build_object('id', cid, 'cells', to_jsonb(cells), 'matches', m, 'symbol', win, 'mult', mult,
                            'payout', credit, 'stake', p_stake, 'net', net, 'balance', neu);
end $$;

-- ===================== Higher or Lower =====================
create table if not exists public.hilo_games (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  stake int not null,
  card int not null,
  streak int not null default 0,
  status text not null default 'active' check (status in ('active', 'done')),
  created_at timestamptz not null default now()
);
alter table public.hilo_games enable row level security;
revoke all on public.hilo_games from anon, authenticated;

create or replace function public.hilo_view(g public.hilo_games) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', g.id, 'stake', g.stake, 'card', g.card, 'streak', g.streak, 'status', g.status,
    'ladder', (select value->'ladder' from public.app_config where key = 'hilo'))
$$;

create or replace function public.hilo_current() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g public.hilo_games%rowtype;
begin
  select * into g from public.hilo_games where user_id = auth.uid() and status = 'active' order by id desc limit 1;
  if not found then return null; end if;
  return public.hilo_view(g);
end $$;

create or replace function public.hilo_start(p_stake int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; g public.hilo_games%rowtype; neu bigint;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('hilo', p_stake);
  if exists (select 1 from public.hilo_games where user_id = p.id and status = 'active') then
    raise exception 'Du hast noch ein offenes Spiel';
  end if;
  if p_stake is null or p_stake < 1 then raise exception 'Ungültiger Einsatz'; end if;
  if p_stake > p.balance then raise exception 'Nicht genug Coins'; end if;
  update public.profiles set balance = balance - p_stake where id = p.id returning balance into neu;
  insert into public.hilo_games (user_id, stake, card) values (p.id, p_stake, floor(random() * 52)::int) returning * into g;
  return public.hilo_view(g) || jsonb_build_object('balance', neu);
end $$;

-- Interne Auszahlung (Aussteigen oder oberste Stufe erreicht)
create or replace function public.hilo_settle(p_game bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.hilo_games%rowtype; p public.profiles%rowtype; ladder jsonb; payout bigint; credit bigint; neu bigint;
begin
  select * into g from public.hilo_games where id = p_game for update;
  select * into p from public.profiles where id = g.user_id for update;
  select value->'ladder' into ladder from public.app_config where key = 'hilo';
  payout := public.round_payout(g.stake * (ladder->>(g.streak - 1))::numeric);
  credit := public.payout_cap(p.is_test, payout);
  update public.profiles set balance = balance + credit where id = p.id returning balance into neu;
  update public.hilo_games set status = 'done' where id = g.id;
  g.status := 'done';
  perform public.log_tx(p.id, credit - g.stake, 'game_hilo');
  perform public.record_round(p.id, 'hilo', g.stake, credit, jsonb_build_object('streak', g.streak));
  return public.hilo_view(g) || jsonb_build_object('result', 'cashout', 'payout', credit, 'net', credit - g.stake, 'balance', neu);
end $$;

create or replace function public.hilo_guess(p_game bigint, p_dir text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.hilo_games%rowtype; cfg jsonb; ladder jsonb; tie_rule text; nxt int; a int; b int; ok boolean; is_tie boolean; ns int;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if p_dir not in ('higher', 'lower') then raise exception 'Ungültige Wahl'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.hilo_games where id = p_game and user_id = auth.uid() and status = 'active' for update;
  if not found then raise exception 'Kein offenes Spiel'; end if;
  select value into cfg from public.app_config where key = 'hilo';
  ladder := cfg->'ladder'; tie_rule := cfg->>'tie';
  nxt := floor(random() * 52)::int;
  a := public.card_value(g.card); b := public.card_value(nxt);
  is_tie := (a = b);
  ok := (p_dir = 'higher' and b > a) or (p_dir = 'lower' and b < a);
  if is_tie and tie_rule = 'push' then
    update public.hilo_games set card = nxt where id = g.id;
    g.card := nxt;
    return public.hilo_view(g) || jsonb_build_object('result', 'tie', 'next', nxt);
  end if;
  if not ok then
    update public.hilo_games set status = 'done', card = nxt where id = g.id;
    g.status := 'done'; g.card := nxt;
    perform public.log_tx(g.user_id, -g.stake, 'game_hilo');
    perform public.record_round(g.user_id, 'hilo', g.stake, 0, jsonb_build_object('streak', g.streak));
    return public.hilo_view(g) || jsonb_build_object('result', 'lose', 'next', nxt, 'payout', 0, 'net', -g.stake);
  end if;
  ns := g.streak + 1;
  update public.hilo_games set card = nxt, streak = ns where id = g.id;
  g.card := nxt; g.streak := ns;
  if ns >= jsonb_array_length(ladder) then
    return public.hilo_settle(g.id) || jsonb_build_object('next', nxt);
  end if;
  return public.hilo_view(g) || jsonb_build_object('result', 'win', 'next', nxt);
end $$;

create or replace function public.hilo_cashout(p_game bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.hilo_games%rowtype;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.hilo_games where id = p_game and user_id = auth.uid() and status = 'active' for update;
  if not found then raise exception 'Kein offenes Spiel'; end if;
  if g.streak < 1 then raise exception 'Du brauchst mindestens eine richtige Antwort zum Aussteigen'; end if;
  return public.hilo_settle(g.id);
end $$;

-- ===================== Video Poker (Jacks or Better) =====================
create table if not exists public.poker_games (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  stake int not null,
  deck int[] not null,
  hand int[] not null,
  status text not null default 'dealt' check (status in ('dealt', 'done')),
  created_at timestamptz not null default now()
);
alter table public.poker_games enable row level security;
revoke all on public.poker_games from anon, authenticated;

create or replace function public.vp_eval(c int[]) returns text
language plpgsql immutable set search_path = public as $$
declare cnt int[] := array_fill(0, array[15]); v int; i int; flush boolean := true; straight boolean; pairs int := 0;
        three boolean := false; four boolean := false; hp boolean := false; mn int := 99; mx int := 0; dn int := 0; suit0 int;
begin
  suit0 := c[1] / 13;
  for i in 1..5 loop
    v := case when c[i] % 13 = 0 then 14 else c[i] % 13 + 1 end;
    cnt[v] := cnt[v] + 1;
    if c[i] / 13 <> suit0 then flush := false; end if;
  end loop;
  for v in 2..14 loop
    if cnt[v] > 0 then dn := dn + 1; mn := least(mn, v); mx := greatest(mx, v); end if;
    if cnt[v] = 4 then four := true;
    elsif cnt[v] = 3 then three := true;
    elsif cnt[v] = 2 then pairs := pairs + 1; if v >= 11 then hp := true; end if;
    end if;
  end loop;
  straight := (dn = 5 and mx - mn = 4) or (dn = 5 and cnt[14] = 1 and cnt[2] = 1 and cnt[3] = 1 and cnt[4] = 1 and cnt[5] = 1);
  if flush and straight and mn = 10 then return 'royal'; end if;
  if flush and straight then return 'straight_flush'; end if;
  if four then return 'four'; end if;
  if three and pairs = 1 then return 'full_house'; end if;
  if flush then return 'flush'; end if;
  if straight then return 'straight'; end if;
  if three then return 'three'; end if;
  if pairs = 2 then return 'two_pair'; end if;
  if pairs = 1 and hp then return 'jacks'; end if;
  return 'none';
end $$;

create or replace function public.vp_current() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g public.poker_games%rowtype;
begin
  select * into g from public.poker_games where user_id = auth.uid() and status = 'dealt' order by id desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('id', g.id, 'stake', g.stake, 'hand', to_jsonb(g.hand));
end $$;

create or replace function public.vp_deal(p_stake int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; deck int[]; neu bigint; gid bigint;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('poker', p_stake);
  if exists (select 1 from public.poker_games where user_id = p.id and status = 'dealt') then
    raise exception 'Du hast noch ein offenes Spiel';
  end if;
  if p_stake is null or p_stake < 1 then raise exception 'Ungültiger Einsatz'; end if;
  if p_stake > p.balance then raise exception 'Nicht genug Coins'; end if;
  deck := public.shuffled_deck();
  update public.profiles set balance = balance - p_stake where id = p.id returning balance into neu;
  insert into public.poker_games (user_id, stake, deck, hand) values (p.id, p_stake, deck[6:52], deck[1:5]) returning id into gid;
  return jsonb_build_object('id', gid, 'stake', p_stake, 'hand', to_jsonb(deck[1:5]), 'balance', neu);
end $$;

create or replace function public.vp_draw(p_game bigint, p_hold boolean[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.poker_games%rowtype; p public.profiles%rowtype; nh int[] := '{}'; idx int := 1; i int; kind text; mult numeric;
        payout bigint; credit bigint; net bigint; neu bigint;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if p_hold is null or array_length(p_hold, 1) <> 5 then raise exception 'Ungültige Auswahl'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.poker_games where id = p_game and user_id = auth.uid() and status = 'dealt' for update;
  if not found then raise exception 'Kein offenes Spiel'; end if;
  select * into p from public.profiles where id = g.user_id for update;
  for i in 1..5 loop
    if coalesce(p_hold[i], false) then nh := nh || g.hand[i];
    else nh := nh || g.deck[idx]; idx := idx + 1; end if;
  end loop;
  kind := public.vp_eval(nh);
  select coalesce((value->'paytable'->>kind)::numeric, 0) into mult from public.app_config where key = 'poker';
  if kind = 'none' then mult := 0; end if;
  payout := public.round_payout(g.stake * mult);
  credit := public.payout_cap(p.is_test, payout);
  update public.profiles set balance = balance + credit where id = p.id returning balance into neu;
  update public.poker_games set status = 'done', hand = nh where id = g.id;
  net := credit - g.stake;
  perform public.log_tx(p.id, net, 'game_poker');
  perform public.record_round(p.id, 'poker', g.stake, credit, jsonb_build_object('hand', kind));
  return jsonb_build_object('hand', to_jsonb(nh), 'kind', kind, 'mult', mult, 'payout', credit, 'stake', g.stake, 'net', net, 'balance', neu);
end $$;

-- ===================== Rechte =====================
revoke all on function public.round_payout(numeric) from public, anon, authenticated;
revoke all on function public.shuffled_deck() from public, anon, authenticated;
revoke all on function public.card_value(int) from public, anon, authenticated;
revoke all on function public.hilo_view(public.hilo_games) from public, anon, authenticated;
revoke all on function public.hilo_settle(bigint) from public, anon, authenticated;
revoke all on function public.vp_eval(int[]) from public, anon, authenticated;
revoke all on function public.get_public_config() from public, anon;
revoke all on function public.plinko_drop(int, text) from public, anon;
revoke all on function public.scratch_buy(int) from public, anon;
revoke all on function public.hilo_current() from public, anon;
revoke all on function public.hilo_start(int) from public, anon;
revoke all on function public.hilo_guess(bigint, text) from public, anon;
revoke all on function public.hilo_cashout(bigint) from public, anon;
revoke all on function public.vp_current() from public, anon;
revoke all on function public.vp_deal(int) from public, anon;
revoke all on function public.vp_draw(bigint, boolean[]) from public, anon;
grant execute on function public.get_public_config() to authenticated;
grant execute on function public.plinko_drop(int, text) to authenticated;
grant execute on function public.scratch_buy(int) to authenticated;
grant execute on function public.hilo_current() to authenticated;
grant execute on function public.hilo_start(int) to authenticated;
grant execute on function public.hilo_guess(bigint, text) to authenticated;
grant execute on function public.hilo_cashout(bigint) to authenticated;
grant execute on function public.vp_current() to authenticated;
grant execute on function public.vp_deal(int) to authenticated;
grant execute on function public.vp_draw(bigint, boolean[]) to authenticated;


-- ===================================================================
-- 20261105000003_missions_profiles_shop.sql
-- ===================================================================
-- SpassCoin 2.0, Teil 3: Missionen, Ranglisten, Profile, Coin-Shop

-- ===================== Missionen =====================
create table if not exists public.mission_defs (
  id bigint generated always as identity primary key,
  key text unique not null,
  title text not null,
  descr text not null default '',
  kind text not null check (kind in ('rounds_any','rounds_game','wins_any','wins_game','win_streak_game','win_streak_any','distinct_games')),
  game text,
  target int not null check (target >= 1),
  reward int not null check (reward >= 0),
  difficulty text not null check (difficulty in ('easy','medium','hard')),
  active boolean not null default true
);
alter table public.mission_defs enable row level security;
revoke all on public.mission_defs from anon, authenticated;

create table if not exists public.player_missions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  mission_id bigint not null references public.mission_defs(id) on delete cascade,
  progress int not null default 0,
  completed boolean not null default false,
  claimed boolean not null default false,
  claimed_at timestamptz,
  primary key (user_id, day, mission_id)
);
create index if not exists player_missions_day_idx on public.player_missions (day);
alter table public.player_missions enable row level security;
revoke all on public.player_missions from anon, authenticated;

insert into public.mission_defs (key, title, descr, kind, game, target, reward, difficulty) values
 ('play3', 'Spiele drei Runden', 'Egal welches Spiel', 'rounds_any', null, 3, 2, 'easy'),
 ('plinko1', 'Spiele eine Runde Plinko', '', 'rounds_game', 'plinko', 1, 2, 'easy'),
 ('chest1', 'Spiele eine Runde Truhen', '', 'rounds_game', 'chest', 1, 2, 'easy'),
 ('scratch1', 'Rubble ein Los frei', '', 'rounds_game', 'scratch', 1, 2, 'easy'),
 ('race1', 'Spiele eine Runde Pferderennen', 'Zählt nach dem Rennen um 19:15 Uhr', 'rounds_game', 'race', 1, 2, 'easy'),
 ('wins2', 'Gewinne zwei Runden', 'Egal welches Spiel', 'wins_any', null, 2, 4, 'medium'),
 ('diff3', 'Spiele drei verschiedene Spiele', '', 'distinct_games', null, 3, 4, 'medium'),
 ('hilo_win', 'Gewinne eine Runde Higher or Lower', '', 'wins_game', 'hilo', 1, 4, 'medium'),
 ('poker_win', 'Gewinne eine Runde Video Poker', '', 'wins_game', 'poker', 1, 4, 'medium'),
 ('wheel_streak2', 'Gewinne zwei Runden hintereinander beim Glücksrad', '', 'win_streak_game', 'wheel', 2, 8, 'hard'),
 ('streak3', 'Erreiche eine Gewinnserie von 3 Runden', 'Drei Gewinne in Folge, egal wo', 'win_streak_any', null, 3, 10, 'hard'),
 ('play10', 'Spiele zehn Runden', '', 'rounds_any', null, 10, 8, 'hard')
on conflict (key) do nothing;

create or replace function public.mission_progress(p_user uuid, p_game text, p_win boolean) returns void
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Europe/Zurich')::date; r record; np int; ng int;
begin
  for r in select pm.mission_id, pm.progress, d.kind, d.game, d.target
           from public.player_missions pm join public.mission_defs d on d.id = pm.mission_id
           where pm.user_id = p_user and pm.day = today and not pm.completed loop
    np := r.progress;
    if r.kind = 'rounds_any' then np := np + 1;
    elsif r.kind = 'rounds_game' then if r.game = p_game then np := np + 1; end if;
    elsif r.kind = 'wins_any' then if p_win then np := np + 1; end if;
    elsif r.kind = 'wins_game' then if p_win and r.game = p_game then np := np + 1; end if;
    elsif r.kind = 'win_streak_game' then if r.game = p_game then np := case when p_win then np + 1 else 0 end; end if;
    elsif r.kind = 'win_streak_any' then np := case when p_win then np + 1 else 0 end;
    elsif r.kind = 'distinct_games' then
      select coalesce(cardinality(games), 0) into ng from public.player_day_games where user_id = p_user and day = today;
      np := coalesce(ng, 0);
    end if;
    if np <> r.progress then
      update public.player_missions set progress = np, completed = (np >= r.target)
        where user_id = p_user and day = today and mission_id = r.mission_id;
    end if;
  end loop;
end $$;

create or replace function public.my_missions() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'Europe/Zurich')::date; cfg jsonb; slot text; picked bigint;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform pg_advisory_xact_lock(hashtext('missions:' || me::text));
  if not exists (select 1 from public.player_missions where user_id = me and day = today) then
    select value into cfg from public.app_config where key = 'missions';
    for slot in select jsonb_array_elements_text(cfg->'slots') loop
      picked := null;
      select d.id into picked from public.mission_defs d
        where d.active and d.difficulty = slot
          and d.id not in (select mission_id from public.player_missions where user_id = me and day = today)
        order by random() limit 1;
      if picked is not null then
        insert into public.player_missions (user_id, day, mission_id) values (me, today, picked);
      end if;
    end loop;
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('mission_id', d.id, 'title', d.title, 'descr', d.descr,
            'kind', d.kind, 'game', d.game, 'target', d.target, 'reward', d.reward, 'difficulty', d.difficulty,
            'progress', least(pm.progress, d.target), 'completed', pm.completed, 'claimed', pm.claimed)
            order by case d.difficulty when 'easy' then 1 when 'medium' then 2 else 3 end, d.id), '[]'::jsonb)
          from public.player_missions pm join public.mission_defs d on d.id = pm.mission_id
          where pm.user_id = me and pm.day = today);
end $$;

create or replace function public.claim_mission(p_mission bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'Europe/Zurich')::date; pm public.player_missions%rowtype;
        d public.mission_defs%rowtype; p public.profiles%rowtype; credit bigint; neu bigint;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into pm from public.player_missions where user_id = me and day = today and mission_id = p_mission for update;
  if not found then raise exception 'Mission nicht gefunden'; end if;
  if pm.claimed then raise exception 'Belohnung schon abgeholt'; end if;
  if not pm.completed then raise exception 'Mission noch nicht geschafft'; end if;
  select * into d from public.mission_defs where id = p_mission;
  select * into p from public.profiles where id = me for update;
  credit := public.payout_cap(p.is_test, d.reward);
  if credit < d.reward then raise exception 'Die Bank hat gerade nicht genug Coins. Versuch es später nochmal.'; end if;
  update public.profiles set balance = balance + credit where id = me returning balance into neu;
  update public.player_missions set claimed = true, claimed_at = now() where user_id = me and day = today and mission_id = p_mission;
  perform public.log_tx(me, credit, 'mission');
  perform public.stat_add(me, credit, 0);
  return jsonb_build_object('reward', credit, 'balance', neu);
end $$;

-- ===================== Profile und Kosmetik =====================
alter table public.profiles add column if not exists username_changed_at timestamptz;

create table if not exists public.player_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  avatar text not null default 'avatar-01',
  frame text not null default 'frame-none',
  color text not null default 'color-gold',
  background text not null default 'bg-default',
  name_color text not null default 'name-default',
  rank_effect text not null default 'fx-none',
  updated_at timestamptz not null default now()
);
alter table public.player_profiles enable row level security;
revoke all on public.player_profiles from anon, authenticated;
insert into public.player_profiles (user_id) select id from public.profiles on conflict do nothing;

create or replace function public.ensure_player_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.player_profiles (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists profiles_after_insert on public.profiles;
create trigger profiles_after_insert after insert on public.profiles
  for each row execute function public.ensure_player_profile();

create table if not exists public.shop_items (
  id text primary key,
  category text not null check (category in ('avatar','frame','color','background','name_color','rank_effect')),
  name text not null,
  descr text not null default '',
  price int not null default 0 check (price >= 0),
  rarity text not null default 'common' check (rarity in ('common','rare','epic','legendary')),
  data jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  sort int not null default 0
);
alter table public.shop_items enable row level security;
revoke all on public.shop_items from anon, authenticated;

create table if not exists public.player_inventory (
  user_id uuid not null references public.profiles(id) on delete cascade,
  item_id text not null references public.shop_items(id) on delete cascade,
  price_paid int not null default 0,
  acquired_at timestamptz not null default now(),
  primary key (user_id, item_id)
);
alter table public.player_inventory enable row level security;
revoke all on public.player_inventory from anon, authenticated;

insert into public.shop_items (id, category, name, descr, price, rarity, data, active, sort) values
('avatar-01','avatar','Fuchs','Avatar Fuchs',0,'common','{"file": "assets/avatars/avatar-01.svg"}'::jsonb,true,0),
('avatar-02','avatar','Panda','Avatar Panda',0,'common','{"file": "assets/avatars/avatar-02.svg"}'::jsonb,true,1),
('avatar-03','avatar','Tiger','Avatar Tiger',0,'common','{"file": "assets/avatars/avatar-03.svg"}'::jsonb,true,2),
('avatar-04','avatar','Löwe','Avatar Löwe',0,'common','{"file": "assets/avatars/avatar-04.svg"}'::jsonb,true,3),
('avatar-05','avatar','Frosch','Avatar Frosch',0,'common','{"file": "assets/avatars/avatar-05.svg"}'::jsonb,true,4),
('avatar-06','avatar','Affe','Avatar Affe',0,'common','{"file": "assets/avatars/avatar-06.svg"}'::jsonb,true,5),
('avatar-07','avatar','Krake','Avatar Krake',0,'common','{"file": "assets/avatars/avatar-07.svg"}'::jsonb,true,6),
('avatar-08','avatar','Einhorn','Avatar Einhorn',0,'common','{"file": "assets/avatars/avatar-08.svg"}'::jsonb,true,7),
('avatar-09','avatar','Drache','Avatar Drache',75,'rare','{"file": "assets/avatars/avatar-09.svg"}'::jsonb,true,8),
('avatar-10','avatar','Roboter','Avatar Roboter',75,'rare','{"file": "assets/avatars/avatar-10.svg"}'::jsonb,true,9),
('avatar-11','avatar','Alien','Avatar Alien',75,'rare','{"file": "assets/avatars/avatar-11.svg"}'::jsonb,true,10),
('avatar-12','avatar','Geist','Avatar Geist',75,'rare','{"file": "assets/avatars/avatar-12.svg"}'::jsonb,true,11),
('avatar-13','avatar','Dino','Avatar Dino',75,'rare','{"file": "assets/avatars/avatar-13.svg"}'::jsonb,true,12),
('avatar-14','avatar','Pinguin','Avatar Pinguin',25,'common','{"file": "assets/avatars/avatar-14.svg"}'::jsonb,true,13),
('avatar-15','avatar','Koala','Avatar Koala',25,'common','{"file": "assets/avatars/avatar-15.svg"}'::jsonb,true,14),
('avatar-16','avatar','Hase','Avatar Hase',25,'common','{"file": "assets/avatars/avatar-16.svg"}'::jsonb,true,15),
('avatar-17','avatar','Eule','Avatar Eule',25,'common','{"file": "assets/avatars/avatar-17.svg"}'::jsonb,true,16),
('avatar-18','avatar','Biene','Avatar Biene',25,'common','{"file": "assets/avatars/avatar-18.svg"}'::jsonb,true,17),
('avatar-19','avatar','Schmetterling','Avatar Schmetterling',25,'common','{"file": "assets/avatars/avatar-19.svg"}'::jsonb,true,18),
('avatar-20','avatar','Schildkröte','Avatar Schildkröte',25,'common','{"file": "assets/avatars/avatar-20.svg"}'::jsonb,true,19),
('avatar-21','avatar','Zauberer','Avatar Zauberer',200,'epic','{"file": "assets/avatars/avatar-21.svg"}'::jsonb,true,20),
('avatar-22','avatar','Ninja','Avatar Ninja',200,'epic','{"file": "assets/avatars/avatar-22.svg"}'::jsonb,true,21),
('avatar-23','avatar','Vampir','Avatar Vampir',200,'epic','{"file": "assets/avatars/avatar-23.svg"}'::jsonb,true,22),
('avatar-24','avatar','Superheld','Avatar Superheld',200,'epic','{"file": "assets/avatars/avatar-24.svg"}'::jsonb,true,23),
('avatar-25','avatar','Dschinn','Avatar Dschinn',200,'epic','{"file": "assets/avatars/avatar-25.svg"}'::jsonb,true,24),
('avatar-26','avatar','Papagei','Avatar Papagei',75,'rare','{"file": "assets/avatars/avatar-26.svg"}'::jsonb,true,25),
('avatar-27','avatar','Astronaut','Avatar Astronaut',200,'epic','{"file": "assets/avatars/avatar-27.svg"}'::jsonb,true,26),
('avatar-28','avatar','Diamant','Avatar Diamant',500,'legendary','{"file": "assets/avatars/avatar-28.svg"}'::jsonb,true,27),
('avatar-29','avatar','König','Avatar König',500,'legendary','{"file": "assets/avatars/avatar-29.svg"}'::jsonb,true,28),
('avatar-30','avatar','Feuergeist','Avatar Feuergeist',500,'legendary','{"file": "assets/avatars/avatar-30.svg"}'::jsonb,true,29),
('frame-none','frame','Kein Rahmen','Ohne Rahmen',0,'common','{}'::jsonb,true,0),
('frame-simple','frame','Einfach','Profilrahmen Einfach',0,'common','{"file": "assets/frames/frame-simple.svg", "animated": false}'::jsonb,true,1),
('frame-bronze','frame','Bronze','Profilrahmen Bronze',40,'common','{"file": "assets/frames/frame-bronze.svg", "animated": false}'::jsonb,true,2),
('frame-silver','frame','Silber','Profilrahmen Silber',60,'common','{"file": "assets/frames/frame-silver.svg", "animated": false}'::jsonb,true,3),
('frame-gold','frame','Gold','Profilrahmen Gold',150,'rare','{"file": "assets/frames/frame-gold.svg", "animated": false}'::jsonb,true,4),
('frame-emerald','frame','Smaragd','Profilrahmen Smaragd',100,'rare','{"file": "assets/frames/frame-emerald.svg", "animated": false}'::jsonb,true,5),
('frame-ruby','frame','Rubin','Profilrahmen Rubin',100,'rare','{"file": "assets/frames/frame-ruby.svg", "animated": false}'::jsonb,true,6),
('frame-diamond','frame','Diamant','Profilrahmen Diamant',400,'epic','{"file": "assets/frames/frame-diamond.svg", "animated": false}'::jsonb,true,7),
('frame-rainbow','frame','Regenbogen','Profilrahmen Regenbogen (animiert)',500,'legendary','{"file": "assets/frames/frame-rainbow.svg", "animated": true}'::jsonb,true,8),
('frame-fire','frame','Feuer','Profilrahmen Feuer (animiert)',600,'legendary','{"file": "assets/frames/frame-fire.svg", "animated": true}'::jsonb,true,9),
('frame-neon','frame','Neon','Profilrahmen Neon (animiert)',350,'epic','{"file": "assets/frames/frame-neon.svg", "animated": true}'::jsonb,true,10),
('frame-winter','frame','Winter-Event','Profilrahmen Winter-Event (animiert)',300,'epic','{"file": "assets/frames/frame-winter.svg", "animated": true}'::jsonb,true,11),
('color-gold','color','Gold','Profilfarbe Gold',0,'common','{"css": "#d4af37", "animated": false}'::jsonb,true,0),
('color-violet','color','Violett','Profilfarbe Violett',0,'common','{"css": "#8b5cf6", "animated": false}'::jsonb,true,1),
('color-green','color','Grün','Profilfarbe Grün',0,'common','{"css": "#22c55e", "animated": false}'::jsonb,true,2),
('color-blue','color','Blau','Profilfarbe Blau',0,'common','{"css": "#3b82f6", "animated": false}'::jsonb,true,3),
('color-red','color','Rot','Profilfarbe Rot',0,'common','{"css": "#ef4444", "animated": false}'::jsonb,true,4),
('color-pink','color','Pink','Profilfarbe Pink',40,'common','{"css": "#ec4899", "animated": false}'::jsonb,true,5),
('color-orange','color','Orange','Profilfarbe Orange',40,'common','{"css": "#f97316", "animated": false}'::jsonb,true,6),
('color-teal','color','Türkis','Profilfarbe Türkis',40,'common','{"css": "#14b8a6", "animated": false}'::jsonb,true,7),
('color-cyan','color','Cyan','Profilfarbe Cyan',60,'rare','{"css": "#06b6d4", "animated": false}'::jsonb,true,8),
('color-lime','color','Limette','Profilfarbe Limette',60,'rare','{"css": "#84cc16", "animated": false}'::jsonb,true,9),
('color-rose','color','Rosa','Profilfarbe Rosa',60,'rare','{"css": "#fb7185", "animated": false}'::jsonb,true,10),
('color-sunset','color','Sonnenuntergang','Profilfarbe Sonnenuntergang',150,'rare','{"css": "linear-gradient(135deg,#ff9a3c,#ff3c8e)", "animated": false}'::jsonb,true,11),
('color-ocean','color','Ozean','Profilfarbe Ozean',150,'rare','{"css": "linear-gradient(135deg,#00c6ff,#0072ff)", "animated": false}'::jsonb,true,12),
('color-aurora','color','Polarlicht','Profilfarbe Polarlicht',250,'epic','{"css": "linear-gradient(135deg,#43e97b,#38f9d7,#8b5cf6)", "animated": false}'::jsonb,true,13),
('color-neon','color','Neon','Profilfarbe Neon',300,'epic','{"css": "linear-gradient(135deg,#ff00e5,#00f5ff)", "animated": false}'::jsonb,true,14),
('color-rainbow-shift','color','Regenbogen (animiert)','Profilfarbe Regenbogen (animiert)',500,'legendary','{"css": "linear-gradient(90deg,#ff0000,#ff9900,#ffee00,#22c55e,#3b82f6,#8b5cf6,#ff0000)", "animated": true}'::jsonb,true,15),
('bg-default','background','Standard','Hintergrund Standard',0,'common','{"css": "var(--card)"}'::jsonb,true,0),
('bg-midnight','background','Mitternacht','Hintergrund Mitternacht',30,'common','{"css": "linear-gradient(160deg,#0b1026,#1b2559)"}'::jsonb,true,1),
('bg-casino','background','Casino-Grün','Hintergrund Casino-Grün',60,'common','{"css": "radial-gradient(circle at 30% 20%,#14532d,#052e16)"}'::jsonb,true,2),
('bg-sunset','background','Abendrot','Hintergrund Abendrot',80,'rare','{"css": "linear-gradient(160deg,#42275a,#734b6d,#ff7e5f)"}'::jsonb,true,3),
('bg-stars','background','Sternenhimmel','Hintergrund Sternenhimmel',120,'rare','{"css": "radial-gradient(2px 2px at 20px 30px,#fff,transparent),radial-gradient(1px 1px at 80px 60px,#fff,transparent),radial-gradient(1.5px 1.5px at 50px 100px,#fff,transparent),#0a0a1a", "size": "120px 120px"}'::jsonb,true,4),
('bg-aurora','background','Polarnacht','Hintergrund Polarnacht',200,'epic','{"css": "linear-gradient(120deg,#0f2027,#2c5364 55%,#1d8f5f)"}'::jsonb,true,5),
('bg-glow','background','Goldglanz','Hintergrund Goldglanz',250,'epic','{"css": "radial-gradient(circle at 50% 0%,#d4af3755,#0a0a0a 70%)"}'::jsonb,true,6),
('bg-matrix','background','Matrix','Hintergrund Matrix',300,'epic','{"css": "repeating-linear-gradient(180deg,#001a00 0 6px,#00330a 6px 12px)"}'::jsonb,true,7),
('name-default','name_color','Standard','Namensfarbe Standard',0,'common','{"css": "inherit", "animated": false}'::jsonb,true,0),
('name-gold','name_color','Gold','Namensfarbe Gold',50,'common','{"css": "#d4af37", "animated": false}'::jsonb,true,1),
('name-cyan','name_color','Cyan','Namensfarbe Cyan',50,'common','{"css": "#22d3ee", "animated": false}'::jsonb,true,2),
('name-pink','name_color','Pink','Namensfarbe Pink',50,'common','{"css": "#f472b6", "animated": false}'::jsonb,true,3),
('name-lime','name_color','Limette','Namensfarbe Limette',50,'common','{"css": "#a3e635", "animated": false}'::jsonb,true,4),
('name-rainbow','name_color','Regenbogen','Namensfarbe Regenbogen',300,'epic','{"css": "linear-gradient(90deg,#ff0000,#ff9900,#ffee00,#22c55e,#3b82f6,#8b5cf6,#ff0000)", "animated": true}'::jsonb,true,5),
('name-fire','name_color','Feuer','Namensfarbe Feuer',400,'legendary','{"css": "linear-gradient(90deg,#ff4500,#ffb300,#ff0000,#ff4500)", "animated": true}'::jsonb,true,6),
('fx-none','rank_effect','Kein Effekt','Ranglisten-Effekt Kein Effekt',0,'common','{"class": ""}'::jsonb,true,0),
('fx-glow','rank_effect','Leuchten','Ranglisten-Effekt Leuchten',100,'rare','{"class": "fx-glow"}'::jsonb,true,1),
('fx-sparkle','rank_effect','Funkeln','Ranglisten-Effekt Funkeln',200,'epic','{"class": "fx-sparkle"}'::jsonb,true,2),
('fx-crown','rank_effect','Krone','Ranglisten-Effekt Krone',400,'legendary','{"class": "fx-crown"}'::jsonb,true,3)
on conflict (id) do nothing;

create or replace function public.owns_item(p_user uuid, p_item text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.shop_items i where i.id = p_item and i.price = 0)
      or exists (select 1 from public.player_inventory v where v.user_id = p_user and v.item_id = p_item)
$$;

-- Shop: alle Artikel mit Besitz-Status und aktueller Auswahl
create or replace function public.shop_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); pp public.player_profiles%rowtype;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into pp from public.player_profiles where user_id = me;
  return jsonb_build_object(
    'equipped', jsonb_build_object('avatar', pp.avatar, 'frame', pp.frame, 'color', pp.color, 'background', pp.background,
                                   'name_color', pp.name_color, 'rank_effect', pp.rank_effect),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'category', i.category, 'name', i.name, 'descr', i.descr,
                'price', i.price, 'rarity', i.rarity, 'data', i.data,
                'owned', (i.price = 0 or exists (select 1 from public.player_inventory v where v.user_id = me and v.item_id = i.id)))
                order by i.category, i.price, i.sort), '[]'::jsonb)
              from public.shop_items i where i.active));
end $$;

create or replace function public.buy_item(p_item text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); it public.shop_items%rowtype; p public.profiles%rowtype; neu bigint;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into it from public.shop_items where id = p_item and active;
  if not found then raise exception 'Artikel nicht gefunden'; end if;
  select * into p from public.profiles where id = me for update;
  if it.price = 0 or exists (select 1 from public.player_inventory where user_id = me and item_id = p_item) then
    raise exception 'Das gehört dir schon';
  end if;
  if p.balance < it.price then raise exception 'Nicht genug Coins'; end if;
  update public.profiles set balance = balance - it.price where id = me returning balance into neu;
  insert into public.player_inventory (user_id, item_id, price_paid) values (me, p_item, it.price);
  perform public.log_tx(me, -it.price, 'shop');
  perform public.stat_add(me, 0, it.price);
  return jsonb_build_object('balance', neu, 'item', p_item);
end $$;

create or replace function public.check_item(p_user uuid, p_item text, p_cat text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.shop_items where id = p_item and category = p_cat) then
    raise exception 'Unbekannter Artikel';
  end if;
  if not public.owns_item(p_user, p_item) then raise exception 'Das hast du noch nicht freigeschaltet'; end if;
end $$;

create or replace function public.update_profile(p_avatar text default null, p_frame text default null, p_color text default null,
  p_background text default null, p_name_color text default null, p_rank_effect text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  if p_avatar is not null then perform public.check_item(me, p_avatar, 'avatar'); end if;
  if p_frame is not null then perform public.check_item(me, p_frame, 'frame'); end if;
  if p_color is not null then perform public.check_item(me, p_color, 'color'); end if;
  if p_background is not null then perform public.check_item(me, p_background, 'background'); end if;
  if p_name_color is not null then perform public.check_item(me, p_name_color, 'name_color'); end if;
  if p_rank_effect is not null then perform public.check_item(me, p_rank_effect, 'rank_effect'); end if;
  update public.player_profiles set
    avatar = coalesce(p_avatar, avatar), frame = coalesce(p_frame, frame), color = coalesce(p_color, color),
    background = coalesce(p_background, background), name_color = coalesce(p_name_color, name_color),
    rank_effect = coalesce(p_rank_effect, rank_effect), updated_at = now()
  where user_id = me;
end $$;

create or replace function public.change_username(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); nm text := lower(trim(coalesce(p_name, ''))); last_change timestamptz;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  if nm !~ '^[a-z0-9_.-]{3,20}$' then raise exception 'Der Benutzername braucht 3 bis 20 Zeichen (Buchstaben, Zahlen, _ . -)'; end if;
  select username_changed_at into last_change from public.profiles where id = me;
  if last_change is not null and last_change > now() - interval '7 days' then
    raise exception 'Du kannst den Namen nur einmal pro Woche ändern';
  end if;
  if exists (select 1 from public.profiles where lower(username) = nm and id <> me) then
    raise exception 'Dieser Benutzername ist schon vergeben';
  end if;
  begin
    update public.profiles set username = nm, username_changed_at = now() where id = me;
  exception when unique_violation then
    raise exception 'Dieser Benutzername ist schon vergeben';
  end;
  return nm;
end $$;

-- Oeffentliche Profilseite (nur Benutzername, Kosmetik, Code und Statistik, nie die E-Mail)
create or replace function public.get_profile(p_username text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); pr public.profiles%rowtype; pp public.player_profiles%rowtype; st public.player_stats%rowtype; rk int; normal boolean;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into pr from public.profiles where lower(username) = lower(p_username);
  if not found then raise exception 'Spieler nicht gefunden'; end if;
  select * into pp from public.player_profiles where user_id = pr.id;
  select * into st from public.player_stats where user_id = pr.id;
  normal := not pr.is_admin and not pr.is_test;
  if normal then
    select 1 + count(*) into rk from public.profiles x where not x.is_admin and not x.is_test and x.balance > pr.balance;
  end if;
  return jsonb_build_object('username', pr.username, 'code', pr.code, 'joined', pr.created_at, 'is_me', pr.id = me,
    'avatar', pp.avatar, 'frame', pp.frame, 'color', pp.color, 'background', pp.background,
    'name_color', pp.name_color, 'rank_effect', pp.rank_effect, 'rank', case when normal then rk else null end,
    'rounds', coalesce(st.rounds, 0), 'wins', coalesce(st.wins, 0), 'losses', coalesce(st.losses, 0),
    'earned', coalesce(st.earned, 0), 'spent', coalesce(st.spent, 0), 'net', coalesce(st.earned, 0) - coalesce(st.spent, 0));
end $$;

-- Kontoverlauf: Kontostand am Ende jedes Tages (rueckwaerts aus dem heutigen Stand und den Buchungen berechnet)
create or replace function public.balance_history(p_username text, p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u uuid; cur bigint; today date := (now() at time zone 'Europe/Zurich')::date; first_day date; start_day date;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  select id, balance into u, cur from public.profiles where lower(username) = lower(p_username);
  if u is null then raise exception 'Spieler nicht gefunden'; end if;
  select min((created_at at time zone 'Europe/Zurich')::date) into first_day
    from public.transactions where receiver_id = u or sender_id = u;
  start_day := case when p_days > 0 then today - (p_days - 1) else least(coalesce(first_day, today), today) end;
  if p_days = 0 and start_day < today - 364 then start_day := today - 364; end if;
  return (
    with ev as (
      select (created_at at time zone 'Europe/Zurich')::date d,
             sum(case when receiver_id = u then amount else -amount end) s
      from public.transactions where receiver_id = u or sender_id = u group by 1
    ), days as (
      select generate_series(start_day, today, interval '1 day')::date d
    )
    select coalesce(jsonb_agg(jsonb_build_object('day', days.d,
             'balance', cur - coalesce((select sum(s) from ev where ev.d > days.d), 0),
             'delta', coalesce((select s from ev where ev.d = days.d), 0)) order by days.d), '[]'::jsonb)
    from days
  );
end $$;

-- ===================== Ranglisten =====================
create or replace function public.leaderboard_v2(p_period text, p_cat text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'Europe/Zurich')::date; start_day date; ts timestamptz;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  if p_period not in ('day', 'week', 'all') or p_cat not in ('net', 'wins', 'activity') then raise exception 'Ungültige Auswahl'; end if;
  start_day := case p_period when 'day' then today when 'week' then date_trunc('week', today::timestamp)::date else null end;
  ts := case when start_day is null then null else (start_day::timestamp at time zone 'Europe/Zurich') end;
  return (
    with vals as (
      select p.id uid, p.username,
        (case p_cat
           when 'net' then case when p_period = 'all' then coalesce(ps.earned - ps.spent, 0) else coalesce(g.net, 0) + coalesce(t.net, 0) end
           when 'wins' then case when p_period = 'all' then coalesce(ps.wins, 0) else coalesce(g.wins, 0) end
           else case when p_period = 'all' then coalesce(ps.rounds, 0) else coalesce(g.rounds, 0) end
         end)::bigint v
      from public.profiles p
      left join public.player_stats ps on ps.user_id = p.id
      left join (select user_id, sum(net) net, count(*) filter (where win) wins, count(*) rounds
                 from public.game_rounds where p_period <> 'all' and created_at >= ts group by user_id) g on g.user_id = p.id
      left join (select coalesce(receiver_id, sender_id) uid2,
                        sum(case when receiver_id is not null then amount else -amount end) net
                 from public.transactions
                 where p_period <> 'all' and created_at >= ts and kind in ('reward', 'mission', 'shop') group by 1) t on t.uid2 = p.id
      where not p.is_admin and not p.is_test
    ), ranked as (
      select uid, username, v, rank() over (order by v desc) rk from vals where (p_cat = 'net' and v <> 0) or v > 0
    )
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('rank', r.rk, 'username', r.username, 'value', r.v,
                'avatar', pp.avatar, 'frame', pp.frame, 'color', pp.color, 'name_color', pp.name_color,
                'rank_effect', pp.rank_effect, 'me', r.uid = me) order by r.rk, r.username)
              from (select * from ranked order by rk, username limit 50) r
              left join public.player_profiles pp on pp.user_id = r.uid), '[]'::jsonb),
      'me', (select jsonb_build_object('rank', rk, 'value', v) from ranked where uid = me)
    )
  );
end $$;

-- ===================== Rechte =====================
revoke all on function public.owns_item(uuid, text) from public, anon, authenticated;
revoke all on function public.check_item(uuid, text, text) from public, anon, authenticated;
revoke all on function public.ensure_player_profile() from public, anon, authenticated;
revoke all on function public.my_missions() from public, anon;
revoke all on function public.claim_mission(bigint) from public, anon;
revoke all on function public.shop_list() from public, anon;
revoke all on function public.buy_item(text) from public, anon;
revoke all on function public.update_profile(text, text, text, text, text, text) from public, anon;
revoke all on function public.change_username(text) from public, anon;
revoke all on function public.get_profile(text) from public, anon;
revoke all on function public.balance_history(text, int) from public, anon;
revoke all on function public.leaderboard_v2(text, text) from public, anon;
grant execute on function public.my_missions() to authenticated;
grant execute on function public.claim_mission(bigint) to authenticated;
grant execute on function public.shop_list() to authenticated;
grant execute on function public.buy_item(text) to authenticated;
grant execute on function public.update_profile(text, text, text, text, text, text) to authenticated;
grant execute on function public.change_username(text) to authenticated;
grant execute on function public.get_profile(text) to authenticated;
grant execute on function public.balance_history(text, int) to authenticated;
grant execute on function public.leaderboard_v2(text, text) to authenticated;


-- ===================================================================
-- 20261105000004_stock_market.sql
-- ===================================================================
-- SpassCoin 2.0, Teil 4: SpassCoin-Boerse (nur erfundene Aktien, nur Coins)

create table if not exists public.stock_companies (
  id bigint generated always as identity primary key,
  symbol text unique not null,
  name text not null,
  descr text not null default '',
  risk text not null default 'medium' check (risk in ('low', 'medium', 'high')),
  price numeric(12, 2) not null check (price >= 0.5),
  start_price numeric(12, 2) not null check (start_price >= 0.5),
  volatility numeric not null default 0.008 check (volatility >= 0 and volatility <= 0.2),
  drift numeric not null default 0 check (drift >= -0.05 and drift <= 0.05),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.stock_prices (
  company_id bigint not null references public.stock_companies(id) on delete cascade,
  ts timestamptz not null default now(),
  price numeric(12, 2) not null,
  primary key (company_id, ts)
);
create table if not exists public.stock_holdings (
  user_id uuid not null references public.profiles(id) on delete cascade,
  company_id bigint not null references public.stock_companies(id) on delete cascade,
  shares bigint not null check (shares >= 0),
  cost bigint not null check (cost >= 0),
  primary key (user_id, company_id)
);
create table if not exists public.stock_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  company_id bigint references public.stock_companies(id) on delete set null,
  symbol text not null,
  side text not null check (side in ('buy', 'sell')),
  shares bigint not null,
  price numeric(12, 2) not null,
  total bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists stock_tx_user_idx on public.stock_transactions (user_id, created_at desc);
create table if not exists public.stock_state (
  id int primary key default 1 check (id = 1),
  last_tick timestamptz not null default now()
);
insert into public.stock_state (id) values (1) on conflict do nothing;

alter table public.stock_companies enable row level security;
alter table public.stock_prices enable row level security;
alter table public.stock_holdings enable row level security;
alter table public.stock_transactions enable row level security;
alter table public.stock_state enable row level security;
revoke all on public.stock_companies, public.stock_prices, public.stock_holdings, public.stock_transactions, public.stock_state from anon, authenticated;

insert into public.app_config (key, value) values ('stocks', '{"interval_sec":300,"paused":false}') on conflict (key) do nothing;

insert into public.stock_companies (symbol, name, descr, risk, price, start_price, volatility) values
 ('CTC', 'CoinTech', 'Technik rund um digitale Coins. Wilde Kurse, grosse Chancen und grosse Risiken.', 'high', 25, 25, 0.014),
 ('SPE', 'SpassEnergy', 'Strom fuer alle SpassCoin-Fans. Ruhig und stabil.', 'low', 12, 12, 0.004),
 ('LKM', 'Lucky Motors', 'Schnelle Autos, mittlere Schwankungen.', 'medium', 18, 18, 0.008),
 ('PXI', 'Pixel Industries', 'Spiele und Grafik, springt gern mal.', 'high', 8, 8, 0.011),
 ('HPW', 'HorsePower AG', 'Pferdestaerken und Rennstall, eher ruhig.', 'low', 15, 15, 0.006)
on conflict (symbol) do nothing;
insert into public.stock_prices (company_id, ts, price) select id, now(), price from public.stock_companies on conflict do nothing;

-- Die Bank zaehlt investierte Coins nicht mehr als "frei": Bank + Konten + investierte Coins = Gesamtmenge
create or replace function public.bank_balance() returns bigint
language sql security definer set search_path = public stable as $$
  select greatest(0, (select total_coins from public.game_settings where id = 1)
         - coalesce((select sum(balance) from public.profiles where not is_admin and not is_test), 0)
         - coalesce((select sum(h.cost) from public.stock_holdings h join public.profiles p on p.id = h.user_id
                     where not p.is_admin and not p.is_test), 0))::bigint
$$;

-- Kurse weiterrechnen: zufaellige Schritte mit leichter Rueckkehr zum Startkurs, serverseitig und fuer alle gleich
create or replace function public.stock_tick(p_force boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; ivl int; lt timestamptz; steps int; i int; c record; z double precision; np numeric; paused boolean;
begin
  select value into cfg from public.app_config where key = 'stocks';
  paused := coalesce((cfg->>'paused')::boolean, false);
  ivl := greatest(30, coalesce((cfg->>'interval_sec')::int, 300));
  select last_tick into lt from public.stock_state where id = 1 for update;
  if paused and not p_force then
    update public.stock_state set last_tick = now() where id = 1;
    return 0;
  end if;
  steps := floor(extract(epoch from (now() - lt)) / ivl)::int;
  if steps < 1 then return 0; end if;
  steps := least(steps, 288);
  for i in 1..steps loop
    for c in select * from public.stock_companies where active loop
      z := sqrt(-2 * ln(greatest(random(), 1e-12))) * cos(2 * pi() * random());
      np := c.price * exp(c.drift - 0.5 * c.volatility * c.volatility + c.volatility * z::numeric)
            + (c.start_price - c.price) * 0.002;
      np := greatest(0.5, least(np, c.start_price * 20));
      update public.stock_companies set price = round(np, 2) where id = c.id;
      insert into public.stock_prices (company_id, ts, price)
        values (c.id, lt + (i * ivl) * interval '1 second', round(np, 2)) on conflict do nothing;
    end loop;
  end loop;
  update public.stock_state set last_tick = lt + (steps * ivl) * interval '1 second' where id = 1;
  delete from public.stock_prices where ts < now() - interval '14 days';
  return steps;
end $$;

-- Marktuebersicht: Kurse, Veraenderung zu gestern, Mini-Verlauf und eigenes Depot
create or replace function public.stock_market() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cfg jsonb;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform public.stock_tick(false);
  select value into cfg from public.app_config where key = 'stocks';
  return jsonb_build_object(
    'paused', coalesce((cfg->>'paused')::boolean, false),
    'interval_sec', (cfg->>'interval_sec')::int,
    'server_ms', (extract(epoch from now()) * 1000)::bigint,
    'last_tick_ms', (select (extract(epoch from last_tick) * 1000)::bigint from public.stock_state where id = 1),
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'symbol', c.symbol, 'name', c.name, 'descr', c.descr,
        'risk', c.risk, 'price', c.price, 'active', c.active,
        'prev', coalesce((select price from public.stock_prices sp where sp.company_id = c.id and sp.ts <= now() - interval '24 hours'
                          order by sp.ts desc limit 1),
                         (select price from public.stock_prices sp where sp.company_id = c.id order by sp.ts asc limit 1), c.price),
        'spark', (select coalesce(jsonb_agg(price order by ts), '[]'::jsonb) from
                  (select price, ts from public.stock_prices sp where sp.company_id = c.id order by ts desc limit 30) q))
        order by c.id), '[]'::jsonb)
      from public.stock_companies c
      where c.active or exists (select 1 from public.stock_holdings h where h.user_id = me and h.company_id = c.id and h.shares > 0)),
    'holdings', (select coalesce(jsonb_agg(jsonb_build_object('company_id', h.company_id, 'shares', h.shares, 'cost', h.cost)), '[]'::jsonb)
                 from public.stock_holdings h where h.user_id = me and h.shares > 0)
  );
end $$;

-- Kursverlauf fuer das Diagramm (p_hours = 24, 168, ...)
create or replace function public.stock_history(p_company bigint, p_hours int default 24) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_array((extract(epoch from ts) * 1000)::bigint, price) order by ts), '[]'::jsonb)
          from public.stock_prices where company_id = p_company and ts >= now() - make_interval(hours => greatest(1, least(p_hours, 336))));
end $$;

create or replace function public.stock_buy(p_company bigint, p_shares bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; c public.stock_companies%rowtype; cfg jsonb;
        v_cost bigint; neu bigint; h public.stock_holdings%rowtype;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('stocks', null);
  if p_shares is null or p_shares < 1 or p_shares > 100000 then raise exception 'Ungültige Anzahl'; end if;
  perform public.stock_tick(false);
  select value into cfg from public.app_config where key = 'stocks';
  if coalesce((cfg->>'paused')::boolean, false) then raise exception 'Der Markt ist gerade pausiert'; end if;
  select * into c from public.stock_companies where id = p_company and active;
  if not found then raise exception 'Unternehmen nicht gefunden'; end if;
  v_cost := ceil(c.price * p_shares)::bigint;
  if v_cost > p.balance then raise exception 'Nicht genug Coins'; end if;
  update public.profiles set balance = balance - v_cost where id = p.id returning balance into neu;
  insert into public.stock_holdings (user_id, company_id, shares, cost) values (p.id, c.id, p_shares, v_cost)
    on conflict (user_id, company_id) do update set shares = public.stock_holdings.shares + excluded.shares,
                                                    cost = public.stock_holdings.cost + excluded.cost;
  select * into h from public.stock_holdings where user_id = p.id and company_id = c.id;
  insert into public.stock_transactions (user_id, company_id, symbol, side, shares, price, total)
    values (p.id, c.id, c.symbol, 'buy', p_shares, c.price, v_cost);
  perform public.log_tx(p.id, -v_cost, 'stock_buy');
  return jsonb_build_object('balance', neu, 'shares', h.shares, 'cost', h.cost, 'paid', v_cost);
end $$;

create or replace function public.stock_sell(p_company bigint, p_shares bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; c public.stock_companies%rowtype; h public.stock_holdings%rowtype;
        proceeds bigint; cost_removed bigint; gain bigint; pay bigint; neu bigint;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('stocks', null);
  if p_shares is null or p_shares < 1 then raise exception 'Ungültige Anzahl'; end if;
  perform public.stock_tick(false);
  select * into c from public.stock_companies where id = p_company;
  if not found then raise exception 'Unternehmen nicht gefunden'; end if;
  select * into h from public.stock_holdings where user_id = p.id and company_id = c.id for update;
  if not found or h.shares < p_shares then raise exception 'Du hast nicht so viele Aktien'; end if;
  proceeds := floor(c.price * p_shares)::bigint;
  cost_removed := case when p_shares = h.shares then h.cost else round(h.cost::numeric * p_shares / h.shares)::bigint end;
  gain := proceeds - cost_removed;
  -- Verkaufsgewinne zahlt die Bank (hoechstens bis zu ihrem Stand), Verluste bleiben bei der Bank
  pay := case when p.is_test then proceeds
              when gain > 0 then cost_removed + least(gain, public.bank_balance())
              else proceeds end;
  update public.profiles set balance = balance + pay where id = p.id returning balance into neu;
  if p_shares = h.shares then
    delete from public.stock_holdings where user_id = p.id and company_id = c.id;
  else
    update public.stock_holdings set shares = shares - p_shares, cost = cost - cost_removed where user_id = p.id and company_id = c.id;
  end if;
  insert into public.stock_transactions (user_id, company_id, symbol, side, shares, price, total)
    values (p.id, c.id, c.symbol, 'sell', p_shares, c.price, pay);
  perform public.log_tx(p.id, pay, 'stock_sell');
  return jsonb_build_object('balance', neu, 'received', pay, 'profit', pay - cost_removed);
end $$;

create or replace function public.stock_trades() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('symbol', symbol, 'side', side, 'shares', shares, 'price', price,
            'total', total, 'at', created_at) order by created_at desc, id desc), '[]'::jsonb)
          from (select * from public.stock_transactions where user_id = auth.uid() order by created_at desc, id desc limit 50) q);
end $$;

revoke all on function public.stock_tick(boolean) from public, anon, authenticated;
revoke all on function public.stock_market() from public, anon;
revoke all on function public.stock_history(bigint, int) from public, anon;
revoke all on function public.stock_buy(bigint, bigint) from public, anon;
revoke all on function public.stock_sell(bigint, bigint) from public, anon;
revoke all on function public.stock_trades() from public, anon;
grant execute on function public.stock_market() to authenticated;
grant execute on function public.stock_history(bigint, int) to authenticated;
grant execute on function public.stock_buy(bigint, bigint) to authenticated;
grant execute on function public.stock_sell(bigint, bigint) to authenticated;
grant execute on function public.stock_trades() to authenticated;


-- ===================================================================
-- 20261105000005_push_and_cron.sql
-- ===================================================================
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


-- ===================================================================
-- 20261105000006_admin.sql
-- ===================================================================
-- SpassCoin 2.0, Teil 6: Admin-Funktionen (alle pruefen serverseitig, ob der Aufrufer Admin ist)

create or replace function public.admin_get_all() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  return jsonb_build_object(
    'config', (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from public.app_config),
    'toggles', (select coalesce(jsonb_agg(to_jsonb(t) order by t.game), '[]'::jsonb) from public.game_toggles t),
    'missions', (select coalesce(jsonb_agg(to_jsonb(m) order by m.difficulty, m.id), '[]'::jsonb) from public.mission_defs m),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.category, i.price, i.sort), '[]'::jsonb) from public.shop_items i),
    'companies', (select coalesce(jsonb_agg(to_jsonb(c) order by c.id), '[]'::jsonb) from public.stock_companies c),
    'push', jsonb_build_object(
      'subscriptions', (select count(*) from public.push_subscriptions),
      'ready', (select vapid_private is not null from public.push_config where id = 1)),
    'bank', public.bank_balance());
end $$;

create or replace function public.chk_num(v text, lo numeric, hi numeric, msg text) returns numeric
language plpgsql immutable set search_path = public as $$
begin
  if v is null or v !~ '^-?[0-9]+(\.[0-9]+)?$' or v::numeric < lo or v::numeric > hi then raise exception '%', msg; end if;
  return v::numeric;
end $$;

create or replace function public.chk_arr(v jsonb, lo int, hi int, msg text) returns int
language plpgsql immutable set search_path = public as $$
begin
  if v is null or jsonb_typeof(v) <> 'array' or jsonb_array_length(v) < lo or jsonb_array_length(v) > hi then raise exception '%', msg; end if;
  return jsonb_array_length(v);
end $$;

create or replace function public.admin_save_config(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e jsonb; n int; lvl text; tot numeric := 0; pool int; ids text[] := '{}'; k text; m int;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if p_value is null then raise exception 'Keine Eingabe'; end if;
  if p_key = 'streak_rewards' then
    perform public.chk_arr(p_value, 1, 14, 'Streak: 1 bis 14 Tage');
    for e in select * from jsonb_array_elements(p_value) loop
      perform public.chk_num(e #>> '{}', 0, 1000, 'Streak: Belohnung muss zwischen 0 und 1000 liegen');
    end loop;
  elsif p_key = 'rescue' then
    if coalesce(jsonb_typeof(p_value->'enabled'), '') <> 'boolean' then raise exception 'Rettungsnetz: an oder aus fehlt'; end if;
    perform public.chk_num(p_value->>'threshold', 1, 1000, 'Rettungsnetz: Mindestguthaben zwischen 1 und 1000');
    perform public.chk_num(p_value->>'amount', 1, 1000, 'Rettungsnetz: Betrag zwischen 1 und 1000');
    perform public.chk_num(p_value->>'hour', 0, 23, 'Rettungsnetz: Stunde zwischen 0 und 23');
  elsif p_key = 'missions' then
    perform public.chk_arr(p_value->'slots', 1, 6, 'Missionen: 1 bis 6 pro Tag');
    for e in select * from jsonb_array_elements(p_value->'slots') loop
      if (e #>> '{}') not in ('easy', 'medium', 'hard') then raise exception 'Missionen: Stufe muss easy, medium oder hard sein'; end if;
    end loop;
  elsif p_key = 'plinko' then
    n := public.chk_num(p_value->>'rows', 6, 16, 'Plinko: Reihen zwischen 6 und 16')::int;
    foreach lvl in array array['low', 'medium', 'high'] loop
      if public.chk_arr(p_value->'levels'->lvl, n + 1, n + 1, 'Plinko: jede Stufe braucht genau ' || (n + 1) || ' Werte') <> n + 1 then
        raise exception 'Plinko: falsche Anzahl Werte';
      end if;
      for e in select * from jsonb_array_elements(p_value->'levels'->lvl) loop
        perform public.chk_num(e #>> '{}', 0, 1000, 'Plinko: Faktoren zwischen 0 und 1000');
      end loop;
    end loop;
  elsif p_key = 'scratch' then
    n := public.chk_num(p_value->>'cells', 4, 12, 'Rubbellos: 4 bis 12 Felder')::int;
    pool := public.chk_arr(p_value->'symbols', n, 16, 'Rubbellos: mindestens so viele Symbole wie Felder (' || n || '), höchstens 16');
    for e in select * from jsonb_array_elements(p_value->'symbols') loop
      if coalesce(e->>'id', '') !~ '^[a-z0-9_]{1,20}$' then raise exception 'Rubbellos: Symbol-ID nur a-z, 0-9 und _'; end if;
      if length(coalesce(e->>'icon', '')) not between 1 and 8 then raise exception 'Rubbellos: Symbol braucht 1 bis 8 Zeichen'; end if;
      if length(coalesce(e->>'name', '')) not between 1 and 20 then raise exception 'Rubbellos: Symbolname 1 bis 20 Zeichen'; end if;
      if (e->>'id') = any(ids) then raise exception 'Rubbellos: Symbol-ID doppelt'; end if;
      ids := ids || (e->>'id');
    end loop;
    perform public.chk_arr(p_value->'tiers', 1, 10, 'Rubbellos: 1 bis 10 Gewinnstufen');
    for e in select * from jsonb_array_elements(p_value->'tiers') loop
      perform public.chk_num(e->>'p', 0.000001, 1, 'Rubbellos: Wahrscheinlichkeit muss grösser als 0 sein');
      perform public.chk_num(e->>'mult', 0, 10000, 'Rubbellos: Gewinnfaktor zwischen 0 und 10000');
      m := public.chk_num(e->>'matches', 0, n, 'Rubbellos: gleiche Symbole zwischen 0 und ' || n)::int;
      if m = 1 then raise exception 'Rubbellos: gleiche Symbole 0 oder mindestens 2'; end if;
      if m > 0 and n - m > pool - 1 then raise exception 'Rubbellos: zu wenige Symbole für diese Stufe'; end if;
      tot := tot + (e->>'p')::numeric;
    end loop;
    if abs(tot - 1) > 0.0001 then raise exception 'Rubbellos: Die Wahrscheinlichkeiten ergeben % Prozent, sie müssen 100 ergeben', round(tot * 100, 3); end if;
  elsif p_key = 'hilo' then
    perform public.chk_arr(p_value->'ladder', 1, 15, 'Higher or Lower: 1 bis 15 Stufen');
    for e in select * from jsonb_array_elements(p_value->'ladder') loop
      perform public.chk_num(e #>> '{}', 0.1, 1000, 'Higher or Lower: Faktoren zwischen 0.1 und 1000');
    end loop;
    if coalesce(p_value->>'tie', '') not in ('lose', 'push') then raise exception 'Higher or Lower: Gleichstand muss lose oder push sein'; end if;
  elsif p_key = 'poker' then
    foreach k in array array['royal', 'straight_flush', 'four', 'full_house', 'flush', 'straight', 'three', 'two_pair', 'jacks'] loop
      perform public.chk_num(p_value->'paytable'->>k, 0, 10000, 'Video Poker: Auszahlung für ' || k || ' fehlt oder ist ungültig');
    end loop;
  elsif p_key = 'stocks' then
    perform public.chk_num(p_value->>'interval_sec', 30, 86400, 'Börse: Intervall zwischen 30 und 86400 Sekunden');
    if coalesce(jsonb_typeof(p_value->'paused'), '') <> 'boolean' then raise exception 'Börse: pausiert ja oder nein fehlt'; end if;
  else
    raise exception 'Unbekannte Einstellung';
  end if;
  insert into public.app_config (key, value) values (p_key, p_value)
    on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

create or replace function public.admin_save_toggle(p_game text, p_enabled boolean, p_min int, p_max int, p_limit int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if not exists (select 1 from public.game_toggles where game = p_game) then raise exception 'Unbekanntes Spiel'; end if;
  if p_min is null or p_min < 1 or p_max is null or p_max < p_min or p_max > 100000 then raise exception 'Einsatzgrenzen sind ungültig'; end if;
  if p_limit is not null and p_limit < 1 then raise exception 'Das Tageslimit muss mindestens 1 sein'; end if;
  update public.game_toggles set enabled = coalesce(p_enabled, true), min_stake = p_min, max_stake = p_max, daily_round_limit = p_limit
    where game = p_game;
end $$;

create or replace function public.admin_save_mission(p_mission jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare mid bigint := nullif(p_mission->>'id', '')::bigint; kd text := p_mission->>'kind'; gm text := nullif(p_mission->>'game', '');
        k text := nullif(trim(coalesce(p_mission->>'key', '')), '');
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if length(trim(coalesce(p_mission->>'title', ''))) not between 1 and 80 then raise exception 'Titel braucht 1 bis 80 Zeichen'; end if;
  if kd not in ('rounds_any', 'rounds_game', 'wins_any', 'wins_game', 'win_streak_game', 'win_streak_any', 'distinct_games') then raise exception 'Unbekannte Missionsart'; end if;
  if kd in ('rounds_game', 'wins_game', 'win_streak_game') and (gm is null or not exists (select 1 from public.game_toggles where game = gm)) then
    raise exception 'Für diese Missionsart braucht es ein gültiges Spiel';
  end if;
  if kd not in ('rounds_game', 'wins_game', 'win_streak_game') then gm := null; end if;
  if (p_mission->>'target')::int < 1 or (p_mission->>'target')::int > 1000 then raise exception 'Ziel zwischen 1 und 1000'; end if;
  if (p_mission->>'reward')::int < 0 or (p_mission->>'reward')::int > 1000 then raise exception 'Belohnung zwischen 0 und 1000'; end if;
  if p_mission->>'difficulty' not in ('easy', 'medium', 'hard') then raise exception 'Schwierigkeit muss easy, medium oder hard sein'; end if;
  if mid is null then
    insert into public.mission_defs (key, title, descr, kind, game, target, reward, difficulty, active)
      values (coalesce(k, 'm_' || substr(md5(random()::text), 1, 8)), trim(p_mission->>'title'), coalesce(p_mission->>'descr', ''),
              kd, gm, (p_mission->>'target')::int, (p_mission->>'reward')::int, p_mission->>'difficulty',
              coalesce((p_mission->>'active')::boolean, true)) returning id into mid;
  else
    update public.mission_defs set title = trim(p_mission->>'title'), descr = coalesce(p_mission->>'descr', ''), kind = kd, game = gm,
      target = (p_mission->>'target')::int, reward = (p_mission->>'reward')::int, difficulty = p_mission->>'difficulty',
      active = coalesce((p_mission->>'active')::boolean, true) where id = mid;
    if not found then raise exception 'Mission nicht gefunden'; end if;
  end if;
  return mid;
end $$;

create or replace function public.admin_delete_mission(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  delete from public.mission_defs where id = p_id;
end $$;

create or replace function public.admin_save_item(p_item jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare iid text := p_item->>'id';
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if coalesce(iid, '') !~ '^[a-z0-9_-]{2,40}$' then raise exception 'Artikel-ID: 2 bis 40 Zeichen (a-z, 0-9, _ und -)'; end if;
  if p_item->>'category' not in ('avatar', 'frame', 'color', 'background', 'name_color', 'rank_effect') then raise exception 'Unbekannte Kategorie'; end if;
  if length(trim(coalesce(p_item->>'name', ''))) not between 1 and 40 then raise exception 'Name braucht 1 bis 40 Zeichen'; end if;
  if (p_item->>'price')::int < 0 or (p_item->>'price')::int > 100000 then raise exception 'Preis zwischen 0 und 100000'; end if;
  if p_item->>'rarity' not in ('common', 'rare', 'epic', 'legendary') then raise exception 'Seltenheit ungültig'; end if;
  insert into public.shop_items (id, category, name, descr, price, rarity, data, active, sort)
    values (iid, p_item->>'category', trim(p_item->>'name'), coalesce(p_item->>'descr', ''), (p_item->>'price')::int, p_item->>'rarity',
            coalesce(p_item->'data', '{}'::jsonb), coalesce((p_item->>'active')::boolean, true), coalesce((p_item->>'sort')::int, 0))
  on conflict (id) do update set category = excluded.category, name = excluded.name, descr = excluded.descr, price = excluded.price,
    rarity = excluded.rarity, data = excluded.data, active = excluded.active, sort = excluded.sort;
  return iid;
end $$;

-- Gekaufte Artikel bleiben im Besitz: sie werden nur ausgeblendet, nie geloescht
create or replace function public.admin_delete_item(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if exists (select 1 from public.player_inventory where item_id = p_id) then
    update public.shop_items set active = false where id = p_id;
  else
    delete from public.shop_items where id = p_id;
  end if;
end $$;

create or replace function public.admin_save_company(p_company jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare cid bigint := nullif(p_company->>'id', '')::bigint; sym text := upper(trim(coalesce(p_company->>'symbol', '')));
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if sym !~ '^[A-Z0-9]{2,6}$' then raise exception 'Kürzel: 2 bis 6 Buchstaben oder Zahlen'; end if;
  if length(trim(coalesce(p_company->>'name', ''))) not between 1 and 40 then raise exception 'Name braucht 1 bis 40 Zeichen'; end if;
  if p_company->>'risk' not in ('low', 'medium', 'high') then raise exception 'Risiko muss low, medium oder high sein'; end if;
  if (p_company->>'volatility')::numeric not between 0 and 0.2 then raise exception 'Schwankung zwischen 0 und 0.2'; end if;
  if coalesce((p_company->>'drift')::numeric, 0) not between -0.05 and 0.05 then raise exception 'Trend zwischen -0.05 und 0.05'; end if;
  if (p_company->>'start_price')::numeric < 0.5 or (p_company->>'start_price')::numeric > 100000 then raise exception 'Startkurs zwischen 0.5 und 100000'; end if;
  if cid is null then
    insert into public.stock_companies (symbol, name, descr, risk, price, start_price, volatility, drift, active)
      values (sym, trim(p_company->>'name'), coalesce(p_company->>'descr', ''), p_company->>'risk', (p_company->>'start_price')::numeric,
              (p_company->>'start_price')::numeric, (p_company->>'volatility')::numeric, coalesce((p_company->>'drift')::numeric, 0),
              coalesce((p_company->>'active')::boolean, true)) returning id into cid;
    insert into public.stock_prices (company_id, ts, price) values (cid, now(), (p_company->>'start_price')::numeric) on conflict do nothing;
  else
    update public.stock_companies set symbol = sym, name = trim(p_company->>'name'), descr = coalesce(p_company->>'descr', ''),
      risk = p_company->>'risk', start_price = (p_company->>'start_price')::numeric, volatility = (p_company->>'volatility')::numeric,
      drift = coalesce((p_company->>'drift')::numeric, 0), active = coalesce((p_company->>'active')::boolean, true) where id = cid;
    if not found then raise exception 'Unternehmen nicht gefunden'; end if;
    if coalesce((p_company->>'reset_price')::boolean, false) then
      update public.stock_companies set price = start_price where id = cid;
      insert into public.stock_prices (company_id, ts, price) select id, now(), price from public.stock_companies where id = cid on conflict do nothing;
    end if;
  end if;
  return cid;
end $$;

create or replace function public.admin_delete_company(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if exists (select 1 from public.stock_holdings where company_id = p_id and shares > 0) then
    raise exception 'Es gibt noch Aktionäre. Setze das Unternehmen stattdessen auf inaktiv.';
  end if;
  delete from public.stock_companies where id = p_id;
end $$;

create or replace function public.admin_run_rescue() returns int
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  return public.run_rescue(true);
end $$;

-- Coin-Wirtschaft: Einnahmen, Ausgaben, Auszahlungsquoten, Verlauf
create or replace function public.admin_economy() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  perform public.snapshot_economy();
  select * into s from public.game_settings where id = 1;
  return jsonb_build_object(
    'total', s.total_coins,
    'bank', public.bank_balance(),
    'circulation', (select coalesce(sum(balance), 0) from public.profiles where not is_admin and not is_test),
    'invested', (select coalesce(sum(h.cost), 0) from public.stock_holdings h join public.profiles p on p.id = h.user_id where not p.is_admin and not p.is_test),
    'players', (select count(*) from public.profiles where not is_admin and not is_test),
    'earned_games', (select coalesce(sum(payout), 0) from public.game_rounds),
    'spent_games', (select coalesce(sum(stake), 0) from public.game_rounds),
    'rewards', (select jsonb_build_object(
        'streak', coalesce(sum(t.amount) filter (where t.kind = 'reward'), 0),
        'missions', coalesce(sum(t.amount) filter (where t.kind = 'mission'), 0),
        'rescue', coalesce(sum(t.amount) filter (where t.kind = 'rescue'), 0),
        'shop_income', 0)
      from public.transactions t join public.profiles p on p.id = t.receiver_id where not p.is_admin and not p.is_test),
    'shop_income', (select coalesce(sum(t.amount), 0) from public.transactions t join public.profiles p on p.id = t.sender_id
                    where t.kind = 'shop' and not p.is_admin and not p.is_test),
    'per_game', (select coalesce(jsonb_agg(jsonb_build_object('game', g.game, 'rounds', g.rounds, 'wins', g.wins, 'staked', g.staked,
                  'paid', g.paid, 'net_players', g.net, 'rtp', g.rtp, 'avg_net', g.avg_net, 'avg_win', g.avg_win, 'avg_loss', g.avg_loss)
                  order by g.rounds desc), '[]'::jsonb)
                 from (select game, count(*) rounds, count(*) filter (where win) wins, sum(stake) staked, sum(payout) paid, sum(net) net,
                              round(100.0 * sum(payout) / nullif(sum(stake), 0), 1) rtp, round(avg(net), 2) avg_net,
                              round(avg(net) filter (where net > 0), 2) avg_win, round(avg(net) filter (where net < 0), 2) avg_loss
                       from public.game_rounds group by game) g),
    'top_winners', (select coalesce(jsonb_agg(jsonb_build_object('username', q.username, 'net', q.net, 'rounds', q.rounds) order by q.net desc), '[]'::jsonb)
                    from (select p.username, sum(r.net) net, count(*) rounds from public.game_rounds r join public.profiles p on p.id = r.user_id
                          where r.created_at >= now() - interval '30 days' group by p.username order by sum(r.net) desc limit 5) q),
    'top_losers', (select coalesce(jsonb_agg(jsonb_build_object('username', q.username, 'net', q.net, 'rounds', q.rounds) order by q.net asc), '[]'::jsonb)
                   from (select p.username, sum(r.net) net, count(*) rounds from public.game_rounds r join public.profiles p on p.id = r.user_id
                         where r.created_at >= now() - interval '30 days' group by p.username order by sum(r.net) asc limit 5) q),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('day', q.day, 'bank', q.bank, 'circulation', q.circulation, 'rounds', q.rounds,
                 'staked', q.staked, 'paid', q.paid) order by q.day), '[]'::jsonb)
               from (select * from public.economy_snapshots order by day desc limit 60) q)
  );
end $$;

revoke all on function public.chk_num(text, numeric, numeric, text) from public, anon, authenticated;
revoke all on function public.chk_arr(jsonb, int, int, text) from public, anon, authenticated;
revoke all on function public.admin_get_all() from public, anon;
revoke all on function public.admin_save_config(text, jsonb) from public, anon;
revoke all on function public.admin_save_toggle(text, boolean, int, int, int) from public, anon;
revoke all on function public.admin_save_mission(jsonb) from public, anon;
revoke all on function public.admin_delete_mission(bigint) from public, anon;
revoke all on function public.admin_save_item(jsonb) from public, anon;
revoke all on function public.admin_delete_item(text) from public, anon;
revoke all on function public.admin_save_company(jsonb) from public, anon;
revoke all on function public.admin_delete_company(bigint) from public, anon;
revoke all on function public.admin_run_rescue() from public, anon;
revoke all on function public.admin_economy() from public, anon;
grant execute on function public.admin_get_all() to authenticated;
grant execute on function public.admin_save_config(text, jsonb) to authenticated;
grant execute on function public.admin_save_toggle(text, boolean, int, int, int) to authenticated;
grant execute on function public.admin_save_mission(jsonb) to authenticated;
grant execute on function public.admin_delete_mission(bigint) to authenticated;
grant execute on function public.admin_save_item(jsonb) to authenticated;
grant execute on function public.admin_delete_item(text) to authenticated;
grant execute on function public.admin_save_company(jsonb) to authenticated;
grant execute on function public.admin_delete_company(bigint) to authenticated;
grant execute on function public.admin_run_rescue() to authenticated;
grant execute on function public.admin_economy() to authenticated;


commit;
