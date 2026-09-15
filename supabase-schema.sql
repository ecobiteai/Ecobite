-- ============================================================
-- EcoBite — run once in Supabase: SQL Editor -> New query
-- (Safe to re-run: every statement below is idempotent.)
--
-- Auth itself (email/password, sessions) is handled by Supabase's
-- built-in auth.users table. This file:
--   1. creates a profiles table extending each account with the
--      optional role-specific details completed after sign-up,
--   2. locks it down with row-level security (you only ever see
--      and edit your own row),
--   3. installs a trigger that creates the profile row the moment
--      a user signs up, from the details signup.html passes as
--      sign-up metadata (sb.auth.signUp({ options: { data } })).
--
-- Creating the row inside the database matters: when email
-- confirmation is on, the browser has no session yet right after
-- signUp, so a client-side insert runs as anonymous and RLS
-- rightly blocks it ("new row violates row-level security policy").
-- The trigger runs as the table owner instead, with the details
-- already attached to the user.
-- ============================================================

-- ---- 1. Table -------------------------------------------------

-- Required for gen_random_uuid() used by food_offers below.
create extension if not exists pgcrypto with schema extensions;

do $$
begin
  create type public.ecobite_role as enum ('donor', 'org', 'driver');
exception
  when duplicate_object then null;  -- type already exists from a previous run
end $$;

create table if not exists public.profiles (
  id               uuid references auth.users(id) on delete cascade primary key,
  role             public.ecobite_role,
  full_name        text not null,
  city             text not null,
  org_name         text,           -- donor: business name / org: organisation name
  org_kind         text,           -- donor: restaurant, grocer, bakery...
  reach            text,           -- org: people served per week
  storage          text[],         -- org: chilled / frozen / dry / same-day
  surplus_windows  text[],         -- donor: when surplus usually shows up
  transport        text,           -- driver: on foot / bike / car / van
  availability     text[],         -- driver: when they're usually free
  created_at       timestamptz not null default now()
);

-- `create table if not exists` does not add fields to a table created by an
-- earlier version of this script. Keep these migrations explicit so this file
-- is safe for both fresh and existing projects.
alter table public.profiles add column if not exists role public.ecobite_role;
alter table public.profiles add column if not exists full_name text;
alter table public.profiles add column if not exists city text;
alter table public.profiles add column if not exists org_name text;
alter table public.profiles add column if not exists org_kind text;
alter table public.profiles add column if not exists reach text;
alter table public.profiles add column if not exists storage text[];
alter table public.profiles add column if not exists surplus_windows text[];
alter table public.profiles add column if not exists transport text;
alter table public.profiles add column if not exists availability text[];
alter table public.profiles add column if not exists created_at timestamptz not null default now();

-- Existing installs created role as required; the lightweight signup now lets
-- people choose it from Profile or Settings later.
alter table public.profiles alter column role drop not null;

-- ---- 2. Row-level security ------------------------------------

alter table public.profiles enable row level security;

-- Everyone can only ever see, create, or edit their own row —
-- never anyone else's.
drop policy if exists "Individuals can view their own profile" on public.profiles;
create policy "Individuals can view their own profile"
  on public.profiles for select
  using (auth.uid() = id);

drop policy if exists "Individuals can insert their own profile" on public.profiles;
create policy "Individuals can insert their own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

drop policy if exists "Individuals can update their own profile" on public.profiles;
create policy "Individuals can update their own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- ---- 3. Auto-create the profile on sign-up ---------------------

-- Turns the JSON arrays from the sign-up form (checkbox lists)
-- into Postgres text[] columns. Missing or non-array values
-- quietly become '{}'.
create or replace function public.jsonb_to_text_array(v jsonb)
returns text[]
language sql
immutable
as $$
  select coalesce(array_agg(x.value order by x.ord), '{}'::text[])
  from jsonb_array_elements_text(
         case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end
       ) with ordinality as x(value, ord)
$$;

