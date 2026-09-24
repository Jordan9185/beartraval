-- Core itinerary schema: trips, members, days, places, stops, invites, change events.
--
-- Authorization model (plan §3.3):
--   * Tables are read-only for clients; RLS limits reads to active trip members.
--   * Every write goes through a SECURITY DEFINER function that checks the caller's
--     role. Hiding a button in the UI is never the authorization.
--   * Itinerary writes carry an expected revision; a mismatch raises STALE_REVISION.
--
-- Errors use SQLSTATE "PTnnn" so PostgREST returns HTTP status nnn:
--   PT401 UNAUTHENTICATED, PT403 FORBIDDEN_ROLE, PT404 NOT_FOUND / INVITE_INVALID,
--   PT409 STALE_REVISION, PT410 INVITE_EXPIRED / INVITE_REVOKED, PT422 validation.

create schema if not exists app;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type app.trip_role as enum ('owner', 'editor', 'viewer');
create type app.member_status as enum ('active', 'removed');
create type app.transport_mode as enum ('transit', 'walking', 'driving');
create type app.stop_kind as enum ('standard', 'purchase');
create type app.resolution_status as enum ('resolved', 'pending_text');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table app.trips (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(btrim(name)) between 1 and 200),
  start_date    date not null,
  end_date      date not null,
  time_zone     text not null,
  primary_city  text,
  owner_id      uuid not null references auth.users (id),
  revision      bigint not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (end_date >= start_date),
  check (end_date - start_date < 60)
);

