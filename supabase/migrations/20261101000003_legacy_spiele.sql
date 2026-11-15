-- SpassCoin: Spiele (Truhen + Glücksrad), Coin-Pool und Spiele-Einstellungen
-- Im Supabase "SQL Editor" einfügen und "Run" klicken.
-- Voraussetzung: supabase-setup.sql und supabase-erweiterung.sql wurden schon ausgeführt.

-- 1) Transaktionsarten erweitern (Spiele erscheinen im Verlauf)
alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check
  check (kind in ('transfer','reward','grant','game_chest','game_wheel'));

-- 2) Einstellungen (genau eine Zeile)
create table if not exists public.game_settings (
  id int primary key default 1 check (id = 1),
  total_coins int not null default 1000 check (total_coins between 1 and 1000000),
  pool_threshold int not null default 70 check (pool_threshold between 1 and 99),
  pool_strength numeric not null default 5 check (pool_strength between 0 and 30),
  wheel_stake int not null default 1 check (wheel_stake between 1 and 1000),
  wheel_fields jsonb not null,
  chest_stake int not null default 1 check (chest_stake between 1 and 1000),
  chest_bombs int not null default 5 check (chest_bombs between 1 and 11),
  chest_values jsonb not null default '[1,1,1,1,2,2,3]'
);
-- Glücksrad-Felder: payout = Coins, die der Spieler zurückbekommt (0 = Niete, gleich wie Einsatz = ±0)
insert into public.game_settings (id, wheel_fields) values (1, '[
  {"payout":0,"weight":15},{"payout":2,"weight":13},{"payout":0,"weight":15},
  {"payout":1,"weight":10},{"payout":3,"weight":5},{"payout":0,"weight":15},
  {"payout":2,"weight":12},{"payout":1,"weight":10},{"payout":3,"weight":5}
]'::jsonb) on conflict (id) do nothing;

-- 3) Tabelle für laufende Truhen-Spiele
create table if not exists public.chest_games (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  stake int not null,
  layout int[] not null,                -- Inhalt der 12 Truhen (-1 = Bombe), nur serverseitig
  opened int[] not null default '{}',
  running int not null default 0,
  status text not null default 'active' check (status in ('active','cashed','bomb')),
  created_at timestamptz not null default now()
);

-- Niemand darf diese Tabellen direkt lesen oder schreiben, alles läuft über Funktionen
alter table public.game_settings enable row level security;
alter table public.chest_games enable row level security;
revoke all on public.game_settings, public.chest_games from anon, authenticated;

-- 4) Interne Hilfsfunktionen (für Spieler NICHT aufrufbar)

-- Pool = Gesamtmenge minus alle Coins auf Nicht-Admin-Konten (nie unter 0)
create or replace function public.game_pool() returns bigint
language sql security definer set search_path = public stable as $$
  select greatest(0, (select total_coins from public.game_settings where id = 1)
         - coalesce((select sum(balance) from public.profiles where not is_admin), 0))::bigint
$$;

-- Faktor -1 (Pool leer) bis +1 (Pool voll); 0 genau bei der Schwelle
create or replace function public.pool_factor() returns numeric
language plpgsql security definer set search_path = public stable as $$
declare s public.game_settings%rowtype; pct numeric;
begin
  select * into s from public.game_settings where id = 1;
  pct := public.game_pool()::numeric / s.total_coins * 100;
  if pct >= s.pool_threshold then
    return least(1, (pct - s.pool_threshold) / (100 - s.pool_threshold));
  else
    return -least(1, (s.pool_threshold - pct) / s.pool_threshold);
  end if;
end $$;

-- Wahrscheinlichkeiten leicht verschieben: p_d > 0 = von Nieten zu Gewinnen, p_d < 0 = umgekehrt
create or replace function public.adjust_weights(p_pay numeric[], p_w numeric[], p_stake numeric, p_d numeric)
returns numeric[] language plpgsql immutable as $$
declare n int := coalesce(array_length(p_w, 1), 0); w numeric[] := p_w; lw numeric := 0; ww numeric := 0; mv numeric; i int;
begin
  for i in 1..n loop
    if p_pay[i] < p_stake then lw := lw + p_w[i];
    elsif p_pay[i] > p_stake then ww := ww + p_w[i]; end if;
  end loop;
  if lw > 0 and ww > 0 and p_d > 0 then
    mv := least(p_d, lw);
    for i in 1..n loop
      if p_pay[i] < p_stake then w[i] := p_w[i] - mv * p_w[i] / lw;
      elsif p_pay[i] > p_stake then w[i] := p_w[i] + mv * p_w[i] / ww; end if;
    end loop;
  elsif lw > 0 and ww > 0 and p_d < 0 then
    mv := least(-p_d, ww);
    for i in 1..n loop
      if p_pay[i] < p_stake then w[i] := p_w[i] + mv * p_w[i] / lw;
      elsif p_pay[i] > p_stake then w[i] := p_w[i] - mv * p_w[i] / ww; end if;
    end loop;
  end if;
  return w;
