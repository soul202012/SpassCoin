-- SpassCoin: Neue Missionen 3 Stunden nachdem alle drei abgeholt wurden (um Mitternacht wie bisher sowieso neu).
-- Jede Runde Missionen eines Tages ist ein "batch". Eine Mission kommt pro Tag höchstens einmal vor.
alter table public.player_missions add column if not exists batch smallint not null default 1;

create or replace function public.my_missions()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare me uuid := auth.uid(); today date := (now() at time zone 'Europe/Zurich')::date;
        midnight timestamptz := ((now() at time zone 'Europe/Zurich')::date + 1)::timestamp at time zone 'Europe/Zurich';
        cfg jsonb; slot text; picked bigint; cur int; open_cnt int; last_claim timestamptz; next_at timestamptz;
begin
  if me is null then raise exception 'Nicht angemeldet'; end if;
  perform pg_advisory_xact_lock(hashtext('missions:' || me::text));
  select max(batch) into cur from public.player_missions where user_id = me and day = today;
  if cur is not null then
    select count(*) filter (where not claimed), max(claimed_at) into open_cnt, last_claim
      from public.player_missions where user_id = me and day = today and batch = cur;
    -- Alle abgeholt und 3 Stunden vorbei: nächste Runde
    if open_cnt = 0 and last_claim + interval '3 hours' <= now() then cur := cur + 1; else cur := -cur; end if;
  else
    cur := 1;
  end if;
  if cur > 0 then
    select value into cfg from public.app_config where key = 'missions';
    for slot in select jsonb_array_elements_text(cfg->'slots') loop
      picked := null;
      select d.id into picked from public.mission_defs d
       where d.active and d.difficulty = slot
         and d.id not in (select mission_id from public.player_missions where user_id = me and day = today)
       order by random() limit 1;
      if picked is not null then
        insert into public.player_missions (user_id, day, mission_id, batch) values (me, today, picked, cur);
      end if;
    end loop;
  end if;
  cur := abs(cur);
  -- Wann gibt es neue Missionen? (nur wenn alle abgeholt sind; spätestens um Mitternacht)
  select count(*) filter (where not claimed), max(claimed_at) into open_cnt, last_claim
    from public.player_missions where user_id = me and day = today and batch = cur;
  next_at := case when open_cnt = 0 and last_claim is not null then least(last_claim + interval '3 hours', midnight) end;
  return (select coalesce(jsonb_agg(jsonb_build_object('mission_id', d.id, 'title', d.title, 'descr', d.descr, 'kind', d.kind,
            'game', d.game, 'target', d.target, 'reward', d.reward, 'difficulty', d.difficulty,
            'progress', least(pm.progress, d.target), 'completed', pm.completed, 'claimed', pm.claimed,
            'batch', pm.batch, 'next_at', next_at)
          order by case d.difficulty when 'easy' then 1 when 'medium' then 2 else 3 end, d.id), '[]'::jsonb)
          from public.player_missions pm join public.mission_defs d on d.id = pm.mission_id
          where pm.user_id = me and pm.day = today and pm.batch = cur);
end $function$;
