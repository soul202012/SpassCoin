-- SpassCoin: Bank statt Pool, Slotmaschine, Blackjack, Pferderennen, Streak-Freischaltung,
-- Test-Konto, Einstellungen pro Konto, Admin-Kontoverwaltung.
-- Im Supabase "SQL Editor" einfügen und "Run" klicken.
-- Voraussetzung: supabase-setup.sql, supabase-erweiterung.sql und supabase-spiele.sql wurden schon ausgeführt.

-- =====================================================================
-- 1) Neue Spalten und Tabellen
-- =====================================================================
alter table public.profiles
  add column if not exists is_test boolean not null default false,
  add column if not exists settings jsonb not null default '{}'::jsonb;

alter table public.game_settings
  add column if not exists slot_symbols jsonb not null default '[
    {"symbol":"🍒","weight":30,"mult":8},{"symbol":"🍋","weight":25,"mult":17},
    {"symbol":"🔔","weight":20,"mult":33},{"symbol":"⭐","weight":13,"mult":75},
    {"symbol":"💎","weight":8,"mult":130},{"symbol":"7️⃣","weight":4,"mult":360}]'::jsonb,
  add column if not exists bj_blackjack_payout numeric not null default 1.5 check (bj_blackjack_payout between 1 and 3),
  add column if not exists bj_win_payout numeric not null default 1 check (bj_win_payout between 0.5 and 2),
  add column if not exists bj_soft17 boolean not null default false,
  add column if not exists race_horses jsonb not null default '[
    {"name":"Rot","color":"#e53935","weight":30,"odds":3.3},
    {"name":"Blau","color":"#1e88e5","weight":25,"odds":4},
    {"name":"Grün","color":"#43a047","weight":20,"odds":5},
    {"name":"Gelb","color":"#fdd835","weight":15,"odds":6.7},
    {"name":"Violett","color":"#8e24aa","weight":10,"odds":10}]'::jsonb;

-- Die gesamte Coin-Menge ist jetzt 10000: Bank + alle normalen Konten = 10000
update public.game_settings set total_coins = 10000 where id = 1;

alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check
  check (kind in ('transfer','reward','grant','game_chest','game_wheel','game_slots','game_bj','game_race','admin_adjust'));

create table if not exists public.blackjack_games (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  stake int not null,
  deck int[] not null,
  player int[] not null,
  dealer int[] not null,
  doubled boolean not null default false,
  status text not null default 'active' check (status in ('active','done')),
  created_at timestamptz not null default now()
);

create table if not exists public.races (
  race_date date primary key,
  seed int not null,
  winner int not null check (winner between 0 and 4),
  horses jsonb not null,
  settled boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.horse_bets (
  id bigint generated always as identity primary key,
  race_date date not null references public.races(race_date),
  user_id uuid not null references public.profiles(id) on delete cascade,
  horse int not null check (horse between 0 and 4),
  stake int not null check (stake > 0),
  status text not null default 'open' check (status in ('open','won','lost')),
  payout int not null default 0,
  created_at timestamptz not null default now()
);

alter table public.blackjack_games enable row level security;
alter table public.races enable row level security;
alter table public.horse_bets enable row level security;
revoke all on public.blackjack_games, public.races, public.horse_bets from anon, authenticated;

-- =====================================================================
-- 2) Admin-Prüfung: Test-Konten haben ebenfalls Admin-Zugriff
-- =====================================================================
create or replace function public.is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select coalesce((select is_admin or is_test from public.profiles where id = auth.uid()), false)
$$;

-- =====================================================================
-- 3) Bank (intern). Bank = 10000 minus alle Coins auf normalen Konten.
--    Normale Konten = weder Admin noch Test-Konto.
-- =====================================================================
create or replace function public.bank_balance() returns bigint
language sql security definer set search_path = public stable as $$
  select greatest(0, (select total_coins from public.game_settings where id = 1)
         - coalesce((select sum(balance) from public.profiles where not is_admin and not is_test), 0))::bigint
$$;

-- -1 (Bank leer) bis +1 (Bank voll), 0 genau bei der Schwelle
create or replace function public.bank_factor() returns numeric
language plpgsql security definer set search_path = public stable as $$
declare s public.game_settings%rowtype; pct numeric;
begin
  select * into s from public.game_settings where id = 1;
  pct := public.bank_balance()::numeric / s.total_coins * 100;
  if pct >= s.pool_threshold then
    return least(1, (pct - s.pool_threshold) / (100 - s.pool_threshold));
  else
    return -least(1, (s.pool_threshold - pct) / s.pool_threshold);
  end if;
end $$;

-- Auszahlung wird auf den Bankstand begrenzt (Test-Konten laufen nicht über die Bank)
create or replace function public.payout_cap(p_test boolean, p_payout bigint) returns bigint
language sql security definer set search_path = public stable as $$
  select case when p_test then p_payout else least(p_payout, public.bank_balance()) end
$$;