end $$;

-- 5) Spiel-Funktionen -------------------------------------------------------

-- Infos für Spieler (OHNE Pool-Stand)
create or replace function public.game_info() returns json
language plpgsql security definer set search_path = public stable as $$
declare s public.game_settings%rowtype;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  select * into s from public.game_settings where id = 1;
  return json_build_object('wheel_stake', s.wheel_stake, 'chest_stake', s.chest_stake, 'wheel_fields', s.wheel_fields);
end $$;

-- Glücksrad drehen
create or replace function public.wheel_spin() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); s public.game_settings%rowtype; p public.profiles%rowtype;
        n int; pay numeric[] := '{}'; w numeric[] := '{}'; i int; r numeric; acc numeric := 0; idx int := 0;
        payout int; credit int; net int; neu bigint;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into s from public.game_settings where id = 1 for update;
  select * into p from public.profiles where id = me for update;
  if p.is_admin then raise exception 'Admins können nicht mitspielen (Admin-Coins zählen nicht zum Pool)'; end if;
  if p.balance < s.wheel_stake then raise exception 'Nicht genug Coins'; end if;
  n := jsonb_array_length(s.wheel_fields);
  for i in 0..n-1 loop
    pay := pay || (s.wheel_fields->i->>'payout')::numeric;
    w := w || (s.wheel_fields->i->>'weight')::numeric;
  end loop;
  w := public.adjust_weights(pay, w, s.wheel_stake, s.pool_strength * public.pool_factor());
  r := random() * 100;
  for i in 1..n loop
    acc := acc + w[i];
    if r < acc then idx := i; exit; end if;
  end loop;
  if idx = 0 then idx := n; end if;
  payout := pay[idx]::int;
  update public.profiles set balance = balance - s.wheel_stake where id = me;
  credit := least(payout, public.game_pool())::int;      -- Gewinn nie grösser als der Pool
  update public.profiles set balance = balance + credit where id = me returning balance into neu;
  net := credit - s.wheel_stake;
  if net > 0 then insert into public.transactions (sender_id, receiver_id, amount, kind) values (null, me, net, 'game_wheel');
  elsif net < 0 then insert into public.transactions (sender_id, receiver_id, amount, kind) values (me, null, -net, 'game_wheel'); end if;
  return json_build_object('index', idx - 1, 'payout', credit, 'stake', s.wheel_stake, 'net', net, 'balance', neu);
end $$;

-- Truhen: laufendes Spiel abfragen (zum Weiterspielen nach Neuladen)
create or replace function public.chest_current() returns json
language plpgsql security definer set search_path = public stable as $$
declare g public.chest_games%rowtype; op json;
begin
  select * into g from public.chest_games where user_id = auth.uid() and status = 'active' order by id desc limit 1;
  if not found then return null; end if;
  select coalesce(json_agg(json_build_object('index', o, 'value', g.layout[o + 1]) order by o), '[]'::json)
    into op from unnest(g.opened) o;
  return json_build_object('id', g.id, 'stake', g.stake, 'opened', op, 'running', g.running);
end $$;

-- Truhen: neues Spiel starten (Einsatz wird sofort abgezogen)
create or replace function public.chest_start() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); s public.game_settings%rowtype; p public.profiles%rowtype;
        vals int[]; b int; d numeric; k int; arr int[]; lay int[]; prev int[]; neu bigint; gid bigint; i int;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  select * into s from public.game_settings where id = 1 for update;
  select * into p from public.profiles where id = me for update;
  if p.is_admin then raise exception 'Admins können nicht mitspielen (Admin-Coins zählen nicht zum Pool)'; end if;
  if exists (select 1 from public.chest_games where user_id = me and status = 'active') then
    raise exception 'Du hast noch ein offenes Spiel';
  end if;
  if p.balance < s.chest_stake then raise exception 'Nicht genug Coins'; end if;
  select array_agg(x::int order by x::int) into vals from jsonb_array_elements_text(s.chest_values) x;
  b := s.chest_bombs;
  -- Chancen leicht an den Pool anpassen (Pool voll: weniger Bomben, Pool leer: mehr Bomben)
  d := s.pool_strength / 100 * 12 * public.pool_factor();
  k := trunc(abs(d))::int + case when random() < abs(d) - trunc(abs(d)) then 1 else 0 end;
  if d > 0 then
    k := least(k, b - 1);
    b := b - k;
    for i in 1..k loop vals := vals || vals[1]; end loop;      -- Bombe wird zu kleinster Truhe
  elsif d < 0 then
    k := least(k, array_length(vals, 1) - 1);
    for i in 1..k loop vals := vals[1:array_length(vals, 1) - 1]; end loop;  -- wertvollste Truhe fällt weg
    b := b + k;
  end if;
  arr := vals;
  for i in 1..b loop arr := arr || (-1); end loop;
  select array_agg(x order by random()) into lay from unnest(arr) x;   -- zufällige Anordnung (nur Server)
  select array_agg(x order by x desc) into prev from unnest(arr) x;    -- Vorschau ohne Positionen
  update public.profiles set balance = balance - s.chest_stake where id = me returning balance into neu;
  insert into public.chest_games (user_id, stake, layout) values (me, s.chest_stake, lay) returning id into gid;
  return json_build_object('id', gid, 'stake', s.chest_stake, 'preview', prev, 'balance', neu);
