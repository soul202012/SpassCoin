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