create or replace function public.log_tx(p_user uuid, p_net bigint, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_net > 0 then
    insert into public.transactions (sender_id, receiver_id, amount, kind) values (null, p_user, p_net, p_kind);
  elsif p_net < 0 then
    insert into public.transactions (sender_id, receiver_id, amount, kind) values (p_user, null, -p_net, p_kind);
  end if;
end $$;

-- Prüft Login, sperrt das Konto, blockiert Admins und prüft die Streak-Freischaltung
create or replace function public.require_player(p_game text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p public.profiles%rowtype;
        today date := (now() at time zone 'Europe/Zurich')::date; eff int;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into p from public.profiles where id = me for update;
  if p.is_admin and not p.is_test then
    raise exception 'Admins können nicht mitspielen. Nimm dafür das Test-Konto';
  end if;
  if not p.is_test then
    eff := case when p.last_claim >= today - 1 then p.streak else 0 end;
    if p_game = 'slots' and eff < 3 then raise exception 'Gesperrt: Die Slotmaschine braucht 3 Tage Streak'; end if;
    if p_game = 'blackjack' and eff < 5 then raise exception 'Gesperrt: Blackjack braucht 5 Tage Streak'; end if;
  end if;
  return p;
end $$;

-- =====================================================================
-- 4) Streak: gibt keine Coins mehr, sondern schaltet Spiele frei
-- =====================================================================
create or replace function public.claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p public.profiles%rowtype;
        today date := (now() at time zone 'Europe/Zurich')::date; ns int;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into p from public.profiles where id = me for update;
  if p.last_claim = today then raise exception 'Heute schon abgeholt'; end if;
  if p.last_claim = today - 1 then ns := p.streak + 1; else ns := 1; end if;
  update public.profiles set streak = ns, last_claim = today where id = me;
  return json_build_object('streak', ns);
end $$;

-- =====================================================================
-- 5) Coins senden: nur zwischen normalen Konten (sonst würden Coins aus dem Nichts entstehen)
-- =====================================================================
create or replace function public.send_coins(p_code text, p_amount int) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rid uuid; neu bigint; blocked boolean;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Ungültige Anzahl'; end if;
  select (is_admin or is_test) into blocked from public.profiles where id = me;
  if blocked then raise exception 'Admins und Test-Konten können keine Coins senden'; end if;
  select id, (is_admin or is_test) into rid, blocked from public.profiles where code = trim(p_code);
  if rid is null or blocked then raise exception 'Diesen Code gibt es nicht'; end if;
  if rid = me then raise exception 'Du kannst dir nicht selbst Coins senden'; end if;
  perform 1 from public.profiles where id in (me, rid) order by id for update;
  update public.profiles set balance = balance - p_amount
    where id = me and balance >= p_amount returning balance into neu;
  if neu is null then raise exception 'Nicht genug Coins'; end if;
  update public.profiles set balance = balance + p_amount where id = rid;
  insert into public.transactions (sender_id, receiver_id, amount, kind) values (me, rid, p_amount, 'transfer');
  return neu;
end $$;

-- Anfragen: Coins kommen aus der Bank
create or replace function public.decide_request(p_id bigint, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r public.coin_requests%rowtype; t public.profiles%rowtype;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into r from public.coin_requests where id = p_id for update;
  if not found or r.status <> 'open' then raise exception 'Anfrage nicht mehr offen'; end if;
  if p_approve then
    select * into t from public.profiles where id = r.user_id for update;
    if not (t.is_admin or t.is_test) and r.amount > public.bank_balance() then
      raise exception 'Die Bank hat nicht genug Coins (Bank: %)', public.bank_balance();
    end if;
    update public.profiles set balance = balance + r.amount where id = r.user_id;
    insert into public.transactions (sender_id, receiver_id, amount, kind) values (null, r.user_id, r.amount, 'grant');
  end if;
  update public.coin_requests
    set status = case when p_approve then 'approved' else 'rejected' end, decided_at = now(), decided_by = auth.uid()
    where id = p_id;
end $$;

-- Rangliste: ohne Admins und ohne Test-Konto
create or replace function public.leaderboard()
returns table(username text, balance bigint)
language sql security definer set search_path = public stable as $$
  select p.username, p.balance from public.profiles p
  where auth.uid() is not null and not p.is_admin and not p.is_test
  order by p.balance desc, p.username limit 200
$$;

-- Einstellungen pro Konto speichern (Musik, Sound, Hell/Dunkel, Akzentfarbe)
create or replace function public.save_my_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if jsonb_typeof(p_settings) <> 'object' or length(p_settings::text) > 2000 then raise exception 'Ungültige Einstellungen'; end if;
  update public.profiles set settings = p_settings where id = auth.uid();
end $$;

-- =====================================================================
-- 6) Spiel-Infos für Spieler (ohne Bankstand)
-- =====================================================================
create or replace function public.game_info() returns json
language plpgsql security definer set search_path = public stable as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype;
        today date := (now() at time zone 'Europe/Zurich')::date; eff int;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  select * into s from public.game_settings where id = 1;
  select * into p from public.profiles where id = auth.uid();
  eff := case when p.last_claim >= today - 1 then p.streak else 0 end;
  return json_build_object('wheel_stake', s.wheel_stake, 'chest_stake', s.chest_stake, 'wheel_fields', s.wheel_fields,
    'slot_symbols', (select coalesce(json_agg(json_build_object('symbol', e->>'symbol', 'mult', e->'mult') order by o), '[]'::json)
                     from jsonb_array_elements(s.slot_symbols) with ordinality as t(e, o)),
    'bj_blackjack_payout', s.bj_blackjack_payout, 'bj_win_payout', s.bj_win_payout,
    'eff_streak', eff, 'is_test', p.is_test);
end $$;

-- =====================================================================
-- 7) Glücksrad
-- =====================================================================
create or replace function public.wheel_spin() returns json
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype;
        n int; pay numeric[] := '{}'; w numeric[] := '{}'; i int; r numeric; acc numeric := 0; idx int := 0;
        payout int; credit bigint; net bigint; neu bigint; f numeric;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('wheel');
  if p.balance < s.wheel_stake then raise exception 'Nicht genug Coins'; end if;
  f := case when p.is_test then 0 else public.bank_factor() end;
  n := jsonb_array_length(s.wheel_fields);
  for i in 0..n-1 loop
    pay := pay || (s.wheel_fields->i->>'payout')::numeric;
    w := w || (s.wheel_fields->i->>'weight')::numeric;
  end loop;
  w := public.adjust_weights(pay, w, s.wheel_stake, s.pool_strength * f);
  r := random() * 100;
  for i in 1..n loop
    acc := acc + w[i];
    if r < acc then idx := i; exit; end if;
  end loop;
  if idx = 0 then idx := n; end if;
  payout := pay[idx]::int;
  update public.profiles set balance = balance - s.wheel_stake where id = p.id;
  credit := public.payout_cap(p.is_test, payout);
  update public.profiles set balance = balance + credit where id = p.id returning balance into neu;
  net := credit - s.wheel_stake;
  perform public.log_tx(p.id, net, 'game_wheel');
  return json_build_object('index', idx - 1, 'payout', credit, 'stake', s.wheel_stake, 'net', net, 'balance', neu);
