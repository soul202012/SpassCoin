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
