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
