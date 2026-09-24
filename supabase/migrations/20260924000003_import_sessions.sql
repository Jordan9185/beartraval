-- Text import pipeline (WP3): keep the pasted text, store the AI draft, and
-- create the trip with its stops in one transaction once the user confirms.
--
-- The draft is never itinerary data: stops only become rows in app.stops via
-- commit_import, after the client resolved each one to a confirmed place, an
-- explicit pending-text stop, or removed it (spec §3.1, AC-01).

create type app.parse_status as enum ('pending', 'parsing', 'parsed', 'failed');

create table app.import_sessions (
  id            uuid primary key default gen_random_uuid(),
  created_by    uuid not null references auth.users (id) on delete cascade,
  trip_name     text not null check (length(btrim(trip_name)) between 1 and 200),
  start_date    date not null,
  end_date      date not null,
  time_zone     text not null,
  -- The user's original text is always kept so parsing can be retried or edited.
  raw_text      text not null check (length(raw_text) <= 50000),
  parse_status  app.parse_status not null default 'pending',
  parse_result  jsonb,
  parse_error   text,
  model         text,
  trip_id       uuid references app.trips (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (end_date >= start_date),
  check (end_date - start_date < 60)
);

create index import_sessions_owner_idx on app.import_sessions (created_by, created_at desc);

alter table app.import_sessions enable row level security;

create policy import_sessions_owner_read on app.import_sessions
  for select to authenticated using (created_by = auth.uid());

grant select on app.import_sessions to authenticated;
revoke insert, update, delete, truncate on app.import_sessions from authenticated, anon;

-- Starts an import. Dates and time zone are validated like create_trip.
create function app.create_import(
  p_trip_name text,
  p_start_date date,
  p_end_date date,
  p_time_zone text,
  p_raw_text text
) returns app.import_sessions
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  s app.import_sessions;
begin
  if p_end_date < p_start_date then
    raise exception 'INVALID_DATES' using errcode = 'PT422';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'INVALID_TIME_ZONE' using errcode = 'PT422';
  end if;
  if length(btrim(coalesce(p_raw_text, ''))) = 0 then
    raise exception 'EMPTY_TEXT' using errcode = 'PT422';
  end if;

  insert into app.import_sessions (created_by, trip_name, start_date, end_date, time_zone, raw_text)
  values (uid, btrim(p_trip_name), p_start_date, p_end_date, p_time_zone, p_raw_text)
  returning * into s;
  return s;
end;
$$;

-- "回到原文編輯": replaces the text and clears any previous draft.
create function app.update_import_text(p_import_id uuid, p_raw_text text) returns app.import_sessions
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  s app.import_sessions;
begin
  if length(btrim(coalesce(p_raw_text, ''))) = 0 then
    raise exception 'EMPTY_TEXT' using errcode = 'PT422';
  end if;
  update app.import_sessions
     set raw_text = p_raw_text, parse_status = 'pending', parse_result = null, parse_error = null,
         model = null, updated_at = now()
   where id = p_import_id and created_by = uid and trip_id is null
  returning * into s;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  return s;
end;
$$;

-- Called by the parse-import Edge Function with the service role only.
create function app.record_parse_result(
  p_import_id uuid,
  p_status app.parse_status,
  p_result jsonb,
  p_error text,
  p_model text
) returns void
language sql security definer
set search_path = ''
as $$
  update app.import_sessions
     set parse_status = p_status, parse_result = p_result, parse_error = p_error,
         model = p_model, updated_at = now()
   where id = p_import_id and trip_id is null;
$$;

-- Creates the trip and every day's stops in one transaction.
--
-- p_days: [{ "date": "YYYY-MM-DD", "stops": [<commit_itinerary stop objects>] }]
-- Days not listed stay empty. Place ids must already exist (upsert_place).
create function app.commit_import(p_import_id uuid, p_days jsonb) returns app.trips
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  s app.import_sessions;
  t app.trips;
  d jsonb;
  day_id uuid;
begin
  select * into s from app.import_sessions where id = p_import_id and created_by = uid for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  if s.trip_id is not null then
    raise exception 'ALREADY_COMMITTED' using errcode = 'PT409';
  end if;
  if jsonb_typeof(p_days) <> 'array' then
    raise exception 'INVALID_STOPS' using errcode = 'PT422';
  end if;

  t := app.create_trip(s.trip_name, s.start_date, s.end_date, s.time_zone);

  for d in select * from jsonb_array_elements(p_days) loop
    select id into day_id from app.trip_days where trip_id = t.id and local_date = (d ->> 'date')::date;
    if day_id is null then
      raise exception 'DATE_OUTSIDE_TRIP' using errcode = 'PT422', detail = d ->> 'date';
    end if;
    if jsonb_array_length(coalesce(d -> 'stops', '[]')) > 0 then
      perform app.commit_itinerary(day_id, 0, d -> 'stops');
    end if;
  end loop;

  update app.import_sessions set trip_id = t.id, updated_at = now() where id = s.id;
  select * into t from app.trips where id = t.id;
  return t;
end;
$$;

revoke execute on function
  app.create_import(text, date, date, text, text),
  app.update_import_text(uuid, text),
  app.record_parse_result(uuid, app.parse_status, jsonb, text, text),
  app.commit_import(uuid, jsonb)
from public, anon, authenticated;

grant execute on function
  app.create_import(text, date, date, text, text),
  app.update_import_text(uuid, text),
  app.commit_import(uuid, jsonb)
to authenticated;

grant usage on schema app to service_role;
grant execute on function app.record_parse_result(uuid, app.parse_status, jsonb, text, text) to service_role;
