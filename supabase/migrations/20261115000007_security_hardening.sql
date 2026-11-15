-- SpassCoin: Datenbank zusätzlich absichern (Verteidigung in mehreren Schichten)

-- 1) Niemand darf Tabellen direkt verändern. Alle Änderungen laufen über geprüfte Funktionen (SECURITY DEFINER),
--    die Seite liest Tabellen nur. Nicht angemeldete Besucher bekommen gar keinen Tabellenzugriff.
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
-- Neue Funktionen sind nicht mehr automatisch für alle aufrufbar (jede Freigabe muss bewusst erfolgen)
alter default privileges in schema public revoke execute on functions from public, anon;

-- 2) Lese-Regeln nur für angemeldete Nutzer; auth.uid() in (select …) wird pro Abfrage nur einmal berechnet (schneller)
drop policy if exists "eigenes Konto lesen" on public.profiles;
create policy "eigenes Konto lesen" on public.profiles for select to authenticated
  using ((select auth.uid()) = id or (select public.is_admin()));
drop policy if exists "eigene Anfragen lesen" on public.coin_requests;
create policy "eigene Anfragen lesen" on public.coin_requests for select to authenticated
  using ((select auth.uid()) = user_id or (select public.is_admin()));
drop policy if exists "eigene Transaktionen lesen" on public.transactions;
create policy "eigene Transaktionen lesen" on public.transactions for select to authenticated
  using ((select auth.uid()) in (sender_id, receiver_id) or (select public.is_admin()));

-- 3) is_admin() braucht niemand ohne Anmeldung
revoke execute on function public.is_admin() from anon;

-- 4) Feste Suchpfade für die letzten Hilfsfunktionen (verhindert, dass fremde Objekte untergeschoben werden)
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('adjust_weights', 'bj_soft', 'bj_total', 'bj_view', 'race_t', 'slot_draw') loop
    execute format('alter function %s set search_path = public, pg_temp', r.f);
  end loop;
end $$;

-- 5) Freigabe "für alle" (PUBLIC) entfernen: is_admin nur für Angemeldete, Trigger-Funktion für niemanden
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
revoke execute on function public.tx_daily_add() from public, anon, authenticated;
