-- SpassCoin: alle Spiele auf rund 110 % Auszahlungsquote (langfristig gewinnen die Spieler etwa 10 % ihrer Einsätze dazu).
-- Werte berechnet für die beste Spielweise; Kommentar = Quote danach (vorher).

update public.game_settings set
  -- Truhen: 7 Truhen (1,1,1,1,1,2,4) + 5 Bomben, Einsatz 1 -> 110.6 % bei bester Strategie (vorher 132.6 %)
  chest_bombs = 5,
  chest_values = '[1,1,1,1,1,2,4]'::jsonb,
  -- Glücksrad: Einsatz 1 -> 110 % (vorher 120 %)
  wheel_fields = '[{"payout":0,"weight":40},{"payout":1,"weight":30},{"payout":2,"weight":20},{"payout":3,"weight":5},{"payout":5,"weight":5}]'::jsonb,
  -- Slotmaschine: gleiche Chancen, höhere Faktoren -> 111.4 % (vorher 57.2 %)
  slot_symbols = (select jsonb_agg(jsonb_set(e, '{mult}', to_jsonb(case (e->>'weight')::numeric when 35 then 10 when 25 then 19 when 20 then 29 when 10 then 96 when 6 then 192 when 4 then 288 else (e->>'mult')::numeric end)) order by o)
                  from jsonb_array_elements(slot_symbols) with ordinality t(e, o)),
  -- Pferderennen: echte Chancen, jede Wette ~108.5 bis 110.4 % (vorher war Rot zu 99.6 % Sieger mit Quote 10)
  race_horses = (select jsonb_agg(jsonb_set(jsonb_set(e, '{weight}', to_jsonb(v.w)), '{odds}', to_jsonb(v.o)) order by t.o)
                 from jsonb_array_elements(race_horses) with ordinality t(e, o)
                 join (values (1, 35, 3.1), (2, 25, 4.4), (3, 20, 5.5), (4, 12, 9.2), (5, 8, 13.8)) v(i, w, o) on v.i = t.o),
  -- Blackjack: normaler Gewinn zahlt 1.2 x, Blackjack 2 x -> etwa 110 % (vorher etwa 123 %)
  bj_win_payout = 1.2,
  bj_blackjack_payout = 2
where id = 1;

-- Plinko: Form bleibt, alle Faktoren auf 110 % skaliert (vorher 95.0 / 98.0 / 94.9 %)
update public.app_config set value = jsonb_set(value, '{levels}', '{
  "low":    [8.22, 5.67, 3.7, 2.2, 1.27, 0.69, 0.58, 0.69, 1.27, 2.2, 3.7, 5.67, 8.22],
  "medium": [20.2, 11.78, 6.17, 2.81, 1.12, 0.45, 0.34, 0.45, 1.12, 2.81, 6.17, 11.78, 20.2],
  "high":   [50.75, 23.75, 9.39, 3.01, 0.7, 0.23, 0.23, 0.23, 0.7, 3.01, 9.39, 23.75, 50.75]
}'::jsonb) where key = 'plinko';

-- Rubbellose: 109.5 % (vorher 353.8 %)
update public.app_config set value = jsonb_set(value, '{tiers}', '[
  {"matches":0,"p":0.63,"mult":0},{"matches":2,"p":0.24,"mult":2},{"matches":3,"p":0.08,"mult":3},
  {"matches":4,"p":0.035,"mult":6},{"matches":5,"p":0.012,"mult":10},{"matches":8,"p":0.003,"mult":15}
]'::jsonb) where key = 'scratch';

-- Higher or Lower: Leiter x 1.16 -> 110.6 % bei bester Strategie (vorher 95.2 %)
update public.app_config set value = jsonb_set(value, '{ladder}', '[1.28, 1.86, 2.67, 3.83, 5.57, 8.12, 11.6, 16.82, 24.36, 34.8]'::jsonb) where key = 'hilo';

-- Video Poker: 9/6 und Zwei Paare zahlen 3 -> etwa 111 % bei guter Strategie (vorher 97.3 %)
update public.app_config set value = jsonb_set(value, '{paytable}',
  '{"royal":250,"straight_flush":50,"four":25,"full_house":9,"flush":6,"straight":4,"three":3,"two_pair":3,"jacks":1}'::jsonb) where key = 'poker';

-- Faire Rundung auch bei Blackjack, Pferderennen und Slots: statt immer abrunden zufällig auf/ab (round_payout),
-- sonst frisst das Abrunden bei kleinen Einsätzen den Vorteil (1 Coin x 2.2 wäre sonst immer 2).
do $$
declare f text; def text;
begin
  foreach f in array array['bj_settle', 'race_settle', 'slot_spin'] loop
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = f;
    def := regexp_replace(def, 'floor\((g\.stake|b\.stake|p_stake)', 'public.round_payout(\1', 'g');
    execute def;
  end loop;
end $$;