end $$;

-- =====================================================================
-- 8) Truhen
-- =====================================================================
create or replace function public.chest_start() returns json
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype;
        vals int[]; b int; d numeric; k int; arr int[]; lay int[]; prev int[]; neu bigint; gid bigint; i int; f numeric;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('chest');
  if exists (select 1 from public.chest_games where user_id = p.id and status = 'active') then
    raise exception 'Du hast noch ein offenes Spiel';
  end if;
  if p.balance < s.chest_stake then raise exception 'Nicht genug Coins'; end if;
  f := case when p.is_test then 0 else public.bank_factor() end;
  select array_agg(x::int order by x::int) into vals from jsonb_array_elements_text(s.chest_values) x;
  b := s.chest_bombs;
  d := s.pool_strength / 100 * 12 * f;
  k := trunc(abs(d))::int + case when random() < abs(d) - trunc(abs(d)) then 1 else 0 end;
  if d > 0 then
    k := least(k, b - 1);
    b := b - k;
    for i in 1..k loop vals := vals || vals[1]; end loop;
  elsif d < 0 then
    k := least(k, array_length(vals, 1) - 1);
    for i in 1..k loop vals := vals[1:array_length(vals, 1) - 1]; end loop;
    b := b + k;
  end if;
  arr := vals;
  for i in 1..b loop arr := arr || (-1); end loop;
  select array_agg(x order by random()) into lay from unnest(arr) x;
  select array_agg(x order by x desc) into prev from unnest(arr) x;
  update public.profiles set balance = balance - s.chest_stake where id = p.id returning balance into neu;
  insert into public.chest_games (user_id, stake, layout) values (p.id, s.chest_stake, lay) returning id into gid;
  return json_build_object('id', gid, 'stake', s.chest_stake, 'preview', prev, 'balance', neu);
end $$;

create or replace function public.chest_open(p_game bigint, p_index int) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g public.chest_games%rowtype; v int; run int; coins int; t boolean;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.chest_games where id = p_game and user_id = me for update;
  if not found or g.status <> 'active' then raise exception 'Kein offenes Spiel'; end if;
  if p_index is null or p_index < 0 or p_index > 11 then raise exception 'Ungültige Truhe'; end if;
  if p_index = any(g.opened) then raise exception 'Diese Truhe ist schon offen'; end if;
  select is_test into t from public.profiles where id = me;
  v := g.layout[p_index + 1];
  if v < 0 then
    update public.chest_games set status = 'bomb', running = 0 where id = g.id;
    perform public.log_tx(me, -g.stake, 'game_chest');
    return json_build_object('result', 'bomb', 'value', -1, 'running', 0, 'layout', g.layout);
  end if;
  run := case when t then g.running + v
              else greatest(g.running, least(g.running + v, public.bank_balance()::int)) end;
  update public.chest_games set opened = opened || p_index, running = run where id = g.id;
  select count(*) into coins from unnest(g.layout) x where x > 0;
  return json_build_object('result', 'coin', 'value', v, 'running', run,
                           'all_open', coalesce(array_length(g.opened, 1), 0) + 1 >= coins);
end $$;

create or replace function public.chest_cashout(p_game bigint) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g public.chest_games%rowtype; p public.profiles%rowtype; credit bigint; net bigint; neu bigint;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.chest_games where id = p_game and user_id = me for update;
  if not found or g.status <> 'active' then raise exception 'Kein offenes Spiel'; end if;
  if coalesce(array_length(g.opened, 1), 0) = 0 then raise exception 'Öffne zuerst mindestens eine Truhe'; end if;
  select * into p from public.profiles where id = me for update;
  credit := public.payout_cap(p.is_test, g.running);
  update public.profiles set balance = balance + credit where id = me returning balance into neu;
  update public.chest_games set status = 'cashed' where id = g.id;
  net := credit - g.stake;
  perform public.log_tx(me, net, 'game_chest');
  return json_build_object('credit', credit, 'net', net, 'balance', neu, 'layout', g.layout);
end $$;

-- =====================================================================
-- 9) Slotmaschine (ab 3 Tagen Streak)
-- =====================================================================
create or replace function public.slot_draw(p_w numeric[]) returns int
language plpgsql volatile as $$
declare tot numeric; r numeric; acc numeric := 0; i int;
begin
  select sum(x) into tot from unnest(p_w) x;
  r := random() * tot;
  for i in 1..array_length(p_w, 1) loop
    acc := acc + p_w[i];
    if r < acc then return i; end if;
  end loop;
  return array_length(p_w, 1);
end $$;

create or replace function public.slot_spin(p_stake int) returns json
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; n int; i int;
        w numeric[] := '{}'; m numeric[] := '{}'; a int; b int; c int; win boolean; f numeric; q numeric;
        payout bigint; credit bigint; net bigint; neu bigint;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('slots');
  if p_stake is null or p_stake < 1 then raise exception 'Ungültiger Einsatz'; end if;
  if p_stake > p.balance then raise exception 'Nicht genug Coins'; end if;
  n := jsonb_array_length(s.slot_symbols);
  for i in 0..n-1 loop
    w := w || (s.slot_symbols->i->>'weight')::numeric;
    m := m || (s.slot_symbols->i->>'mult')::numeric;
  end loop;
  f := case when p.is_test then 0 else public.bank_factor() end;
  q := s.pool_strength / 100 * abs(f);
  a := public.slot_draw(w); b := public.slot_draw(w); c := public.slot_draw(w);
  win := (a = b and b = c);
  -- dezente Anpassung: Bank leer = Treffer können neu ausgewürfelt werden, Bank voll = Nieten bekommen eine zweite Chance
  if (win and f < 0 and random() < q) or (not win and f > 0 and random() < q) then
    a := public.slot_draw(w); b := public.slot_draw(w); c := public.slot_draw(w);
    win := (a = b and b = c);
  end if;
  payout := case when win then floor(p_stake * m[a])::bigint else 0 end;
  update public.profiles set balance = balance - p_stake where id = p.id;
  credit := public.payout_cap(p.is_test, payout);
  update public.profiles set balance = balance + credit where id = p.id returning balance into neu;
  net := credit - p_stake;
  perform public.log_tx(p.id, net, 'game_slots');
  return json_build_object('reels', json_build_array(a - 1, b - 1, c - 1), 'win', win,
                           'payout', credit, 'stake', p_stake, 'net', net, 'balance', neu);
