-- EcoBite AI forecasting data. Run after supabase-schema.sql.
-- The API still verifies facility membership itself; these RLS policies also
-- protect the tables if they are accessed through Supabase directly.

do $$
begin
  create type public.facility_member_role as enum ('owner', 'manager', 'analyst', 'viewer');
exception when duplicate_object then null;
end $$;

create table if not exists public.facilities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  timezone text not null default 'UTC',
  created_at timestamptz not null default now()
);

create table if not exists public.facility_members (
  facility_id uuid not null references public.facilities(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  member_role public.facility_member_role not null default 'viewer',
  created_at timestamptz not null default now(),
  primary key (facility_id, user_id)
);

create table if not exists public.consumption_history (
  id bigint generated always as identity primary key,
  facility_id uuid not null references public.facilities(id) on delete cascade,
  consumption_date date not null,
  ingredient_name text not null,
  menu_type text not null,
  planned_servings integer not null check (planned_servings >= 0),
  raw_quantity numeric not null check (raw_quantity >= 0),
  unit text not null default 'kg',
  weather_temperature_c numeric,
  weather_precipitation_mm numeric check (weather_precipitation_mm >= 0),
  is_holiday boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists consumption_history_facility_date on public.consumption_history(facility_id, consumption_date);

alter table public.facilities enable row level security;
alter table public.facility_members enable row level security;
alter table public.consumption_history enable row level security;

drop policy if exists "Members can view their facilities" on public.facilities;
create policy "Members can view their facilities" on public.facilities for select using (
  exists (select 1 from public.facility_members m where m.facility_id = id and m.user_id = auth.uid())
);
drop policy if exists "Members can view facility membership" on public.facility_members;
create policy "Members can view facility membership" on public.facility_members for select using (
  exists (select 1 from public.facility_members mine where mine.facility_id = facility_id and mine.user_id = auth.uid())
);
drop policy if exists "Members can view facility history" on public.consumption_history;
create policy "Members can view facility history" on public.consumption_history for select using (
  exists (select 1 from public.facility_members m where m.facility_id = facility_id and m.user_id = auth.uid())
);

-- Delivery marketplace and private GPS tracking ----------------------------
-- The existing profiles table supplies the donor, organisation, and driver
-- identities. These tables contain the opt-in delivery details only.

create table if not exists public.driver_delivery_preferences (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  service_city text not null,
  delivery_mode text not null check (delivery_mode in ('free', 'paid', 'both')),
  base_fee numeric check (base_fee is null or base_fee >= 0),
  max_distance_km numeric not null default 15 check (max_distance_km > 0 and max_distance_km <= 500),
  is_available boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.driver_live_locations (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  latitude numeric not null check (latitude between -90 and 90),
  longitude numeric not null check (longitude between -180 and 180),
  updated_at timestamptz not null default now()
);

create table if not exists public.delivery_jobs (
  id uuid primary key default gen_random_uuid(),
  donor_id uuid not null references public.profiles(id),
  receiver_id uuid not null references public.profiles(id),
  driver_id uuid references public.profiles(id),
  pickup_latitude numeric not null check (pickup_latitude between -90 and 90),
  pickup_longitude numeric not null check (pickup_longitude between -180 and 180),
  dropoff_latitude numeric not null check (dropoff_latitude between -90 and 90),
  dropoff_longitude numeric not null check (dropoff_longitude between -180 and 180),
  delivery_mode text not null check (delivery_mode in ('free', 'paid')),
  offered_amount numeric check (offered_amount is null or offered_amount >= 0),
  notes text,
  food_summary text,
  quantity numeric check (quantity is null or quantity > 0),
  quantity_unit text,
  pickup_window_start timestamptz,
  pickup_window_end timestamptz,
  priority text not null default 'normal' check (priority in ('normal', 'urgent')),
  status text not null default 'open' check (status in ('open', 'claimed', 'in_progress', 'delivered', 'cancelled')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);
-- Existing projects may already have the initial version of delivery_jobs.
alter table public.delivery_jobs add column if not exists food_summary text;
alter table public.delivery_jobs add column if not exists quantity numeric check (quantity is null or quantity > 0);
alter table public.delivery_jobs add column if not exists quantity_unit text;
alter table public.delivery_jobs add column if not exists pickup_window_start timestamptz;
alter table public.delivery_jobs add column if not exists pickup_window_end timestamptz;
alter table public.delivery_jobs add column if not exists priority text not null default 'normal' check (priority in ('normal', 'urgent'));
create index if not exists delivery_jobs_open_idx on public.delivery_jobs(status, created_at desc) where status = 'open';

create table if not exists public.delivery_location_events (
  id bigint generated always as identity primary key,
  job_id uuid not null references public.delivery_jobs(id) on delete cascade,
  driver_id uuid not null references public.profiles(id),
  latitude numeric not null check (latitude between -90 and 90),
  longitude numeric not null check (longitude between -180 and 180),
  accuracy_m numeric check (accuracy_m is null or accuracy_m >= 0),
  heading numeric check (heading is null or heading between 0 and 360),
  recorded_at timestamptz not null default now()
);
create index if not exists delivery_location_events_job_idx on public.delivery_location_events(job_id, recorded_at desc);

create table if not exists public.delivery_events (
  id bigint generated always as identity primary key,
  job_id uuid not null references public.delivery_jobs(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  detail text,
  event_at timestamptz not null default now()
);
create index if not exists delivery_events_job_idx on public.delivery_events(job_id, event_at);

create table if not exists public.delivery_feedback (
  job_id uuid not null references public.delivery_jobs(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  primary key (job_id, author_id)
);

alter table public.driver_delivery_preferences enable row level security;
alter table public.driver_live_locations enable row level security;
alter table public.delivery_jobs enable row level security;
alter table public.delivery_location_events enable row level security;
alter table public.delivery_events enable row level security;
alter table public.delivery_feedback enable row level security;

-- Direct Supabase access is restricted too. The API independently verifies
-- these same roles before any query, so clients cannot spoof a user id.
drop policy if exists "Drivers manage their delivery preferences" on public.driver_delivery_preferences;
create policy "Drivers manage their delivery preferences" on public.driver_delivery_preferences
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());
drop policy if exists "Verified parties can see driver options" on public.driver_delivery_preferences;
create policy "Verified parties can see driver options" on public.driver_delivery_preferences for select using (
  exists (select 1 from public.profiles where id = auth.uid() and role in ('donor', 'org'))
);
drop policy if exists "Participants can see delivery jobs" on public.delivery_jobs;
create policy "Participants can see delivery jobs" on public.delivery_jobs for select using (
  auth.uid() in (donor_id, receiver_id, driver_id)
);
drop policy if exists "Participants can see delivery tracking" on public.delivery_location_events;
create policy "Participants can see delivery tracking" on public.delivery_location_events for select using (
  exists (select 1 from public.delivery_jobs j where j.id = job_id
    and auth.uid() in (j.donor_id, j.receiver_id, j.driver_id))
);
drop policy if exists "Participants can see delivery events" on public.delivery_events;
create policy "Participants can see delivery events" on public.delivery_events for select using (
  exists (select 1 from public.delivery_jobs j where j.id = job_id
    and auth.uid() in (j.donor_id, j.receiver_id, j.driver_id))
);
drop policy if exists "Participants can see delivery feedback" on public.delivery_feedback;
create policy "Participants can see delivery feedback" on public.delivery_feedback for select using (
  exists (select 1 from public.delivery_jobs j where j.id = job_id
    and auth.uid() in (j.donor_id, j.receiver_id, j.driver_id))
);
