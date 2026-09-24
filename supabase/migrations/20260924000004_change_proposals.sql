-- Change proposals (WP5): the only way a Route Match result becomes a stop.
--
-- A proposal records what the user was shown (+N travel, +M dwell, fixed-stop
-- check) and the route_revision it was computed against. Any later change to
-- that day marks open proposals stale; confirming a stale proposal writes
-- nothing and tells the client to recompute and ask again (AC-08, AC-13).

create type app.proposal_status as enum ('proposed', 'confirmed', 'rejected', 'stale');

create table app.change_proposals (
  id                       uuid primary key default gen_random_uuid(),
  trip_id                  uuid not null references app.trips (id) on delete cascade,
  day_id                   uuid not null references app.trip_days (id) on delete cascade,
  -- MVP supports inserting one stop:
  -- { "place_id": uuid, "raw_label": text, "before_stop_id"?: uuid, "after_stop_id"?: uuid,
  --   "dwell_minutes"?: int, "kind"?: "standard"|"purchase" }
  change                   jsonb not null,
  -- Numbers shown to the user when proposing (client-computed Route Match).
  route_match              jsonb,
  expected_route_revision  bigint not null,
  status                   app.proposal_status not null default 'proposed',
  created_by               uuid not null references auth.users (id),
  created_by_ai            boolean not null default false,
  created_at               timestamptz not null default now(),
  decided_by               uuid references auth.users (id),
  decided_at               timestamptz,
  result_stop_id           uuid references app.stops (id),
  result_route_revision    bigint
);

create index change_proposals_day_idx on app.change_proposals (day_id, status);

alter table app.change_proposals enable row level security;

create policy change_proposals_member_read on app.change_proposals
  for select to authenticated using (app.trip_role_of(trip_id) is not null);

grant select on app.change_proposals to authenticated;
revoke insert, update, delete, truncate on app.change_proposals from authenticated, anon;

-- Whatever changes a day's itinerary (commit_itinerary, confirm_proposal,
-- future RPCs) bumps route_revision; that alone invalidates open proposals.
create function app.stale_open_proposals() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update app.change_proposals
     set status = 'stale'
   where day_id = new.id and status = 'proposed' and expected_route_revision <> new.route_revision;
  return new;
end;
$$;

create trigger trip_days_stale_proposals
  after update of route_revision on app.trip_days
  for each row when (old.route_revision is distinct from new.route_revision)
  execute function app.stale_open_proposals();

create function app.create_proposal(
  p_day_id uuid,
  p_expected_route_revision bigint,
  p_change jsonb,
  p_route_match jsonb default null
) returns app.change_proposals
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  d app.trip_days;
  p app.change_proposals;
  place uuid;
begin
  select * into d from app.trip_days where id = p_day_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);

  if d.route_revision <> p_expected_route_revision then
    raise exception 'STALE_REVISION'
      using errcode = 'PT409', detail = pg_catalog.format('current route_revision is %s', d.route_revision);
  end if;

  -- Only confirmed places can be proposed: unknown locations never enter routes.
  place := nullif(p_change ->> 'place_id', '')::uuid;
  if place is null or not exists (select 1 from app.places where id = place) then
    raise exception 'PLACE_UNRESOLVED' using errcode = 'PT422';
  end if;
  if length(btrim(coalesce(p_change ->> 'raw_label', ''))) = 0 then
    raise exception 'INVALID_STOPS' using errcode = 'PT422';
  end if;

  insert into app.change_proposals (trip_id, day_id, change, route_match, expected_route_revision, created_by)
  values (d.trip_id, d.id, p_change, p_route_match, p_expected_route_revision, uid)
  returning * into p;
  return p;
end;
$$;

-- Returns { "status": "confirmed", "route_revision": n, "stop_id": uuid }
--      or { "status": "stale", "route_revision": current }.
-- A stale result is not an exception so the stale mark is committed.
create function app.confirm_proposal(p_proposal_id uuid) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  p app.change_proposals;
  d app.trip_days;
  anchor app.stops;
  pos int;
  new_stop uuid;
  new_rev bigint;
begin
  select * into p from app.change_proposals where id = p_proposal_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;

  -- Same lock as commit_itinerary: concurrent writers to a day serialize here.
  select * into d from app.trip_days where id = p.day_id for update;
  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);

  select * into p from app.change_proposals where id = p_proposal_id for update;
  if p.status = 'stale' or (p.status = 'proposed' and p.expected_route_revision <> d.route_revision) then
    update app.change_proposals set status = 'stale' where id = p.id;
    return jsonb_build_object('status', 'stale', 'route_revision', d.route_revision);
  end if;
  if p.status <> 'proposed' then
    raise exception 'PROPOSAL_CLOSED' using errcode = 'PT409', detail = p.status::text;
  end if;

  -- Resolve the insert position against the current (unchanged) day.
  if p.change ? 'before_stop_id' then
    select * into anchor from app.stops
     where id = (p.change ->> 'before_stop_id')::uuid and day_id = d.id and deleted_at is null;
    if not found then raise exception 'STOP_NOT_IN_DAY' using errcode = 'PT422'; end if;
    pos := anchor.sort_order;
  elsif p.change ? 'after_stop_id' then
    select * into anchor from app.stops
     where id = (p.change ->> 'after_stop_id')::uuid and day_id = d.id and deleted_at is null;
    if not found then raise exception 'STOP_NOT_IN_DAY' using errcode = 'PT422'; end if;
    pos := anchor.sort_order + 1;
  else
    select coalesce(max(sort_order) + 1, 0) into pos from app.stops where day_id = d.id and deleted_at is null;
  end if;

  update app.stops
     set sort_order = sort_order + 1, updated_at = now()
   where day_id = d.id and deleted_at is null and sort_order >= pos;

  insert into app.stops (trip_id, day_id, place_id, raw_label, resolution_status, dwell_minutes, kind, sort_order, added_by)
  values (d.trip_id, d.id, (p.change ->> 'place_id')::uuid, p.change ->> 'raw_label', 'resolved',
          (p.change ->> 'dwell_minutes')::int, coalesce(p.change ->> 'kind', 'standard')::app.stop_kind, pos, uid)
  returning id into new_stop;

  -- Close this proposal before bumping, so the trigger only stales the others.
  update app.change_proposals
     set status = 'confirmed', decided_by = uid, decided_at = now(), result_stop_id = new_stop,
         result_route_revision = d.route_revision + 1
   where id = p.id;

  update app.trip_days set route_revision = route_revision + 1 where id = d.id returning route_revision into new_rev;
  perform app.bump_trip(d.trip_id, 'day.itinerary_changed', d.id);

  return jsonb_build_object('status', 'confirmed', 'route_revision', new_rev, 'stop_id', new_stop);
end;
$$;

create function app.reject_proposal(p_proposal_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  p app.change_proposals;
begin
  select * into p from app.change_proposals where id = p_proposal_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(p.trip_id, array['owner', 'editor']::app.trip_role[]);
  if p.status in ('proposed', 'stale') then
    update app.change_proposals set status = 'rejected', decided_by = uid, decided_at = now() where id = p.id;
  end if;
end;
$$;

revoke execute on function
  app.stale_open_proposals(),
  app.create_proposal(uuid, bigint, jsonb, jsonb),
  app.confirm_proposal(uuid),
  app.reject_proposal(uuid)
from public, anon, authenticated;

grant execute on function
  app.create_proposal(uuid, bigint, jsonb, jsonb),
  app.confirm_proposal(uuid),
  app.reject_proposal(uuid)
to authenticated;
