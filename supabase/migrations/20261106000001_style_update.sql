-- SpassCoin Style-Update: Gesamtmenge, Coin-Bilanz mit allen Transaktionen, Symbole und Avatare ohne Emojis

create or replace function public.admin_set_total(p_total int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare circ bigint; inv bigint;
begin
  if not public.is_admin() then raise exception 'Nur für Admins'; end if;
  if p_total is null or p_total < 1 or p_total > 1000000 then raise exception 'Die Gesamtmenge muss zwischen 1 und 1000000 liegen'; end if;
  perform 1 from public.game_settings where id = 1 for update;
  select coalesce(sum(balance), 0) into circ from public.profiles where not is_admin and not is_test;
  select coalesce(sum(h.cost), 0) into inv from public.stock_holdings h join public.profiles p on p.id = h.user_id where not p.is_admin and not p.is_test;
  if p_total < circ + inv then raise exception 'Zu klein: % Coins sind schon bei Spielern oder in Aktien', circ + inv; end if;
  update public.game_settings set total_coins = p_total where id = 1;
  return jsonb_build_object('total', p_total, 'bank', p_total - circ - inv);
end $$;
revoke all on function public.admin_set_total(int) from public, anon;
grant execute on function public.admin_set_total(int) to authenticated;

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
           when 'net' then coalesce(t.net, 0)
           when 'wins' then case when p_period = 'all' then coalesce(ps.wins, 0) else coalesce(g.wins, 0) end
           else case when p_period = 'all' then coalesce(ps.rounds, 0) else coalesce(g.rounds, 0) end
         end)::bigint v
      from public.profiles p
      left join public.player_stats ps on ps.user_id = p.id
      left join (select user_id, count(*) filter (where win) wins, count(*) rounds
                 from public.game_rounds where p_period <> 'all' and p_cat <> 'net' and created_at >= ts group by user_id) g on g.user_id = p.id
      left join (select q.uid, sum(q.v) net from (
                   select receiver_id uid, amount v from public.transactions
                    where p_cat = 'net' and receiver_id is not null and kind not in ('stock_buy', 'stock_sell') and (p_period = 'all' or created_at >= ts)
                   union all
                   select sender_id uid, -amount v from public.transactions
                    where p_cat = 'net' and sender_id is not null and kind not in ('stock_buy', 'stock_sell') and (p_period = 'all' or created_at >= ts)
                 ) q group by q.uid) t on t.uid = p.id
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

create or replace function public.get_profile(p_username text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); pr public.profiles%rowtype; pp public.player_profiles%rowtype; st public.player_stats%rowtype;
        rk int; normal boolean; inc bigint; outc bigint;
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
  select coalesce(sum(case when receiver_id = pr.id then amount end), 0), coalesce(sum(case when sender_id = pr.id then amount end), 0)
    into inc, outc from public.transactions
    where (receiver_id = pr.id or sender_id = pr.id) and kind not in ('stock_buy', 'stock_sell');
  return jsonb_build_object('username', pr.username, 'code', pr.code, 'joined', pr.created_at, 'is_me', pr.id = me,
    'avatar', pp.avatar, 'frame', pp.frame, 'color', pp.color, 'background', pp.background,
    'name_color', pp.name_color, 'rank_effect', pp.rank_effect, 'rank', case when normal then rk else null end,
    'rounds', coalesce(st.rounds, 0), 'wins', coalesce(st.wins, 0), 'losses', coalesce(st.losses, 0),
    'earned', inc, 'spent', outc, 'net', inc - outc);
end $$;

update public.game_settings set slot_symbols = (
  select jsonb_agg(jsonb_set(e, '{symbol}', to_jsonb(coalesce((array['●','■','▲','◆','★','7'])[ord::int], e->>'symbol'))) order by ord)
  from jsonb_array_elements(slot_symbols) with ordinality as t(e, ord)) where id = 1;

update public.app_config set value = jsonb_set(value, '{symbols}', (
  select jsonb_agg(jsonb_set(e, '{icon}', to_jsonb(coalesce((array['●','■','▲','◆','★','✚','✦','▼'])[ord::int], e->>'icon'))) order by ord)
  from jsonb_array_elements(value->'symbols') with ordinality as t(e, ord))) where key = 'scratch';

update public.shop_items i set name = v.n, descr = 'Avatar ' || v.n
from (values
  ('avatar-01', 'Kreis Blau'),
  ('avatar-02', 'Ring Blau'),
  ('avatar-03', 'Quadrat Blau'),
  ('avatar-04', 'Raute Blau'),
  ('avatar-05', 'Dreieck Blau'),
  ('avatar-06', 'Sechseck Blau'),
  ('avatar-07', 'Kreuz Blau'),
  ('avatar-08', 'Streifen Blau'),
  ('avatar-09', 'Punkte Blau'),
  ('avatar-10', 'Halbkreis Blau'),
  ('avatar-11', 'Kreis Grün'),
  ('avatar-12', 'Ring Grün'),
  ('avatar-13', 'Quadrat Grün'),
  ('avatar-14', 'Raute Grün'),
  ('avatar-15', 'Dreieck Grün'),
  ('avatar-16', 'Sechseck Grün'),
  ('avatar-17', 'Kreuz Grün'),
  ('avatar-18', 'Streifen Grün'),
  ('avatar-19', 'Punkte Grün'),
  ('avatar-20', 'Halbkreis Grün'),
  ('avatar-21', 'Kreis Violett'),
  ('avatar-22', 'Ring Violett'),
  ('avatar-23', 'Quadrat Violett'),
  ('avatar-24', 'Raute Violett'),
  ('avatar-25', 'Dreieck Violett'),
  ('avatar-26', 'Sechseck Violett'),
  ('avatar-27', 'Kreuz Violett'),
  ('avatar-28', 'Streifen Violett'),
  ('avatar-29', 'Punkte Violett'),
  ('avatar-30', 'Halbkreis Violett')
) as v(id, n) where i.id = v.id;
