-- SpassCoin: viele neue Missionen mit lohnenden Belohnungen
-- Belohnungen: leicht 10-15, mittel 25-40, schwer 70-120 Coins (vorher 2 bis 10)

-- 0) Neue Missionsarten erlauben (Prüfregel der Tabelle und Admin-Speichern)
alter table public.mission_defs drop constraint if exists mission_defs_kind_check;
alter table public.mission_defs add constraint mission_defs_kind_check check (kind = any (array['rounds_any','rounds_game','wins_any','wins_game','win_streak_game','win_streak_any','distinct_games','coins_won','coins_staked','big_win_any','big_win_game']));
do $$
declare def text;
begin
  select pg_get_functiondef('public.admin_save_mission'::regproc) into def;
  def := replace(def, $q$'win_streak_any', 'distinct_games') then raise exception 'Unbekannte Missionsart'$q$, $q$'win_streak_any', 'distinct_games', 'coins_won', 'coins_staked', 'big_win_any', 'big_win_game') then raise exception 'Unbekannte Missionsart'$q$);
  def := replace(def, $q$kd in ('rounds_game', 'wins_game', 'win_streak_game') and$q$, $q$kd in ('rounds_game', 'wins_game', 'win_streak_game', 'big_win_game') and$q$);
  def := replace(def, $q$kd not in ('rounds_game', 'wins_game', 'win_streak_game') then gm := null$q$, $q$kd not in ('rounds_game', 'wins_game', 'win_streak_game', 'big_win_game') then gm := null$q$);
  def := replace(def, $q$(p_mission->>'target')::int > 1000$q$, $q$(p_mission->>'target')::int > 100000$q$);
  execute def;
end $$;
-- 1) Neue Missionsarten, die Einsatz und Auszahlung brauchen:
--    coins_won    = Summe der Netto-Gewinne (Auszahlung minus Einsatz, nur positive Runden)
--    coins_staked = Summe aller Einsätze
--    big_win_any / big_win_game = Runden mit Auszahlung von mindestens 5x Einsatz
create or replace function public.mission_extra(p_user uuid, p_game text, p_stake bigint, p_payout bigint)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := (now() at time zone 'Europe/Zurich')::date; r record; np int;
begin
  for r in select pm.mission_id, pm.progress, d.kind, d.game, d.target from public.player_missions pm
           join public.mission_defs d on d.id = pm.mission_id
           where pm.user_id = p_user and pm.day = today and not pm.completed
             and d.kind in ('coins_won', 'coins_staked', 'big_win_any', 'big_win_game') loop
    np := r.progress;
    if r.kind = 'coins_won' then np := np + greatest(p_payout - p_stake, 0)::int;
    elsif r.kind = 'coins_staked' then np := np + p_stake::int;
    elsif r.kind = 'big_win_any' then if p_stake > 0 and p_payout >= p_stake * 5 then np := np + 1; end if;
    elsif r.kind = 'big_win_game' then if r.game = p_game and p_stake > 0 and p_payout >= p_stake * 5 then np := np + 1; end if;
    end if;
    if np <> r.progress then
      update public.player_missions set progress = np, completed = (np >= r.target)
       where user_id = p_user and day = today and mission_id = r.mission_id;
    end if;
  end loop;
end $$;
revoke execute on function public.mission_extra(uuid, text, bigint, bigint) from public, anon, authenticated;

-- record_round ruft die neuen Arten zusätzlich auf
do $$
declare def text;
begin
  select pg_get_functiondef('public.record_round'::regproc) into def;
  if position('mission_extra' in def) = 0 then
    def := replace(def, 'perform public.mission_progress(p_user, p_game, w);',
                        'perform public.mission_progress(p_user, p_game, w); perform public.mission_extra(p_user, p_game, p_stake, p_payout);');
    execute def;
  end if;
end $$;

-- 2) Bestehende Missionen: fairere Belohnungen
update public.mission_defs set reward = case key
  when 'play3' then 10 when 'plinko1' then 10 when 'chest1' then 10 when 'scratch1' then 10 when 'race1' then 15
  when 'wins2' then 25 when 'diff3' then 25 when 'hilo_win' then 30 when 'poker_win' then 30 when 'play10' then 25
  when 'wheel_streak2' then 70 when 'streak3' then 90 else reward end;