-- security definer: runs as the table owner, so the insert can't be
-- tripped up by RLS or by the session not existing yet mid-signup.
-- search_path is pinned to empty so the function can't be hijacked
-- by a maliciously named object in another schema.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  meta jsonb := new.raw_user_meta_data;
begin
  insert into public.profiles (
    id, role, full_name, city,
    org_name, org_kind, reach, storage, surplus_windows,
    transport, availability
  ) values (
    new.id,
    case when meta->>'role' in ('donor','org','driver')
         then (meta->>'role')::public.ecobite_role
         else null end,
    coalesce(meta->>'full_name', ''),
    coalesce(meta->>'city', ''),
    nullif(meta->>'org_name', ''),
    nullif(meta->>'org_kind', ''),
    nullif(meta->>'reach', ''),
    public.jsonb_to_text_array(meta->'storage'),
    public.jsonb_to_text_array(meta->'surplus_windows'),
    nullif(meta->>'transport', ''),
    public.jsonb_to_text_array(meta->'availability')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---- 4. One-time repair ----------------------------------------
-- Creates profile rows for accounts that signed up while the old
-- (broken) setup was live, using whatever details they carry as
-- sign-up metadata. Accounts created before the metadata change
-- keep a blank role until it is completed from Profile or Settings.

insert into public.profiles (
  id, role, full_name, city,
  org_name, org_kind, reach, storage, surplus_windows,
  transport, availability
)
select
  u.id,
  case when u.raw_user_meta_data->>'role' in ('donor','org','driver')
       then (u.raw_user_meta_data->>'role')::public.ecobite_role
       else null end,
  coalesce(u.raw_user_meta_data->>'full_name', ''),
  coalesce(u.raw_user_meta_data->>'city', ''),
  nullif(u.raw_user_meta_data->>'org_name', ''),
  nullif(u.raw_user_meta_data->>'org_kind', ''),
  nullif(u.raw_user_meta_data->>'reach', ''),
  public.jsonb_to_text_array(u.raw_user_meta_data->'storage'),
  public.jsonb_to_text_array(u.raw_user_meta_data->'surplus_windows'),
  nullif(u.raw_user_meta_data->>'transport', ''),
  public.jsonb_to_text_array(u.raw_user_meta_data->'availability')
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id);

-- ---- 5. Shared food offers -------------------------------------
-- Donors create offers here. Signed-in receivers can see open offers
-- in their city and claim one; this makes data visible across devices.

create table if not exists public.food_offers (
  id uuid primary key default gen_random_uuid(),
  donor_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid references public.profiles(id) on delete set null,
  city text not null,
  category text not null check (category in ('prepared', 'produce', 'bakery', 'chilled')),
  food_name text not null check (char_length(trim(food_name)) > 0),
  quantity numeric not null check (quantity > 0),
  unit text not null check (unit in ('portions', 'kg', 'items', 'crates')),
  collect_by text not null,
  status text not null default 'open' check (status in ('open', 'claimed', 'collected', 'cancelled')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);

-- Claim handoff details shared privately by the donor and recipient.
alter table public.food_offers add column if not exists recipient_contact_name text;
alter table public.food_offers add column if not exists recipient_phone text;
alter table public.food_offers add column if not exists pickup_address text;
alter table public.food_offers add column if not exists pickup_mode text;
alter table public.food_offers add column if not exists pickup_notes text;

create index if not exists food_offers_city_status_idx
  on public.food_offers (city, status, created_at desc);

alter table public.food_offers enable row level security;

drop policy if exists "Users can view relevant food offers" on public.food_offers;
create policy "Users can view relevant food offers"
  on public.food_offers for select to authenticated
  using (status = 'open' or donor_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists "Donors can create food offers" on public.food_offers;
create policy "Donors can create food offers"
  on public.food_offers for insert to authenticated
  with check (donor_id = auth.uid());

drop policy if exists "Donors can manage their food offers" on public.food_offers;
create policy "Donors can manage their food offers"
  on public.food_offers for update to authenticated
  using (donor_id = auth.uid()) with check (donor_id = auth.uid());

drop policy if exists "Receivers can claim open food offers" on public.food_offers;
create policy "Receivers can claim open food offers"
  on public.food_offers for update to authenticated
  using (status = 'open' and recipient_id is null)
  with check (recipient_id = auth.uid() and status = 'claimed');

-- Refresh PostgREST's table/relationship cache so the browser client can use
-- public.food_offers immediately after this script has run.
notify pgrst, 'reload schema';
