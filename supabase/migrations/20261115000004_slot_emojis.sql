-- Slotmaschine: Symbole wieder als Emojis (nur Anzeige, Gewichte und Faktoren bleiben gleich)
update public.game_settings set slot_symbols = (
  select jsonb_agg(jsonb_set(e, '{symbol}', to_jsonb(case (e->>'mult')::int when 5 then '🍒' when 10 then '🍋' when 15 then '🍉' when 50 then '🔔' when 100 then '💎' when 150 then '7️⃣' else e->>'symbol' end)) order by o)
  from jsonb_array_elements(slot_symbols) with ordinality t(e, o)
) where id = 1;