end $$;

-- =====================================================================
-- 10) Blackjack (ab 5 Tagen Streak). Karten 0..51: Rang = Karte % 13 (0 = Ass), Farbe = Karte / 13
-- =====================================================================
create or replace function public.bj_total(c int[]) returns int
language plpgsql immutable as $$
declare t int := 0; aces int := 0; x int; r int;
begin
  foreach x in array coalesce(c, '{}'::int[]) loop
    r := x % 13;
    if r = 0 then aces := aces + 1; t := t + 1;
    elsif r >= 9 then t := t + 10;
    else t := t + r + 1; end if;
  end loop;
  if aces > 0 and t + 10 <= 21 then t := t + 10; end if;
  return t;
end $$;

create or replace function public.bj_soft(c int[]) returns boolean
language plpgsql immutable as $$
declare h int := 0; aces int := 0; x int; r int;
begin
  foreach x in array coalesce(c, '{}'::int[]) loop
    r := x % 13;
    if r = 0 then aces := aces + 1; h := h + 1;
    elsif r >= 9 then h := h + 10;
    else h := h + r + 1; end if;
  end loop;
  return aces > 0 and h + 10 <= 21;
end $$;

create or replace function public.bj_view(g public.blackjack_games) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'id', g.id, 'stake', g.stake, 'player', to_jsonb(g.player), 'ptotal', public.bj_total(g.player),
    'dealer', case when g.status = 'done' then to_jsonb(g.dealer) else jsonb_build_array(g.dealer[1], -1) end,
    'dtotal', case when g.status = 'done' then to_jsonb(public.bj_total(g.dealer)) else null end,
    'status', g.status,
    'can_double', (g.status = 'active' and array_length(g.player, 1) = 2 and not g.doubled))
$$;