-- 3) Neue Missionen
insert into public.mission_defs (key, title, descr, kind, game, target, reward, difficulty, active) values
-- leicht
('wheel3',      'Drehe dreimal am Glücksrad',              '',                              'rounds_game', 'wheel',     3,  10, 'easy', true),
('slots5',      'Drehe fünfmal die Slotmaschine',          '',                              'rounds_game', 'slots',     5,  12, 'easy', true),
('bj2',         'Spiele zwei Runden Blackjack',            '',                              'rounds_game', 'blackjack', 2,  12, 'easy', true),
('hilo2',       'Spiele zwei Runden Higher or Lower',      '',                              'rounds_game', 'hilo',      2,  10, 'easy', true),
('poker2',      'Spiele zwei Runden Video Poker',          '',                              'rounds_game', 'poker',     2,  12, 'easy', true),
('chest2',      'Spiele zwei Runden Schatzkisten',         '',                              'rounds_game', 'chest',     2,  12, 'easy', true),
('plinko5',     'Lass fünf Plinko-Kugeln fallen',          '',                              'rounds_game', 'plinko',    5,  12, 'easy', true),
('scratch3',    'Rubble drei Lose frei',                   '',                              'rounds_game', 'scratch',   3,  12, 'easy', true),
('play5',       'Spiele fünf Runden',                      'Egal welches Spiel',            'rounds_any',  null,        5,  12, 'easy', true),
('win1',        'Gewinne eine Runde',                      'Egal welches Spiel',            'wins_any',    null,        1,  10, 'easy', true),
('diff2',       'Spiele zwei verschiedene Spiele',         '',                              'distinct_games', null,     2,  10, 'easy', true),
('stake25',     'Setze insgesamt 25 Coins',                'Alle Einsätze des Tages zählen', 'coins_staked', null,      25, 12, 'easy', true),
-- mittel
('play20',      'Spiele 20 Runden',                        'Egal welches Spiel',            'rounds_any',  null,        20, 30, 'medium', true),
('wins5',       'Gewinne fünf Runden',                     'Egal welches Spiel',            'wins_any',    null,        5,  35, 'medium', true),
('diff5',       'Spiele fünf verschiedene Spiele',         '',                              'distinct_games', null,     5,  35, 'medium', true),
('bj_win2',     'Gewinne zwei Runden Blackjack',           '',                              'wins_game',   'blackjack', 2,  30, 'medium', true),
('slots_win2',  'Lande zwei Treffer an der Slotmaschine',  '',                              'wins_game',   'slots',     2,  35, 'medium', true),
('plinko_win3', 'Gewinne dreimal bei Plinko',              'Auszahlung höher als der Einsatz', 'wins_game', 'plinko',   3,  30, 'medium', true),
('scratch_win2','Gewinne mit zwei Rubbellosen',            '',                              'wins_game',   'scratch',   2,  30, 'medium', true),
('chest_win2',  'Löse zweimal Schatzkisten mit Gewinn ein','',                              'wins_game',   'chest',     2,  30, 'medium', true),
('wheel_win3',  'Gewinne dreimal am Glücksrad',            '',                              'wins_game',   'wheel',     3,  30, 'medium', true),
('earn50',      'Gewinne insgesamt 50 Coins',              'Netto-Gewinne aller Runden zählen', 'coins_won', null,      50, 35, 'medium', true),
('stake200',    'Setze insgesamt 200 Coins',               'Alle Einsätze des Tages zählen', 'coins_staked', null,      200, 30, 'medium', true),
('big1',        'Hol einen Gewinn ab 5× Einsatz',          'Egal welches Spiel',            'big_win_any', null,        1,  40, 'medium', true),
-- schwer
('streak4',     'Erreiche eine Gewinnserie von 4 Runden',  'Vier Gewinne in Folge, egal wo', 'win_streak_any', null,     4,  110, 'hard', true),
('bj_streak3',  'Gewinne dreimal in Folge Blackjack',      '',                              'win_streak_game', 'blackjack', 3, 100, 'hard', true),
('hilo_streak2','Gewinne zweimal in Folge Higher or Lower','',                              'win_streak_game', 'hilo',  2,  70, 'hard', true),
('wins12',      'Gewinne zwölf Runden',                    'Egal welches Spiel',            'wins_any',    null,        12, 80, 'hard', true),
('diff8',       'Spiele acht verschiedene Spiele',         'Das Pferderennen zählt nach 19:15 Uhr', 'distinct_games', null, 8, 100, 'hard', true),
('play50',      'Spiele 50 Runden',                        'Egal welches Spiel',            'rounds_any',  null,        50, 75, 'hard', true),
('earn250',     'Gewinne insgesamt 250 Coins',             'Netto-Gewinne aller Runden zählen', 'coins_won', null,      250, 100, 'hard', true),
('big3',        'Hol drei Gewinne ab 5× Einsatz',          'Egal welches Spiel',            'big_win_any', null,        3,  120, 'hard', true),
('plinko_big',  'Triff bei Plinko einen Rand (ab 5×)',     '',                              'big_win_game', 'plinko',   1,  80, 'hard', true),
('poker_win3',  'Gewinne drei Runden Video Poker',         '',                              'wins_game',   'poker',     3,  70, 'hard', true)
on conflict do nothing;
