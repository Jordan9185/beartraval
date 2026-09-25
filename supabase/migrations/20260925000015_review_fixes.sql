-- Fixes from the 2026-09-25 review (medium severity).

-- 1. commit_itinerary: NULL expected revision skipped the STALE check, and NULL
--    stops soft-deleted every stop of the day. Same body, with both required.
create or replace function app.commit_itinerary(
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

  -- NULL would skip the revision check or delete the whole day (review): both are required.
  if p_expected_route_revision is null or p_stops is null then
    raise exception 'INVALID_STOPS' using errcode = 'PT422', detail = 'expected revision and stops are required';
  end if;

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

-- 2. Saved entries return to the "to add" list when their place leaves the
--    itinerary (stop removed or re-pointed), so the place can be added again.
create or replace function app.mark_saved_added() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.place_id is not null and new.deleted_at is null then
    update app.saved_places
       set status = 'added_to_itinerary', updated_at = now()
     where trip_id = new.trip_id and place_id = new.place_id and status = 'saved';
  end if;
  if tg_op = 'UPDATE' and old.place_id is not null and old.deleted_at is null
     and (new.deleted_at is not null or new.place_id is distinct from old.place_id)
     and not exists (select 1 from app.stops
                      where trip_id = old.trip_id and place_id = old.place_id and deleted_at is null and id <> old.id) then
    update app.saved_places
       set status = 'saved', updated_at = now()
     where trip_id = old.trip_id and place_id = old.place_id and status = 'added_to_itinerary';
  end if;
  return new;
end;
$$;

-- 3. Places are shared by every trip, keyed by the map provider's id.
--    * Filling in a missing local/Chinese name is only allowed while no trip the
--      caller isn't in uses the place, so a stranger can't rename other trips' places.
--    * If the id is already registered more than 1 km from what the caller saw,
--      the caller gets their own row instead of someone else's (possibly planted) data.
create or replace function app.upsert_place(
  p_provider text,
  p_provider_place_id text,
  p_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_name_local text default null,
  p_address text default null,
  p_country_code text default null,
  p_name_zh text default null
) returns app.places
language plpgsql security definer
set search_path = ''
as $$
declare
  p app.places;
  key text := btrim(coalesce(p_provider_place_id, ''));
begin
  perform app.current_user_id();

  if p_provider is null or p_provider not in ('apple_mapkit', 'apple_maps_server') then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'unknown provider';
  end if;
  if length(key) = 0 or length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'id and name are required';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'coordinates out of range';
  end if;

  select * into p from app.places where provider = p_provider and provider_place_id = key;
  if found and app.distance_km(p.latitude, p.longitude, p_latitude, p_longitude) > 1 then
    key := key || '~' || left(md5(pg_catalog.format('%s|%s|%s', btrim(p_name), round(p_latitude::numeric, 4), round(p_longitude::numeric, 4))), 12);
    select * into p from app.places where provider = p_provider and provider_place_id = key;
  end if;

  if not found then
    insert into app.places (provider, provider_place_id, name, name_local, address, latitude, longitude, country_code, name_zh)
    values (p_provider, key, btrim(p_name), nullif(btrim(p_name_local), ''),
            nullif(btrim(p_address), ''), p_latitude, p_longitude, upper(nullif(btrim(p_country_code), '')),
            nullif(btrim(p_name_zh), ''))
    on conflict (provider, provider_place_id) do nothing
    returning * into p;
    if p.id is null then
      select * into p from app.places where provider = p_provider and provider_place_id = key;
    end if;
    return p;
  end if;

  if (p.name_local is null or p.name_zh is null) and not app.place_used_by_others(p.id) then
    update app.places
       set name_local = coalesce(name_local, nullif(btrim(p_name_local), '')),
           name_zh = coalesce(name_zh, nullif(btrim(p_name_zh), ''))
     where id = p.id
    returning * into p;
  end if;
  return p;
end;
$$;

create function app.distance_km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision
language sql immutable
set search_path = ''
as $$
  select 2 * 6371 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))));
$$;

-- True when a trip the caller doesn't belong to references the place.
create function app.place_used_by_others(p_place_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from app.stops where place_id = p_place_id and app.trip_role_of(trip_id) is null)
      or exists (select 1 from app.saved_places where place_id = p_place_id and app.trip_role_of(trip_id) is null)
      or exists (select 1 from app.merchant_candidates m join app.shopping_items i on i.id = m.item_id
                  where m.place_id = p_place_id and app.trip_role_of(i.trip_id) is null);
$$;

revoke execute on function app.place_used_by_others(uuid) from public, anon, authenticated;

-- 4. Per-user limits on AI calls (Claude costs money per call).
create table app.ai_usage (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  kind        text not null check (kind in ('parse', 'ask', 'extract')),
  created_at  timestamptz not null default now()
);
create index ai_usage_user_idx on app.ai_usage (user_id, kind, created_at desc);
alter table app.ai_usage enable row level security;
revoke all on app.ai_usage from anon, authenticated;

-- Records one call and returns true, or returns false when the caller is over
-- the hourly or daily limit for that kind.
create function app.consume_ai_quota(p_kind text) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  per_hour int;
  per_day int;
begin
  select h, d into per_hour, per_day
    from (values ('parse', 10, 30), ('ask', 40, 200), ('extract', 30, 100)) as limits(k, h, d)
   where k = p_kind;
  if per_hour is null then
    raise exception 'INVALID_KIND' using errcode = 'PT422';
  end if;
  -- Serialise this user's checks so parallel calls can't all pass the limit.
  perform pg_advisory_xact_lock(hashtext(uid::text || p_kind));
  if (select count(*) from app.ai_usage where user_id = uid and kind = p_kind and created_at > now() - interval '1 hour') >= per_hour
     or (select count(*) from app.ai_usage where user_id = uid and kind = p_kind and created_at > now() - interval '1 day') >= per_day then
    return false;
  end if;
  insert into app.ai_usage (user_id, kind) values (uid, p_kind);
  delete from app.ai_usage where user_id = uid and created_at < now() - interval '2 days';
  return true;
end;
$$;

revoke execute on function app.consume_ai_quota(text) from public, anon;
grant execute on function app.consume_ai_quota(text) to authenticated;