end $$;

-- Truhen: eine Truhe öffnen (p_index 0 bis 11)
create or replace function public.chest_open(p_game bigint, p_index int) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g public.chest_games%rowtype; v int; run int; coins int;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.chest_games where id = p_game and user_id = me for update;
  if not found or g.status <> 'active' then raise exception 'Kein offenes Spiel'; end if;
  if p_index is null or p_index < 0 or p_index > 11 then raise exception 'Ungültige Truhe'; end if;
  if p_index = any(g.opened) then raise exception 'Diese Truhe ist schon offen'; end if;
  v := g.layout[p_index + 1];
  if v < 0 then
    update public.chest_games set status = 'bomb', running = 0 where id = g.id;
    insert into public.transactions (sender_id, receiver_id, amount, kind) values (me, null, g.stake, 'game_chest');
    return json_build_object('result', 'bomb', 'value', -1, 'running', 0, 'layout', g.layout);
  end if;
  -- Gewinn zählt nur bis zum Pool-Rest
  run := greatest(g.running, least(g.running + v, public.game_pool()::int));
  update public.chest_games set opened = opened || p_index, running = run where id = g.id;
  select count(*) into coins from unnest(g.layout) x where x > 0;
  return json_build_object('result', 'coin', 'value', v, 'running', run,
                           'all_open', coalesce(array_length(g.opened, 1), 0) + 1 >= coins);
end $$;

-- Truhen: aussteigen und Gewinn aufs Konto bekommen
create or replace function public.chest_cashout(p_game bigint) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g public.chest_games%rowtype; credit int; net int; neu bigint;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select * into g from public.chest_games where id = p_game and user_id = me for update;
  if not found or g.status <> 'active' then raise exception 'Kein offenes Spiel'; end if;
  if coalesce(array_length(g.opened, 1), 0) = 0 then raise exception 'Öffne zuerst mindestens eine Truhe'; end if;
  perform 1 from public.profiles where id = me for update;
  credit := least(g.running, public.game_pool())::int;
  update public.profiles set balance = balance + credit where id = me returning balance into neu;
  update public.chest_games set status = 'cashed' where id = g.id;
  net := credit - g.stake;
  if net > 0 then insert into public.transactions (sender_id, receiver_id, amount, kind) values (null, me, net, 'game_chest');
  elsif net < 0 then insert into public.transactions (sender_id, receiver_id, amount, kind) values (me, null, -net, 'game_chest'); end if;
  return json_build_object('credit', credit, 'net', net, 'balance', neu, 'layout', g.layout);
end $$;

-- 6) Admin-Funktionen -------------------------------------------------------

-- Pool-Stand und alle Einstellungen (nur Admins)
create or replace function public.admin_game_overview() returns json
language plpgsql security definer set search_path = public stable as $$
declare s public.game_settings%rowtype; circ bigint; pool bigint;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  select * into s from public.game_settings where id = 1;
  select coalesce(sum(balance), 0) into circ from public.profiles where not is_admin;
  pool := public.game_pool();
  return json_build_object('total', s.total_coins, 'circulating', circ, 'pool', pool,
    'pool_pct', round(pool::numeric / s.total_coins * 100, 1),
    'settings', json_build_object('total_coins', s.total_coins, 'pool_threshold', s.pool_threshold,
      'pool_strength', s.pool_strength, 'wheel_stake', s.wheel_stake, 'wheel_fields', s.wheel_fields,
      'chest_stake', s.chest_stake, 'chest_bombs', s.chest_bombs, 'chest_values', s.chest_values));
