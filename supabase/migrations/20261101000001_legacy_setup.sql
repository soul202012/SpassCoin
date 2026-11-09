-- SpassCoin: Datenbank einrichten (in Supabase unter "SQL Editor" einfügen und "Run" klicken)

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  email text not null,
  balance bigint not null default 0 check (balance >= 0),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Prüft, ob der eingeloggte Benutzer Admin ist
create or replace function public.is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- Jeder sieht nur sein eigenes Konto, der Admin sieht alle
create policy "eigenes Konto lesen" on public.profiles
  for select using (auth.uid() = id or public.is_admin());

-- Beim Registrieren wird automatisch ein Konto angelegt
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, email)
  values (new.id, lower(new.raw_user_meta_data->>'username'), new.email);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Coins kaufen (symbolisch): nur das eigene Konto, 1 bis 100000 Coins
create or replace function public.buy_coins(amount int) returns bigint
language plpgsql security definer set search_path = public as $$
declare neu bigint;
begin
  if amount < 1 or amount > 100000 then raise exception 'Ungültige Anzahl'; end if;
  update public.profiles set balance = balance + amount where id = auth.uid() returning balance into neu;
  return neu;
end $$;

-- Für den Login mit Benutzername
create or replace function public.email_for_username(uname text) returns text
language sql security definer set search_path = public stable as $$
  select email from public.profiles where username = lower(uname)
$$;

create or replace function public.username_taken(uname text) returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.profiles where username = lower(uname))
$$;

grant execute on function public.buy_coins(int) to authenticated;
grant execute on function public.email_for_username(text) to anon, authenticated;
grant execute on function public.username_taken(text) to anon, authenticated;
