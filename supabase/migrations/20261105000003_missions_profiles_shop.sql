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