end $$;

-- Einstellungen speichern (mit Prüfung, nur Admins)
create or replace function public.admin_save_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e jsonb; wsum numeric := 0; nb int; cnt int;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  begin
    if (p_settings->>'total_coins')::int not between 1 and 1000000 then raise exception 'Gesamtmenge muss zwischen 1 und 1000000 liegen'; end if;
    if (p_settings->>'pool_threshold')::int not between 1 and 99 then raise exception 'Pool-Schwelle muss zwischen 1 und 99 Prozent liegen'; end if;
    if (p_settings->>'pool_strength')::numeric not between 0 and 30 then raise exception 'Stärke der Anpassung muss zwischen 0 und 30 liegen'; end if;
    if (p_settings->>'wheel_stake')::int not between 1 and 1000 then raise exception 'Einsatz Glücksrad muss zwischen 1 und 1000 liegen'; end if;
    if (p_settings->>'chest_stake')::int not between 1 and 1000 then raise exception 'Einsatz Truhen muss zwischen 1 und 1000 liegen'; end if;
    nb := (p_settings->>'chest_bombs')::int;
    if nb not between 1 and 11 then raise exception 'Anzahl Bomben muss zwischen 1 und 11 liegen'; end if;
    if jsonb_typeof(p_settings->'chest_values') <> 'array' or jsonb_array_length(p_settings->'chest_values') <> 12 - nb then
      raise exception 'Anzahl Truhenwerte plus Bomben muss genau 12 ergeben';
    end if;
    for e in select * from jsonb_array_elements(p_settings->'chest_values') loop
      if (e #>> '{}')::int not between 1 and 1000 then raise exception 'Truhenwerte müssen zwischen 1 und 1000 liegen'; end if;
    end loop;
    if jsonb_typeof(p_settings->'wheel_fields') <> 'array' then raise exception 'Felder fehlen'; end if;
    cnt := jsonb_array_length(p_settings->'wheel_fields');
    if cnt not between 2 and 20 then raise exception 'Das Glücksrad braucht 2 bis 20 Felder'; end if;
    for e in select * from jsonb_array_elements(p_settings->'wheel_fields') loop
      if (e->>'payout')::int not between 0 and 1000 then raise exception 'Auszahlung muss zwischen 0 und 1000 liegen'; end if;
      if (e->>'weight')::numeric <= 0 then raise exception 'Wahrscheinlichkeit muss grösser als 0 sein'; end if;
      wsum := wsum + (e->>'weight')::numeric;
    end loop;
    if abs(wsum - 100) > 0.01 then raise exception 'Die Wahrscheinlichkeiten ergeben % Prozent, sie müssen 100 ergeben', wsum; end if;
  exception when invalid_text_representation or numeric_value_out_of_range or null_value_not_allowed then
    raise exception 'Ungültige Eingaben';
  end;
  update public.game_settings set
    total_coins = (p_settings->>'total_coins')::int,
    pool_threshold = (p_settings->>'pool_threshold')::int,
    pool_strength = (p_settings->>'pool_strength')::numeric,
    wheel_stake = (p_settings->>'wheel_stake')::int,
    wheel_fields = p_settings->'wheel_fields',
    chest_stake = (p_settings->>'chest_stake')::int,
    chest_bombs = nb,
    chest_values = p_settings->'chest_values'
  where id = 1;
end $$;

-- 7) Wer darf was: Spieler nur die Spiel-Funktionen, Pool-Funktionen bleiben intern
revoke all on function public.game_pool() from public, anon, authenticated;
revoke all on function public.pool_factor() from public, anon, authenticated;
revoke all on function public.adjust_weights(numeric[], numeric[], numeric, numeric) from public, anon, authenticated;
revoke all on function public.game_info() from public, anon;
revoke all on function public.wheel_spin() from public, anon;
revoke all on function public.chest_current() from public, anon;
revoke all on function public.chest_start() from public, anon;
revoke all on function public.chest_open(bigint, int) from public, anon;
revoke all on function public.chest_cashout(bigint) from public, anon;
revoke all on function public.admin_game_overview() from public, anon;
revoke all on function public.admin_save_settings(jsonb) from public, anon;
grant execute on function public.game_info() to authenticated;
grant execute on function public.wheel_spin() to authenticated;
grant execute on function public.chest_current() to authenticated;
grant execute on function public.chest_start() to authenticated;
grant execute on function public.chest_open(bigint, int) to authenticated;
grant execute on function public.chest_cashout(bigint) to authenticated;
grant execute on function public.admin_game_overview() to authenticated;
grant execute on function public.admin_save_settings(jsonb) to authenticated;