create table app.trip_members (
  trip_id     uuid not null references app.trips (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        app.trip_role not null,
  status      app.member_status not null default 'active',
  joined_at   timestamptz not null default now(),
  primary key (trip_id, user_id)
);

create index trip_members_user_idx on app.trip_members (user_id) where status = 'active';

create table app.trip_days (
  id              uuid primary key default gen_random_uuid(),
  trip_id         uuid not null references app.trips (id) on delete cascade,
  local_date      date not null,
  time_zone       text not null,
  transport_mode  app.transport_mode not null default 'transit',
  display_order   int not null,
  route_revision  bigint not null default 0,
  unique (trip_id, local_date)
);

-- Places are a shared POI cache (public business data, not trip-private).
create table app.places (
  id                 uuid primary key default gen_random_uuid(),
  provider           text not null,
  provider_place_id  text not null,
  name               text not null,
  name_local         text,
  address            text,
  latitude           double precision not null check (latitude between -90 and 90),
  longitude          double precision not null check (longitude between -180 and 180),
  country_code       text,
  created_at         timestamptz not null default now(),
  unique (provider, provider_place_id)
);

create table app.stops (
  id                 uuid primary key default gen_random_uuid(),
  trip_id            uuid not null references app.trips (id) on delete cascade,
  day_id             uuid not null references app.trip_days (id) on delete cascade,
  place_id           uuid references app.places (id),
  raw_label          text not null check (length(btrim(raw_label)) between 1 and 500),
  resolution_status  app.resolution_status not null,
  start_time         time,
  end_time           time,
  dwell_minutes      int check (dwell_minutes between 0 and 1440),
  fixed              boolean not null default false,
  kind               app.stop_kind not null default 'standard',
  sort_order         int not null,
  added_by           uuid not null references auth.users (id),
  revision           bigint not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  -- An unresolved stop never carries a place, so it can never enter route math.
  check ((resolution_status = 'resolved') = (place_id is not null))
);

create index stops_day_idx on app.stops (day_id, sort_order) where deleted_at is null;

create table app.invites (
  id           uuid primary key default gen_random_uuid(),
  trip_id      uuid not null references app.trips (id) on delete cascade,
  token_hash   text not null unique,
  role         app.trip_role not null check (role <> 'owner'),
  created_by   uuid not null references auth.users (id),
  expires_at   timestamptz not null,
  max_uses     int check (max_uses > 0),
  use_count    int not null default 0,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);

-- Change feed. Realtime pushes these rows (ids + revision only); clients then
-- refetch, and use get_trip_changes(since_revision) to catch up after reconnecting.
create table app.trip_events (
  id          bigint generated always as identity primary key,
  trip_id     uuid not null references app.trips (id) on delete cascade,
  revision    bigint not null,
  kind        text not null,
  entity_id   uuid,
  actor_id    uuid,
  created_at  timestamptz not null default now()
);

create index trip_events_trip_rev_idx on app.trip_events (trip_id, revision);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create function app.current_user_id() returns uuid
language plpgsql stable
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'PT401';
  end if;
  return uid;
end;
$$;

-- Active role of the current user in a trip, or null.
create function app.trip_role_of(p_trip_id uuid) returns app.trip_role
language sql stable security definer
set search_path = ''
as $$
  select m.role
  from app.trip_members m
  where m.trip_id = p_trip_id
    and m.user_id = auth.uid()
    and m.status = 'active';
$$;

create function app.require_role(p_trip_id uuid, p_allowed app.trip_role[]) returns app.trip_role
language plpgsql stable
set search_path = ''
as $$
declare
  r app.trip_role;
begin
  perform app.current_user_id();
  r := app.trip_role_of(p_trip_id);
  if r is null or not (r = any (p_allowed)) then
    raise exception 'FORBIDDEN_ROLE' using errcode = 'PT403';
  end if;
  return r;
end;
$$;

-- Bumps the trip revision and records one event. Returns the new trip revision.
create function app.bump_trip(p_trip_id uuid, p_kind text, p_entity_id uuid) returns bigint
language plpgsql
set search_path = ''
as $$
declare
  new_rev bigint;
begin
  update app.trips
     set revision = revision + 1, updated_at = now()
   where id = p_trip_id
  returning revision into new_rev;

  insert into app.trip_events (trip_id, revision, kind, entity_id, actor_id)
  values (p_trip_id, new_rev, p_kind, p_entity_id, auth.uid());

  return new_rev;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row level security: members may read; nobody writes directly.
-- ---------------------------------------------------------------------------

alter table app.trips enable row level security;
alter table app.trip_members enable row level security;
alter table app.trip_days enable row level security;
alter table app.places enable row level security;
alter table app.stops enable row level security;
alter table app.invites enable row level security;
alter table app.trip_events enable row level security;

create policy trips_member_read on app.trips
  for select to authenticated using (app.trip_role_of(id) is not null);

create policy trip_members_member_read on app.trip_members
  for select to authenticated using (app.trip_role_of(trip_id) is not null);

create policy trip_days_member_read on app.trip_days
  for select to authenticated using (app.trip_role_of(trip_id) is not null);

create policy places_authenticated_read on app.places
  for select to authenticated using (true);

create policy stops_member_read on app.stops
  for select to authenticated using (app.trip_role_of(trip_id) is not null);

create policy invites_owner_read on app.invites
  for select to authenticated using (app.trip_role_of(trip_id) = 'owner');

create policy trip_events_member_read on app.trip_events
  for select to authenticated using (app.trip_role_of(trip_id) is not null);

grant usage on schema app to authenticated;
grant select on all tables in schema app to authenticated;
revoke insert, update, delete, truncate on all tables in schema app from authenticated, anon;
revoke all on schema app from anon;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Creates a trip, its days, and the owner membership.
create function app.create_trip(
  p_name text,
  p_start_date date,
  p_end_date date,
  p_time_zone text
) returns app.trips
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  t app.trips;
begin
  if p_end_date < p_start_date then
    raise exception 'INVALID_DATES' using errcode = 'PT422';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'INVALID_TIME_ZONE' using errcode = 'PT422';
  end if;

  insert into app.trips (name, start_date, end_date, time_zone, owner_id)
  values (btrim(p_name), p_start_date, p_end_date, p_time_zone, uid)
  returning * into t;

  insert into app.trip_members (trip_id, user_id, role) values (t.id, uid, 'owner');

  insert into app.trip_days (trip_id, local_date, time_zone, display_order)
  select t.id, d::date, p_time_zone, row_number() over (order by d) - 1
  from generate_series(p_start_date, p_end_date, interval '1 day') as d;

  return t;
end;
$$;

-- Replaces a day's itinerary with the given ordered stop list.
--
-- p_stops: [{ "id"?: uuid, "place_id"?: uuid, "raw_label": text, "start_time"?: "HH:MM",
--             "end_time"?: "HH:MM", "dwell_minutes"?: int, "fixed"?: bool,
--             "kind"?: "standard"|"purchase" }]
-- Entries with an existing id update that stop; entries without id create one;
-- existing stops missing from the list are soft-deleted. Array order is sort order.
--
-- Returns the new route_revision. Raises STALE_REVISION if the day changed since
-- p_expected_route_revision; nothing is written in that case.
create function app.commit_itinerary(
  p_day_id uuid,
  p_expected_route_revision bigint,
  p_stops jsonb
) returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  d app.trip_days;
  s jsonb;
  pos int := 0;
  stop_id uuid;
  place uuid;
  kept uuid[] := '{}';
  new_rev bigint;
begin
  -- Lock the day so concurrent commits serialize; the second one sees the bump.
  select * into d from app.trip_days where id = p_day_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;

  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);

  if d.route_revision <> p_expected_route_revision then
    raise exception 'STALE_REVISION'
      using errcode = 'PT409',
            detail = pg_catalog.format('current route_revision is %s', d.route_revision);
  end if;

  if jsonb_typeof(p_stops) <> 'array' then
    raise exception 'INVALID_STOPS' using errcode = 'PT422';
  end if;

  for s in select * from jsonb_array_elements(p_stops) loop
    place := nullif(s ->> 'place_id', '')::uuid;
    if place is not null and not exists (select 1 from app.places where id = place) then
      raise exception 'PLACE_NOT_FOUND' using errcode = 'PT422';
    end if;

    stop_id := nullif(s ->> 'id', '')::uuid;

    if stop_id is not null then
      update app.stops
         set place_id = place,
             raw_label = s ->> 'raw_label',
             resolution_status = case when place is null then 'pending_text' else 'resolved' end::app.resolution_status,
             start_time = (s ->> 'start_time')::time,
             end_time = (s ->> 'end_time')::time,
             dwell_minutes = (s ->> 'dwell_minutes')::int,
             fixed = coalesce((s ->> 'fixed')::boolean, false),
             kind = coalesce(s ->> 'kind', 'standard')::app.stop_kind,
             sort_order = pos,
             revision = revision + 1,
             updated_at = now()
       where id = stop_id and day_id = p_day_id and deleted_at is null;
      if not found then
        raise exception 'STOP_NOT_IN_DAY' using errcode = 'PT422';
      end if;
    else
      insert into app.stops (
        trip_id, day_id, place_id, raw_label, resolution_status, start_time, end_time,
        dwell_minutes, fixed, kind, sort_order, added_by
      ) values (
        d.trip_id, p_day_id, place, s ->> 'raw_label',
        case when place is null then 'pending_text' else 'resolved' end::app.resolution_status,
        (s ->> 'start_time')::time, (s ->> 'end_time')::time,
        (s ->> 'dwell_minutes')::int, coalesce((s ->> 'fixed')::boolean, false),
        coalesce(s ->> 'kind', 'standard')::app.stop_kind, pos, uid
      ) returning id into stop_id;
    end if;

    kept := kept || stop_id;
    pos := pos + 1;
  end loop;

  update app.stops
     set deleted_at = now(), revision = revision + 1, updated_at = now()
   where day_id = p_day_id and deleted_at is null and not (id = any (kept));

  update app.trip_days
     set route_revision = route_revision + 1
   where id = p_day_id
  returning route_revision into new_rev;

  perform app.bump_trip(d.trip_id, 'day.itinerary_changed', p_day_id);

  return new_rev;
