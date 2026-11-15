-- SpassCoin: Spiel "Truhen" heisst jetzt "Schatzkisten" (Fehlermeldungen und Mission)
do $$
declare r record; def text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prosrc ~ 'Truhe' loop
    def := pg_get_functiondef(r.oid);
    def := replace(def, 'Truhen', 'Schatzkisten');
    def := replace(def, 'Truhe', 'Schatzkiste');
    execute def;
  end loop;
end $$;
update public.mission_defs set title = 'Spiele eine Runde Schatzkisten' where title = 'Spiele eine Runde Truhen';
