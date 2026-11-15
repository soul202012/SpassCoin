-- SpassCoin: Einzelne Transaktionen leben nur noch 24 Stunden.
-- Damit Rangliste, Profil-Statistik und Admin-Zahlen trotzdem stimmen, werden sie vorher
-- in Tagessummen (tx_daily) zusammengefasst. Der Kontoverlauf kommt aus Punkten alle 5 Stunden (balance_points).

-- 1) Tagessummen pro Spieler, Tag (Schweizer Zeit) und Art
create table if not exists public.tx_daily (
  user_id uuid not null,
  day date not null,
  kind text not null,
  amount_in bigint not null default 0,
  amount_out bigint not null default 0,
  primary key (user_id, day, kind)
);
create index if not exists tx_daily_day_idx on public.tx_daily (day);
alter table public.tx_daily enable row level security;

insert into public.tx_daily (user_id, day, kind, amount_in, amount_out)
select uid, d, k, sum(i), sum(o) from (
  select receiver_id uid, (created_at at time zone 'Europe/Zurich')::date d, coalesce(kind, '') k, amount i, 0::bigint o
    from public.transactions where receiver_id is not null
  union all
  select sender_id, (created_at at time zone 'Europe/Zurich')::date, coalesce(kind, ''), 0, amount
    from public.transactions where sender_id is not null
) q group by 1, 2, 3
on conflict (user_id, day, kind) do nothing;

create or replace function public.tx_daily_add() returns trigger
language plpgsql security definer set search_path = public as $$
declare d date := (coalesce(new.created_at, now()) at time zone 'Europe/Zurich')::date; k text := coalesce(new.kind, '');
begin
  if new.receiver_id is not null then
    insert into public.tx_daily values (new.receiver_id, d, k, new.amount, 0)
    on conflict (user_id, day, kind) do update set amount_in = public.tx_daily.amount_in + excluded.amount_in;
  end if;
  if new.sender_id is not null then
    insert into public.tx_daily values (new.sender_id, d, k, 0, new.amount)
    on conflict (user_id, day, kind) do update set amount_out = public.tx_daily.amount_out + excluded.amount_out;
  end if;
  return new;
end $$;
drop trigger if exists tx_daily_add on public.transactions;
create trigger tx_daily_add after insert on public.transactions for each row execute function public.tx_daily_add();

-- 2) Kontostand alle 5 Stunden (festes Raster ab 1970, also immer genau 5 h Abstand)
create table if not exists public.balance_points (
  user_id uuid not null,
  ts timestamptz not null,
  balance bigint not null,
  primary key (user_id, ts)
);
alter table public.balance_points enable row level security;

-- Alte Punkte aus den bisherigen Transaktionen zurückrechnen: Stand jetzt minus alles, was danach passiert ist
insert into public.balance_points (user_id, ts, balance)
select p.id, g.ts,
       p.balance - coalesce((select sum(case when t.receiver_id = p.id then t.amount else -t.amount end)
                               from public.transactions t
                              where (t.receiver_id = p.id or t.sender_id = p.id) and t.created_at > g.ts), 0)
from public.profiles p
cross join lateral generate_series(
  to_timestamp(ceil(extract(epoch from coalesce(
    (select min(t.created_at) from public.transactions t where t.receiver_id = p.id or t.sender_id = p.id), p.created_at)) / 18000) * 18000),
  to_timestamp(floor(extract(epoch from now()) / 18000) * 18000),
  interval '5 hours') g(ts)
on conflict (user_id, ts) do nothing;

create or replace function public.snapshot_balances() returns void
language sql security definer set search_path = public as $$
  insert into public.balance_points (user_id, ts, balance)
  select id, to_timestamp(floor(extract(epoch from now()) / 18000) * 18000), balance from public.profiles
  on conflict (user_id, ts) do nothing;
$$;
revoke execute on function public.snapshot_balances() from public, anon, authenticated;

-- 3) Funktionen auf die neuen Tabellen umstellen
create or replace function public.balance_history(p_username text, p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare u uuid; cur bigint; since timestamptz;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  select id, balance into u, cur from public.profiles where lower(username) = lower(p_username);
  if u is null then raise exception 'Spieler nicht gefunden'; end if;
  since := now() - make_interval(days => case when p_days > 0 then p_days else 365 end);
  return (
    select coalesce(jsonb_agg(jsonb_build_object('ts', q.ts, 'balance', q.balance) order by q.ts), '[]'::jsonb)
    from (select ts, balance from public.balance_points where user_id = u and ts >= since
          union all select now(), cur) q
  );
end $function$;

create or replace function public.get_profile(p_username text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
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
  select coalesce(sum(amount_in), 0), coalesce(sum(amount_out), 0) into inc, outc
    from public.tx_daily where user_id = pr.id and kind not in ('stock_buy', 'stock_sell');
  return jsonb_build_object('username', pr.username, 'code', pr.code, 'joined', pr.created_at, 'is_me', pr.id = me,
    'avatar', pp.avatar, 'frame', pp.frame, 'color', pp.color, 'background', pp.background,
    'name_color', pp.name_color, 'rank_effect', pp.rank_effect, 'rank', case when normal then rk else null end,
    'rounds', coalesce(st.rounds, 0), 'wins', coalesce(st.wins, 0), 'losses', coalesce(st.losses, 0),
    'earned', inc, 'spent', outc, 'net', inc - outc);
end $function$;

create or replace function public.leaderboard_v2(p_period text, p_cat text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
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
      left join (select user_id uid, sum(amount_in - amount_out) net from public.tx_daily
                  where p_cat = 'net' and kind not in ('stock_buy', 'stock_sell') and (p_period = 'all' or day >= start_day)
                  group by user_id) t on t.uid = p.id
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
end $function$;

create or replace function public.admin_economy()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
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
        'streak', coalesce(sum(t.amount_in) filter (where t.kind = 'reward'), 0),
        'missions', coalesce(sum(t.amount_in) filter (where t.kind = 'mission'), 0),
        'rescue', coalesce(sum(t.amount_in) filter (where t.kind = 'rescue'), 0),
        'shop_income', 0)
      from public.tx_daily t join public.profiles p on p.id = t.user_id where not p.is_admin and not p.is_test),
    'shop_income', (select coalesce(sum(t.amount_out), 0) from public.tx_daily t join public.profiles p on p.id = t.user_id
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
end $function$;

-- 4) Zeitpläne: Kontostand-Punkt jede Stunde prüfen (schreibt nur einmal pro 5-h-Raster)
select cron.schedule('spasscoin-balance-points', '1 * * * *', 'select public.snapshot_balances()');

-- 5) Einzelne Transaktionen jede Minute löschen, sobald sie älter als 24 Stunden sind (Summen bleiben in tx_daily)
select cron.schedule('spasscoin-tx-cleanup', '* * * * *', $$delete from public.transactions where created_at < now() - interval '24 hours'$$);