-- Spiel abschliessen und auszahlen. p_result: win, lose, push, blackjack
create or replace function public.bj_settle(p_game bigint, p_result text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.blackjack_games%rowtype; p public.profiles%rowtype; s public.game_settings%rowtype;
        payout bigint; credit bigint; neu bigint;
begin
  select * into g from public.blackjack_games where id = p_game for update;
  select * into p from public.profiles where id = g.user_id for update;
  select * into s from public.game_settings where id = 1;
  payout := case p_result
    when 'win' then floor(g.stake * (1 + s.bj_win_payout))
    when 'push' then g.stake
    when 'blackjack' then g.stake + floor(g.stake * s.bj_blackjack_payout)
    else 0 end;
  credit := public.payout_cap(p.is_test, payout);
  update public.profiles set balance = balance + credit where id = p.id returning balance into neu;
  update public.blackjack_games set status = 'done' where id = g.id;
  g.status := 'done';
  perform public.log_tx(p.id, credit - g.stake, 'game_bj');
  return public.bj_view(g) || jsonb_build_object('result', p_result, 'payout', credit, 'net', credit - g.stake, 'balance', neu);
end $$;

-- Dealer zieht bis 17
create or replace function public.bj_run_dealer(p_game bigint) returns void
language plpgsql security definer set search_path = public as $$
declare g public.blackjack_games%rowtype; s public.game_settings%rowtype; dl int[]; dk int[]; t int;
begin
  select * into g from public.blackjack_games where id = p_game for update;
  select * into s from public.game_settings where id = 1;
  dl := g.dealer; dk := g.deck;
  loop
    t := public.bj_total(dl);
    exit when t > 17 or (t = 17 and not (s.bj_soft17 and public.bj_soft(dl)));
    dl := dl || dk[1];
    dk := dk[2:array_length(dk, 1)];
  end loop;
  update public.blackjack_games set dealer = dl, deck = dk where id = p_game;
end $$;

create or replace function public.bj_finish(p_game bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.blackjack_games%rowtype; pt int; dt int; res text;
begin
  select * into g from public.blackjack_games where id = p_game;
  pt := public.bj_total(g.player); dt := public.bj_total(g.dealer);
  res := case when pt > 21 then 'lose' when dt > 21 then 'win' when pt > dt then 'win' when pt = dt then 'push' else 'lose' end;
  return public.bj_settle(p_game, res);
end $$;

create or replace function public.bj_current() returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare g public.blackjack_games%rowtype;
begin
  select * into g from public.blackjack_games where user_id = auth.uid() and status = 'active' order by id desc limit 1;
  if not found then return null; end if;
  return public.bj_view(g);
end $$;

create or replace function public.bj_start(p_stake int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; f numeric; q numeric;
        deck int[]; pl int[]; dl int[]; pt int; att int; redeal boolean; gid bigint; neu bigint; g public.blackjack_games%rowtype;
        pbj boolean; dbj boolean;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('blackjack');
  if exists (select 1 from public.blackjack_games where user_id = p.id and status = 'active') then
    raise exception 'Du hast noch ein offenes Spiel';
  end if;
  if p_stake is null or p_stake < 1 then raise exception 'Ungültiger Einsatz'; end if;
  if p_stake > p.balance then raise exception 'Nicht genug Coins'; end if;
  f := case when p.is_test then 0 else public.bank_factor() end;
  q := s.pool_strength / 100 * abs(f);
  for att in 1..2 loop
    select array_agg(x order by random()) into deck from generate_series(0, 51) x;
    pl := array[deck[1], deck[3]]; dl := array[deck[2], deck[4]]; deck := deck[5:52];
    pt := public.bj_total(pl);
    -- dezente Anpassung: Bank leer = sehr starke Starthände werden manchmal neu gegeben, Bank voll = sehr schwache
    redeal := att = 1 and ((f < 0 and pt >= 19 and random() < q) or (f > 0 and pt <= 12 and random() < q));
    exit when not redeal;
  end loop;
  update public.profiles set balance = balance - p_stake where id = p.id returning balance into neu;
  insert into public.blackjack_games (user_id, stake, deck, player, dealer) values (p.id, p_stake, deck, pl, dl) returning id into gid;
  pbj := public.bj_total(pl) = 21; dbj := public.bj_total(dl) = 21;
  if pbj and dbj then return public.bj_settle(gid, 'push'); end if;
  if pbj then return public.bj_settle(gid, 'blackjack'); end if;
  if dbj then return public.bj_settle(gid, 'lose'); end if;
  select * into g from public.blackjack_games where id = gid;
  return public.bj_view(g) || jsonb_build_object('balance', neu);
end $$;

create or replace function public.bj_hit(p_game bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.blackjack_games%rowtype; pl int[]; pt int;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.blackjack_games where id = p_game and user_id = auth.uid() and status = 'active' for update;
  if not found then raise exception 'Kein offenes Spiel'; end if;
  pl := g.player || g.deck[1];
  update public.blackjack_games set player = pl, deck = g.deck[2:array_length(g.deck, 1)] where id = g.id;
  pt := public.bj_total(pl);
  if pt > 21 then return public.bj_settle(g.id, 'lose'); end if;
  if pt = 21 then perform public.bj_run_dealer(g.id); return public.bj_finish(g.id); end if;
  select * into g from public.blackjack_games where id = g.id;
  return public.bj_view(g);
end $$;

create or replace function public.bj_stand(p_game bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.blackjack_games%rowtype;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.blackjack_games where id = p_game and user_id = auth.uid() and status = 'active' for update;
  if not found then raise exception 'Kein offenes Spiel'; end if;
  perform public.bj_run_dealer(g.id);
  return public.bj_finish(g.id);
end $$;

create or replace function public.bj_double(p_game bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.blackjack_games%rowtype; p public.profiles%rowtype; pl int[]; pt int;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.blackjack_games where id = p_game and user_id = auth.uid() and status = 'active' for update;
  if not found then raise exception 'Kein offenes Spiel'; end if;
  if array_length(g.player, 1) <> 2 or g.doubled then raise exception 'Verdoppeln geht nur mit den ersten zwei Karten'; end if;
  select * into p from public.profiles where id = g.user_id for update;
  if p.balance < g.stake then raise exception 'Nicht genug Coins zum Verdoppeln'; end if;
  update public.profiles set balance = balance - g.stake where id = p.id;
  pl := g.player || g.deck[1];
  update public.blackjack_games set player = pl, deck = g.deck[2:array_length(g.deck, 1)], stake = g.stake * 2, doubled = true where id = g.id;
  pt := public.bj_total(pl);
  if pt > 21 then return public.bj_settle(g.id, 'lose'); end if;
  perform public.bj_run_dealer(g.id);
  return public.bj_finish(g.id);
end $$;

-- =====================================================================
-- 11) Pferderennen: täglich 19:00 Uhr Schweizer Zeit, Wetten 18:00 bis 19:00, Rennen 19:00 bis 19:15
-- =====================================================================
create or replace function public.race_t(p_date date, p_hour int, p_min int) returns timestamptz
language sql stable as $$
  select ((p_date + make_time(p_hour, p_min, 0)) at time zone 'Europe/Zurich')
$$;

create or replace function public.ensure_race(p_date date) returns void
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; w numeric[] := '{}'; i int; r numeric; acc numeric := 0; win int := 4;
begin
  if exists (select 1 from public.races where race_date = p_date) then return; end if;
  select * into s from public.game_settings where id = 1;
  for i in 0..4 loop w := w || (s.race_horses->i->>'weight')::numeric; end loop;
  r := random() * 100;
  for i in 1..5 loop
    acc := acc + w[i];
    if r < acc then win := i - 1; exit; end if;
  end loop;
  insert into public.races (race_date, seed, winner, horses)
    values (p_date, floor(random() * 2147483646)::int + 1, win, s.race_horses)
    on conflict (race_date) do nothing;
end $$;

-- Wetten auszahlen, sobald ein Rennen vorbei ist (läuft automatisch beim Öffnen der Seite)
create or replace function public.race_settle() returns void
language plpgsql security definer set search_path = public as $$
declare r record; b record; p public.profiles%rowtype; odds numeric; payout bigint; credit bigint;
begin
  for r in select race_date, winner, horses from public.races
           where not settled and public.race_t(race_date, 19, 15) <= now() order by race_date loop
    perform 1 from public.game_settings where id = 1 for update;
    perform 1 from public.races where race_date = r.race_date and not settled for update;
    if not found then continue; end if;
    odds := (r.horses->r.winner->>'odds')::numeric;
    for b in select * from public.horse_bets where race_date = r.race_date and status = 'open' order by id loop
      select * into p from public.profiles where id = b.user_id for update;
      if b.horse = r.winner then
        payout := floor(b.stake * odds)::bigint;
        credit := public.payout_cap(p.is_test, payout);
        update public.profiles set balance = balance + credit where id = p.id;
        update public.horse_bets set status = 'won', payout = credit where id = b.id;
        perform public.log_tx(p.id, credit - b.stake, 'game_race');
      else
        update public.horse_bets set status = 'lost', payout = 0 where id = b.id;
        perform public.log_tx(p.id, -b.stake, 'game_race');
      end if;
    end loop;
    update public.races set settled = true where race_date = r.race_date;
  end loop;
end $$;

create or replace function public.race_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; r public.races%rowtype; lr public.races%rowtype;
        nowts timestamptz := now(); today date; t_open timestamptz; t_start timestamptz; t_end timestamptz;
        phase text; hs jsonb; hj jsonb; mine jsonb; lastj jsonb := null; nxt_open timestamptz; nxt_start timestamptz; have boolean := false;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  perform public.race_settle();
  today := (nowts at time zone 'Europe/Zurich')::date;
  t_open := public.race_t(today, 18, 0); t_start := public.race_t(today, 19, 0); t_end := public.race_t(today, 19, 15);
  phase := case when nowts < t_open then 'waiting' when nowts < t_start then 'betting'
                when nowts < t_end then 'racing' else 'finished' end;
  select * into s from public.game_settings where id = 1;
  if phase <> 'waiting' then
    perform public.ensure_race(today);
    select * into r from public.races where race_date = today;
    have := found;
  end if;
  hs := case when have then r.horses else s.race_horses end;
  select jsonb_agg(jsonb_build_object('name', e->>'name', 'color', e->>'color', 'odds', e->'odds') order by o)
    into hj from jsonb_array_elements(hs) with ordinality as t(e, o);
  select coalesce(jsonb_agg(jsonb_build_object('horse', horse, 'stake', stake, 'status', status, 'payout', payout) order by id), '[]'::jsonb)
    into mine from public.horse_bets where race_date = today and user_id = auth.uid() and have;
  mine := coalesce(mine, '[]'::jsonb);
  select * into lr from public.races where public.race_t(race_date, 19, 15) <= nowts order by race_date desc limit 1;
  if found then
    lastj := jsonb_build_object('date', lr.race_date, 'winner', lr.winner,
      'name', lr.horses->lr.winner->>'name', 'color', lr.horses->lr.winner->>'color',
      'my_net', (select coalesce(sum(payout - stake), 0) from public.horse_bets
                 where race_date = lr.race_date and user_id = auth.uid() and status <> 'open'),
      'my_stake', (select coalesce(sum(stake), 0) from public.horse_bets
                 where race_date = lr.race_date and user_id = auth.uid() and status <> 'open'));
  end if;
  nxt_open := case phase when 'waiting' then t_open when 'finished' then public.race_t(today + 1, 18, 0) else null end;
  nxt_start := case phase when 'waiting' then t_start when 'finished' then public.race_t(today + 1, 19, 0) else null end;
  return jsonb_build_object(
    'server_ms', (extract(epoch from nowts) * 1000)::bigint, 'phase', phase,
    't_open_ms', (extract(epoch from t_open) * 1000)::bigint,
    't_start_ms', (extract(epoch from t_start) * 1000)::bigint,
    't_end_ms', (extract(epoch from t_end) * 1000)::bigint,
    'next_open_ms', (extract(epoch from nxt_open) * 1000)::bigint,
    'next_start_ms', (extract(epoch from nxt_start) * 1000)::bigint,
    'horses', hj, 'my_bets', mine,
    'seed', case when have and phase in ('racing', 'finished') then r.seed else null end,
    'winner', case when have and phase in ('racing', 'finished') then r.winner else null end,
    'last', lastj);
end $$;

create or replace function public.place_bet(p_horse int, p_stake int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.game_settings%rowtype; p public.profiles%rowtype; nowts timestamptz := now(); today date; neu bigint;
begin
  select * into s from public.game_settings where id = 1 for update;
  p := public.require_player('race');
  today := (nowts at time zone 'Europe/Zurich')::date;
  if nowts < public.race_t(today, 18, 0) or nowts >= public.race_t(today, 19, 0) then
    raise exception 'Wetten sind nur von 18:00 bis 19:00 Uhr möglich';
  end if;
  perform public.ensure_race(today);
  if p_horse is null or p_horse < 0 or p_horse > 4 then raise exception 'Ungültiges Pferd'; end if;
  if p_stake is null or p_stake < 1 then raise exception 'Ungültiger Einsatz'; end if;
  if p_stake > p.balance then raise exception 'Nicht genug Coins'; end if;
  update public.profiles set balance = balance - p_stake where id = p.id returning balance into neu;
  insert into public.horse_bets (race_date, user_id, horse, stake) values (today, p.id, p_horse, p_stake);
  return jsonb_build_object('balance', neu);
end $$;

-- =====================================================================
-- 12) Admin: Bank, Einstellungen, Konten
-- =====================================================================
create or replace function public.admin_game_overview() returns json
language plpgsql security definer set search_path = public stable as $$
declare s public.game_settings%rowtype; circ bigint; bank bigint; pl int;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  select * into s from public.game_settings where id = 1;
  select coalesce(sum(balance), 0), count(*) into circ, pl from public.profiles where not is_admin and not is_test;
  bank := public.bank_balance();
  return json_build_object('total', s.total_coins, 'circulating', circ, 'bank', bank, 'players', pl,
    'bank_pct', round(bank::numeric / s.total_coins * 100, 1),
    'settings', json_build_object('pool_threshold', s.pool_threshold, 'pool_strength', s.pool_strength,
      'wheel_stake', s.wheel_stake, 'wheel_fields', s.wheel_fields,
      'chest_stake', s.chest_stake, 'chest_bombs', s.chest_bombs, 'chest_values', s.chest_values,
      'slot_symbols', s.slot_symbols, 'bj_blackjack_payout', s.bj_blackjack_payout,
      'bj_win_payout', s.bj_win_payout, 'bj_soft17', s.bj_soft17, 'race_horses', s.race_horses));
end $$;

create or replace function public.admin_save_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e jsonb; wsum numeric; nb int; cnt int;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  begin
    if (p_settings->>'pool_threshold')::int not between 1 and 99 then raise exception 'Bank-Schwelle muss zwischen 1 und 99 Prozent liegen'; end if;
    if (p_settings->>'pool_strength')::numeric not between 0 and 30 then raise exception 'Stärke der Anpassung muss zwischen 0 und 30 liegen'; end if;
    if (p_settings->>'wheel_stake')::int not between 1 and 1000 then raise exception 'Einsatz Glücksrad muss zwischen 1 und 1000 liegen'; end if;
    if (p_settings->>'chest_stake')::int not between 1 and 1000 then raise exception 'Einsatz Truhen muss zwischen 1 und 1000 liegen'; end if;
    -- Truhen
    nb := (p_settings->>'chest_bombs')::int;
    if nb not between 1 and 11 then raise exception 'Anzahl Bomben muss zwischen 1 und 11 liegen'; end if;
    if jsonb_typeof(p_settings->'chest_values') <> 'array' or jsonb_array_length(p_settings->'chest_values') <> 12 - nb then
      raise exception 'Anzahl Truhenwerte plus Bomben muss genau 12 ergeben';
    end if;
    for e in select * from jsonb_array_elements(p_settings->'chest_values') loop
      if (e #>> '{}')::int not between 1 and 1000 then raise exception 'Truhenwerte müssen zwischen 1 und 1000 liegen'; end if;
    end loop;
    -- Glücksrad
    if jsonb_typeof(p_settings->'wheel_fields') <> 'array' then raise exception 'Glücksrad-Felder fehlen'; end if;
    cnt := jsonb_array_length(p_settings->'wheel_fields');
    if cnt not between 2 and 20 then raise exception 'Das Glücksrad braucht 2 bis 20 Felder'; end if;
    wsum := 0;
    for e in select * from jsonb_array_elements(p_settings->'wheel_fields') loop
      if (e->>'payout')::int not between 0 and 1000 then raise exception 'Glücksrad: Auszahlung muss zwischen 0 und 1000 liegen'; end if;
      if (e->>'weight')::numeric <= 0 then raise exception 'Glücksrad: Chance muss grösser als 0 sein'; end if;
      wsum := wsum + (e->>'weight')::numeric;
    end loop;
    if abs(wsum - 100) > 0.01 then raise exception 'Glücksrad: Die Chancen ergeben % Prozent, sie müssen 100 ergeben', wsum; end if;
    -- Slotmaschine
    if jsonb_typeof(p_settings->'slot_symbols') <> 'array' then raise exception 'Slot-Symbole fehlen'; end if;
    cnt := jsonb_array_length(p_settings->'slot_symbols');
    if cnt not between 2 and 10 then raise exception 'Die Slotmaschine braucht 2 bis 10 Symbole'; end if;
    wsum := 0;
    for e in select * from jsonb_array_elements(p_settings->'slot_symbols') loop
      if length(coalesce(e->>'symbol', '')) not between 1 and 8 then raise exception 'Slot: Jedes Symbol braucht 1 bis 8 Zeichen'; end if;
      if (e->>'weight')::numeric <= 0 then raise exception 'Slot: Chance muss grösser als 0 sein'; end if;
      if (e->>'mult')::numeric < 0 or (e->>'mult')::numeric > 10000 then raise exception 'Slot: Gewinnfaktor muss zwischen 0 und 10000 liegen'; end if;
      wsum := wsum + (e->>'weight')::numeric;
    end loop;
    if abs(wsum - 100) > 0.01 then raise exception 'Slot: Die Chancen ergeben % Prozent, sie müssen 100 ergeben', wsum; end if;
    -- Blackjack
    if (p_settings->>'bj_blackjack_payout')::numeric not between 1 and 3 then raise exception 'Blackjack-Auszahlung muss zwischen 1 und 3 liegen'; end if;
    if (p_settings->>'bj_win_payout')::numeric not between 0.5 and 2 then raise exception 'Blackjack-Gewinnfaktor muss zwischen 0.5 und 2 liegen'; end if;
    perform (p_settings->>'bj_soft17')::boolean;
    -- Pferderennen
    if jsonb_typeof(p_settings->'race_horses') <> 'array' or jsonb_array_length(p_settings->'race_horses') <> 5 then
      raise exception 'Es braucht genau 5 Pferde';
    end if;
    wsum := 0;
    for e in select * from jsonb_array_elements(p_settings->'race_horses') loop
      if length(coalesce(e->>'name', '')) not between 1 and 20 then raise exception 'Pferd: Name braucht 1 bis 20 Zeichen'; end if;
      if coalesce(e->>'color', '') !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Pferd: Farbe muss wie #e53935 aussehen'; end if;
      if (e->>'weight')::numeric <= 0 then raise exception 'Pferd: Chance muss grösser als 0 sein'; end if;
      if (e->>'odds')::numeric < 1.01 or (e->>'odds')::numeric > 1000 then raise exception 'Pferd: Quote muss zwischen 1.01 und 1000 liegen'; end if;
      wsum := wsum + (e->>'weight')::numeric;
    end loop;
    if abs(wsum - 100) > 0.01 then raise exception 'Pferde: Die Chancen ergeben % Prozent, sie müssen 100 ergeben', wsum; end if;
  exception when invalid_text_representation or numeric_value_out_of_range or null_value_not_allowed then
    raise exception 'Ungültige Eingaben';
  end;
  update public.game_settings set
    pool_threshold = (p_settings->>'pool_threshold')::int,
    pool_strength = (p_settings->>'pool_strength')::numeric,
    wheel_stake = (p_settings->>'wheel_stake')::int,
    wheel_fields = p_settings->'wheel_fields',
    chest_stake = (p_settings->>'chest_stake')::int,
    chest_bombs = nb,
    chest_values = p_settings->'chest_values',
    slot_symbols = p_settings->'slot_symbols',
    bj_blackjack_payout = (p_settings->>'bj_blackjack_payout')::numeric,
    bj_win_payout = (p_settings->>'bj_win_payout')::numeric,
    bj_soft17 = (p_settings->>'bj_soft17')::boolean,
    race_horses = p_settings->'race_horses'
  where id = 1;
end $$;

-- Kontostand einer Person setzen (p_mode = 'set') oder ändern (p_mode = 'add', auch negativ).
-- Die Bank gleicht automatisch aus, die Gesamtmenge bleibt 10000.
create or replace function public.admin_set_balance(p_user uuid, p_mode text, p_amount bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare t public.profiles%rowtype; neu bigint; delta bigint;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if p_mode not in ('set', 'add') or p_amount is null or abs(p_amount) > 1000000 then raise exception 'Ungültige Eingabe'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into t from public.profiles where id = p_user for update;
  if not found then raise exception 'Konto nicht gefunden'; end if;
  neu := case when p_mode = 'set' then p_amount else t.balance + p_amount end;
  if neu < 0 then raise exception 'Der Kontostand kann nicht negativ sein'; end if;
  delta := neu - t.balance;
  if not (t.is_admin or t.is_test) and delta > public.bank_balance() then
    raise exception 'Die Bank hat nicht genug Coins (Bank: %)', public.bank_balance();
  end if;
  update public.profiles set balance = neu where id = p_user;
  perform public.log_tx(p_user, delta, 'admin_adjust');
  return neu;
end $$;

-- =====================================================================
-- 13) Rechte: Spieler dürfen nur die öffentlichen Funktionen aufrufen
-- =====================================================================
revoke all on function public.bank_balance() from public, anon, authenticated;
revoke all on function public.bank_factor() from public, anon, authenticated;
revoke all on function public.payout_cap(boolean, bigint) from public, anon, authenticated;
revoke all on function public.log_tx(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.require_player(text) from public, anon, authenticated;
revoke all on function public.slot_draw(numeric[]) from public, anon, authenticated;
revoke all on function public.bj_total(int[]) from public, anon, authenticated;
revoke all on function public.bj_soft(int[]) from public, anon, authenticated;
revoke all on function public.bj_view(public.blackjack_games) from public, anon, authenticated;
revoke all on function public.bj_settle(bigint, text) from public, anon, authenticated;
revoke all on function public.bj_run_dealer(bigint) from public, anon, authenticated;
revoke all on function public.bj_finish(bigint) from public, anon, authenticated;
revoke all on function public.race_t(date, int, int) from public, anon, authenticated;
revoke all on function public.ensure_race(date) from public, anon, authenticated;
revoke all on function public.race_settle() from public, anon, authenticated;

revoke all on function public.claim_daily() from public, anon;
revoke all on function public.send_coins(text, int) from public, anon;
revoke all on function public.decide_request(bigint, boolean) from public, anon;
revoke all on function public.leaderboard() from public, anon;
revoke all on function public.save_my_settings(jsonb) from public, anon;
revoke all on function public.game_info() from public, anon;
revoke all on function public.wheel_spin() from public, anon;
revoke all on function public.chest_start() from public, anon;
revoke all on function public.chest_open(bigint, int) from public, anon;
revoke all on function public.chest_cashout(bigint) from public, anon;
revoke all on function public.slot_spin(int) from public, anon;
revoke all on function public.bj_current() from public, anon;
revoke all on function public.bj_start(int) from public, anon;
revoke all on function public.bj_hit(bigint) from public, anon;
revoke all on function public.bj_stand(bigint) from public, anon;
revoke all on function public.bj_double(bigint) from public, anon;
revoke all on function public.race_state() from public, anon;
revoke all on function public.place_bet(int, int) from public, anon;
revoke all on function public.admin_game_overview() from public, anon;
revoke all on function public.admin_save_settings(jsonb) from public, anon;
revoke all on function public.admin_set_balance(uuid, text, bigint) from public, anon;

grant execute on function public.claim_daily() to authenticated;
grant execute on function public.send_coins(text, int) to authenticated;
grant execute on function public.decide_request(bigint, boolean) to authenticated;
grant execute on function public.leaderboard() to authenticated;
grant execute on function public.save_my_settings(jsonb) to authenticated;
grant execute on function public.game_info() to authenticated;
grant execute on function public.wheel_spin() to authenticated;
grant execute on function public.chest_start() to authenticated;
grant execute on function public.chest_open(bigint, int) to authenticated;
grant execute on function public.chest_cashout(bigint) to authenticated;
grant execute on function public.slot_spin(int) to authenticated;
grant execute on function public.bj_current() to authenticated;
grant execute on function public.bj_start(int) to authenticated;
grant execute on function public.bj_hit(bigint) to authenticated;
grant execute on function public.bj_stand(bigint) to authenticated;
grant execute on function public.bj_double(bigint) to authenticated;
grant execute on function public.race_state() to authenticated;
grant execute on function public.place_bet(int, int) to authenticated;
grant execute on function public.admin_game_overview() to authenticated;
grant execute on function public.admin_save_settings(jsonb) to authenticated;
grant execute on function public.admin_set_balance(uuid, text, bigint) to authenticated;

-- Alte Pool-Funktionen entfernen (ersetzt durch die Bank)
drop function if exists public.game_pool();
drop function if exists public.pool_factor();

-- =====================================================================
-- 14) Test-Konto (500 Coins, nicht Teil der Bank, überall Zugriff)
-- =====================================================================
-- a) In Supabase: Authentication > Users > "Add user" (E-Mail + Passwort, "Auto Confirm User" ankreuzen).
-- b) Dann diese Zeile mit der E-Mail des Test-Kontos ausführen (zuerst die zwei Minuszeichen vorne entfernen):
-- update public.profiles set is_test = true, balance = 500 where email = 'test@example.com';

-- =====================================================================
-- 15) Optional: Rennen auch ohne Seitenbesuch auszahlen (pg_cron)
-- =====================================================================
-- Die Auszahlung passiert sowieso automatisch, sobald jemand die Seite öffnet.
-- Wer es zusätzlich geplant will: Database > Extensions > "pg_cron" einschalten, dann (Minuszeichen entfernen):
-- select cron.schedule('race-settle', '*/10 * * * *', $$select public.race_settle()$$);
