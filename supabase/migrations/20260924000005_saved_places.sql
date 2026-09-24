-- Saved places (WP6): places people are interested in but that are not part
-- of the itinerary (spec rule 5, 7). Friends' additions land here, never in
-- app.stops; turning one into a stop goes through a change proposal.

create type app.saved_category as enum ('eat', 'cafe', 'shop', 'place', 'other');
create type app.saved_status as enum ('saved', 'added_to_itinerary', 'dismissed');
create type app.source_type as enum ('share', 'url', 'text', 'image', 'manual');

-- Where a saved place came from, kept for traceability. canonical_url is
-- computed by the client (tracking parameters removed) and dedupes re-shares.
create table app.source_references (
  id             uuid primary key default gen_random_uuid(),
  trip_id        uuid not null references app.trips (id) on delete cascade,
  type           app.source_type not null,
  url            text,
  canonical_url  text,
  summary        text check (length(summary) <= 2000),
  created_by     uuid not null references auth.users (id),
  created_at     timestamptz not null default now()
);

create unique index source_references_canonical_idx
  on app.source_references (trip_id, canonical_url) where canonical_url is not null;

create table app.saved_places (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references app.trips (id) on delete cascade,
  -- Null until the location is confirmed; unconfirmed items never enter routes.
  place_id    uuid references app.places (id),
  raw_label   text not null check (length(btrim(raw_label)) between 1 and 500),
  category    app.saved_category not null default 'place',
  source_id   uuid references app.source_references (id),
  added_by    uuid not null references auth.users (id),
  status      app.saved_status not null default 'saved',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index saved_places_trip_idx on app.saved_places (trip_id, status);
create unique index saved_places_trip_place_idx
  on app.saved_places (trip_id, place_id) where place_id is not null and status <> 'dismissed';

-- "想去" as a set of members: concurrent toggles never conflict (plan §3.4).
create table app.saved_interests (
  saved_id    uuid not null references app.saved_places (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (saved_id, user_id)
);

alter table app.source_references enable row level security;
alter table app.saved_places enable row level security;
alter table app.saved_interests enable row level security;

create policy source_references_member_read on app.source_references
  for select to authenticated using (app.trip_role_of(trip_id) is not null);
create policy saved_places_member_read on app.saved_places
  for select to authenticated using (app.trip_role_of(trip_id) is not null);
create policy saved_interests_member_read on app.saved_interests
  for select to authenticated using (
    exists (select 1 from app.saved_places s where s.id = saved_id and app.trip_role_of(s.trip_id) is not null));

grant select on app.source_references, app.saved_places, app.saved_interests to authenticated;
revoke insert, update, delete, truncate on app.source_references, app.saved_places, app.saved_interests from authenticated, anon;

-- Once a place is on the itinerary, its Saved entry leaves the "to add" list.
create function app.mark_saved_added() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.place_id is not null and new.deleted_at is null then
    update app.saved_places
       set status = 'added_to_itinerary', updated_at = now()
     where trip_id = new.trip_id and place_id = new.place_id and status = 'saved';
  end if;
  return new;
end;
$$;

create trigger stops_mark_saved_added
  after insert or update of place_id, deleted_at on app.stops
  for each row execute function app.mark_saved_added();

-- Saves a place (or unconfirmed label) to the trip's shared Saved list.
-- Re-sharing the same URL or saving the same place returns the existing entry
-- and records the caller's interest instead of creating a duplicate.
-- Returns the saved row plus "duplicate": true/false.
create function app.save_place(
  p_trip_id uuid,
  p_raw_label text,
  p_category app.saved_category default 'place',
  p_place_id uuid default null,
  p_source jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  s app.saved_places;
  src uuid;
  canonical text := nullif(btrim(p_source ->> 'canonical_url'), '');
  duplicate boolean := false;
begin
  perform app.require_role(p_trip_id, array['owner', 'editor']::app.trip_role[]);
  if length(btrim(coalesce(p_raw_label, ''))) = 0 then
    raise exception 'INVALID_SAVED' using errcode = 'PT422';
  end if;
  if p_place_id is not null and not exists (select 1 from app.places where id = p_place_id) then
    raise exception 'PLACE_NOT_FOUND' using errcode = 'PT422';
  end if;

  if canonical is not null then
    select sp.* into s from app.saved_places sp
      join app.source_references r on r.id = sp.source_id
     where r.trip_id = p_trip_id and r.canonical_url = canonical and sp.status <> 'dismissed'
     limit 1;
    duplicate := found;
  end if;
  if not duplicate and p_place_id is not null then
    select * into s from app.saved_places
     where trip_id = p_trip_id and place_id = p_place_id and status <> 'dismissed';
    duplicate := found;
  end if;

  if not duplicate then
    if p_source is not null then
      insert into app.source_references (trip_id, type, url, canonical_url, summary, created_by)
      values (p_trip_id, coalesce(p_source ->> 'type', 'share')::app.source_type, p_source ->> 'url', canonical,
              left(p_source ->> 'summary', 2000), uid)
      on conflict (trip_id, canonical_url) where canonical_url is not null do update set canonical_url = excluded.canonical_url
      returning id into src;
    end if;

    insert into app.saved_places (trip_id, place_id, raw_label, category, source_id, added_by, status)
    values (p_trip_id, p_place_id, btrim(p_raw_label), p_category, src, uid,
            case when p_place_id is not null and exists (
                   select 1 from app.stops where trip_id = p_trip_id and place_id = p_place_id and deleted_at is null)
                 then 'added_to_itinerary' else 'saved' end::app.saved_status)
    returning * into s;
    perform app.bump_trip(p_trip_id, 'saved.changed', s.id);
  end if;

  insert into app.saved_interests (saved_id, user_id) values (s.id, uid) on conflict do nothing;

  return to_jsonb(s) || jsonb_build_object('duplicate', duplicate);
end;
$$;

create function app.set_saved_interest(p_saved_id uuid, p_interested boolean) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  s app.saved_places;
begin
  select * into s from app.saved_places where id = p_saved_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(s.trip_id, array['owner', 'editor']::app.trip_role[]);
  if p_interested then
    insert into app.saved_interests (saved_id, user_id) values (s.id, uid) on conflict do nothing;
  else
    delete from app.saved_interests where saved_id = s.id and user_id = uid;
  end if;
  perform app.bump_trip(s.trip_id, 'saved.changed', s.id);
end;
$$;

-- Confirms the location of an unconfirmed saved item (manual fill, AC-04).
create function app.resolve_saved(p_saved_id uuid, p_place_id uuid) returns app.saved_places
language plpgsql security definer
set search_path = ''
as $$
declare
  s app.saved_places;
begin
  select * into s from app.saved_places where id = p_saved_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(s.trip_id, array['owner', 'editor']::app.trip_role[]);
  if not exists (select 1 from app.places where id = p_place_id) then
    raise exception 'PLACE_NOT_FOUND' using errcode = 'PT422';
  end if;
  if exists (select 1 from app.saved_places where trip_id = s.trip_id and place_id = p_place_id
               and status <> 'dismissed' and id <> s.id) then
    raise exception 'DUPLICATE_SAVED' using errcode = 'PT409';
  end if;
  update app.saved_places set place_id = p_place_id, updated_at = now() where id = s.id returning * into s;
  perform app.bump_trip(s.trip_id, 'saved.changed', s.id);
  return s;
end;
$$;

create function app.dismiss_saved(p_saved_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  s app.saved_places;
begin
  select * into s from app.saved_places where id = p_saved_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(s.trip_id, array['owner', 'editor']::app.trip_role[]);
  update app.saved_places set status = 'dismissed', updated_at = now() where id = s.id;
  perform app.bump_trip(s.trip_id, 'saved.changed', s.id);
end;
$$;

revoke execute on function
  app.mark_saved_added(),
  app.save_place(uuid, text, app.saved_category, uuid, jsonb),
  app.set_saved_interest(uuid, boolean),
  app.resolve_saved(uuid, uuid),
  app.dismiss_saved(uuid)
from public, anon, authenticated;

grant execute on function
  app.save_place(uuid, text, app.saved_category, uuid, jsonb),
  app.set_saved_interest(uuid, boolean),
  app.resolve_saved(uuid, uuid),
  app.dismiss_saved(uuid)
to authenticated;