end;
$$;

-- Creates an invite link token. The plaintext token is returned once; only its
-- hash is stored, so a trip id alone never grants access.
create function app.create_invite(
  p_trip_id uuid,
  p_role app.trip_role,
  p_expires_in interval default interval '7 days',
  p_max_uses int default null
) returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  token text;
begin
  perform app.require_role(p_trip_id, array['owner']::app.trip_role[]);
  if p_role = 'owner' then
    raise exception 'INVALID_ROLE' using errcode = 'PT422';
  end if;

  token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');

  insert into app.invites (trip_id, token_hash, role, created_by, expires_at, max_uses)
  values (p_trip_id, encode(sha256(convert_to(token, 'UTF8')), 'hex'), p_role, uid,
          now() + p_expires_in, p_max_uses);

  return token;
end;
$$;

create function app.revoke_invite(p_invite_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  t uuid;
begin
  select trip_id into t from app.invites where id = p_invite_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(t, array['owner']::app.trip_role[]);
  update app.invites set revoked_at = now() where id = p_invite_id and revoked_at is null;
end;
$$;

-- Joins the trip behind an invite token. An existing active member keeps their role.
create function app.accept_invite(p_token text) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  inv app.invites;
begin
  select * into inv
  from app.invites
  where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
  for update;

  if not found then
    raise exception 'INVITE_INVALID' using errcode = 'PT404';
  end if;
  if inv.revoked_at is not null then
    raise exception 'INVITE_REVOKED' using errcode = 'PT410';
  end if;
  if inv.expires_at <= now() or (inv.max_uses is not null and inv.use_count >= inv.max_uses) then
    raise exception 'INVITE_EXPIRED' using errcode = 'PT410';
  end if;

  if exists (select 1 from app.trip_members
             where trip_id = inv.trip_id and user_id = uid and status = 'active') then
    return inv.trip_id;
  end if;

  insert into app.trip_members (trip_id, user_id, role)
  values (inv.trip_id, uid, inv.role)
  on conflict (trip_id, user_id)
  do update set role = excluded.role, status = 'active', joined_at = now();

  update app.invites set use_count = use_count + 1 where id = inv.id;

  perform app.bump_trip(inv.trip_id, 'member.changed', uid);

  return inv.trip_id;
end;
$$;

create function app.set_member_role(p_trip_id uuid, p_user_id uuid, p_role app.trip_role) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform app.require_role(p_trip_id, array['owner']::app.trip_role[]);
  if p_role = 'owner' or p_user_id = auth.uid() then
    raise exception 'INVALID_ROLE' using errcode = 'PT422';
  end if;
  update app.trip_members set role = p_role
   where trip_id = p_trip_id and user_id = p_user_id and status = 'active';
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.bump_trip(p_trip_id, 'member.changed', p_user_id);
end;
$$;

create function app.remove_member(p_trip_id uuid, p_user_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform app.require_role(p_trip_id, array['owner']::app.trip_role[]);
  if p_user_id = auth.uid() then
    raise exception 'INVALID_ROLE' using errcode = 'PT422';
  end if;
  update app.trip_members set status = 'removed'
   where trip_id = p_trip_id and user_id = p_user_id and status = 'active';
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.bump_trip(p_trip_id, 'member.changed', p_user_id);
end;
$$;

-- Events after a known trip revision, for catching up after reconnecting.
create function app.get_trip_changes(p_trip_id uuid, p_since_revision bigint)
returns setof app.trip_events
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform app.require_role(p_trip_id, array['owner', 'editor', 'viewer']::app.trip_role[]);
  return query
    select * from app.trip_events
    where trip_id = p_trip_id and revision > p_since_revision
    order by revision;
end;
$$;

-- New functions default to EXECUTE for PUBLIC; lock everything down, then allow
-- only the RPCs.
revoke execute on all functions in schema app from public, anon, authenticated;

grant execute on function
  app.create_trip(text, date, date, text),
  app.commit_itinerary(uuid, bigint, jsonb),
  app.create_invite(uuid, app.trip_role, interval, int),
  app.revoke_invite(uuid),
  app.accept_invite(text),
  app.set_member_role(uuid, uuid, app.trip_role),
  app.remove_member(uuid, uuid),
  app.get_trip_changes(uuid, bigint)
to authenticated;

-- RLS policies call this helper.
grant execute on function app.trip_role_of(uuid) to authenticated;

-- Supabase Realtime: broadcast change events (RLS still applies to subscribers).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table app.trip_events;
  end if;
end;
$$;
