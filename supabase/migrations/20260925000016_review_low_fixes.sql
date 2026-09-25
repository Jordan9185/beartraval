-- Fixes from the 2026-09-25 review (low severity).

-- 1. Account deletion: the departing user leaves every trip here, not only when
--    auth.users cascades later. If deleting the auth user then fails, the trip
--    must not be left with two owners (the old one could demote the heir).
--    Idempotent: a second run finds nothing to transfer and no memberships.
create or replace function app.prepare_account_deletion(p_user_id uuid) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  t record;
  heir uuid;
  transferred int := 0;
  deleted int := 0;
begin
  for t in select id from app.trips where owner_id = p_user_id loop
    select user_id into heir from app.trip_members
     where trip_id = t.id and user_id <> p_user_id and status = 'active'
     order by (role = 'editor') desc, joined_at
     limit 1;
    if heir is null then
      delete from app.import_sessions where trip_id = t.id;
      delete from app.trips where id = t.id;
      deleted := deleted + 1;
    else
      update app.trip_members set role = 'owner' where trip_id = t.id and user_id = heir;
      update app.trips set owner_id = heir, updated_at = now() where id = t.id;
      perform app.bump_trip(t.id, 'member.changed', heir);
      transferred := transferred + 1;
    end if;
  end loop;
  for t in select trip_id from app.trip_members where user_id = p_user_id and status = 'active' loop
    perform app.bump_trip(t.trip_id, 'member.changed', null);
  end loop;
  delete from app.trip_members where user_id = p_user_id;
  update app.trip_events set actor_id = null where actor_id = p_user_id;
  delete from app.import_sessions where created_by = p_user_id;
  return jsonb_build_object('transferred', transferred, 'deleted', deleted);
end;
$$;

-- 2. Parse attempts: a result or progress update is only written by the parse
--    that currently owns the import. Editing the text (update_import_text) or
--    reclaiming an abandoned parse starts a new attempt, so a late result for the
--    old text can no longer land on the new text.
alter table app.import_sessions add column parse_attempt uuid;

drop function app.begin_parse(uuid);
drop function app.record_parse_result(uuid, app.parse_status, jsonb, text, text);
drop function app.record_parse_progress(uuid, jsonb);

-- Returns the new attempt id, or null when another parse is still running.
create function app.begin_parse(p_import_id uuid) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  attempt uuid := gen_random_uuid();
begin
  update app.import_sessions
     set parse_status = 'parsing', parse_result = null, parse_error = null, parse_progress = null,
         parse_attempt = attempt, updated_at = now()
   where id = p_import_id
     and trip_id is null
     and (parse_status <> 'parsing' or updated_at < now() - interval '8 minutes');
  if not found then
    return null;
  end if;
  return attempt;
end;
$$;

-- True when recorded; false when the attempt was superseded (text edited,
-- parse reclaimed) or the import was already committed.
create function app.record_parse_result(
  p_import_id uuid,
  p_attempt uuid,
  p_status app.parse_status,
  p_result jsonb,
  p_error text,
  p_model text
) returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
  update app.import_sessions
     set parse_status = p_status, parse_result = p_result, parse_error = p_error,
         model = p_model, updated_at = now()
   where id = p_import_id and trip_id is null and parse_attempt = p_attempt;
  return found;
end;
$$;

create function app.record_parse_progress(p_import_id uuid, p_attempt uuid, p_progress jsonb) returns void
language sql security definer
set search_path = ''
as $$
  update app.import_sessions
     set parse_progress = p_progress
   where id = p_import_id and trip_id is null and parse_status = 'parsing' and parse_attempt = p_attempt;
$$;

revoke execute on function
  app.begin_parse(uuid),
  app.record_parse_result(uuid, uuid, app.parse_status, jsonb, text, text),
  app.record_parse_progress(uuid, uuid, jsonb)
from public, anon, authenticated;
grant execute on function
  app.begin_parse(uuid),
  app.record_parse_result(uuid, uuid, app.parse_status, jsonb, text, text),
  app.record_parse_progress(uuid, uuid, jsonb)
to service_role;

-- "回到原文編輯": replaces the text, clears any previous draft and ends the
-- running parse attempt (its result is dropped when it arrives).
create or replace function app.update_import_text(p_import_id uuid, p_raw_text text) returns app.import_sessions
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
         model = null, parse_progress = null, parse_attempt = null, updated_at = now()
   where id = p_import_id and created_by = uid and trip_id is null
  returning * into s;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  return s;
end;
$$;

-- 3. record_purchase: when the buyer's account was deleted (actor_id null), only
--    the owner may undo; `<>` against null let any editor through.
create or replace function app.record_purchase(p_item_id uuid, p_purchased boolean, p_client_op_id uuid default null) returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  i app.shopping_items;
  last_event app.purchase_events;
  role app.trip_role;
begin
  select * into i from app.shopping_items where id = p_item_id and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  role := app.require_role(i.trip_id, array['owner', 'editor']::app.trip_role[]);

  if p_client_op_id is not null and exists (select 1 from app.purchase_events where client_op_id = p_client_op_id) then
    return (select type::text from app.purchase_events where item_id = i.id order by id desc limit 1);
  end if;

  select * into last_event from app.purchase_events where item_id = i.id order by id desc limit 1;
  if p_purchased then
    if found and last_event.type = 'purchased' then
      return 'purchased';
    end if;
    insert into app.purchase_events (item_id, actor_id, type, client_op_id) values (i.id, uid, 'purchased', p_client_op_id);
  else
    if not found or last_event.type = 'undone' then
      return 'undone';
    end if;
    if last_event.actor_id is distinct from uid and role <> 'owner' then
      raise exception 'FORBIDDEN_ROLE' using errcode = 'PT403', detail = 'only the buyer or the owner can undo';
    end if;
    insert into app.purchase_events (item_id, actor_id, type, client_op_id) values (i.id, uid, 'undone', p_client_op_id);
  end if;
  perform app.bump_trip(i.trip_id, 'shopping.changed', i.id);
  return case when p_purchased then 'purchased' else 'undone' end;
end;
$$;

-- 4. create_proposal refuses what confirm_proposal would refuse later, so a
--    proposal shown to the user can always be confirmed (or goes stale):
--    anchors must be live stops of that day, kind a known stop kind, and
--    dwell_minutes a whole number of minutes within a day.
create or replace function app.create_proposal(
  p_day_id uuid,
  p_expected_route_revision bigint,
  p_change jsonb,
  p_route_match jsonb default null,
  p_created_by_ai boolean default false
) returns app.change_proposals
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  d app.trip_days;
  p app.change_proposals;
  place uuid;
  anchor text;
  dwell numeric;
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

  place := nullif(p_change ->> 'place_id', '')::uuid;
  if place is null or not exists (select 1 from app.places where id = place) then
    raise exception 'PLACE_UNRESOLVED' using errcode = 'PT422';
  end if;
  if length(btrim(coalesce(p_change ->> 'raw_label', ''))) = 0 then
    raise exception 'INVALID_STOPS' using errcode = 'PT422';
  end if;

  foreach anchor in array array['before_stop_id', 'after_stop_id'] loop
    if p_change ? anchor and not exists (
         select 1 from app.stops
          where id = app.uuid_or_null(p_change ->> anchor) and day_id = d.id and deleted_at is null) then
      raise exception 'STOP_NOT_IN_DAY' using errcode = 'PT422', detail = anchor;
    end if;
  end loop;
  if p_change ? 'kind' and jsonb_typeof(p_change -> 'kind') <> 'null'
     and (p_change ->> 'kind') not in ('standard', 'purchase') then
    raise exception 'INVALID_STOPS' using errcode = 'PT422', detail = 'unknown kind';
  end if;
  if p_change ? 'dwell_minutes' and jsonb_typeof(p_change -> 'dwell_minutes') <> 'null' then
    if jsonb_typeof(p_change -> 'dwell_minutes') <> 'number' then
      raise exception 'INVALID_STOPS' using errcode = 'PT422', detail = 'dwell_minutes must be 0-1440';
    end if;
    dwell := (p_change ->> 'dwell_minutes')::numeric;
    if dwell <> trunc(dwell) or dwell < 0 or dwell > 1440 then
      raise exception 'INVALID_STOPS' using errcode = 'PT422', detail = 'dwell_minutes must be 0-1440';
    end if;
  end if;

  insert into app.change_proposals (trip_id, day_id, change, route_match, expected_route_revision, created_by, created_by_ai)
  values (d.trip_id, d.id, p_change, p_route_match, p_expected_route_revision, uid, coalesce(p_created_by_ai, false))
  returning * into p;
  return p;
end;
$$;

-- 5. confirm_proposal: an item has at most one live purchase stop. A second one
--    would re-point planned_stop_id and leave the first stop orphaned.
create or replace function app.confirm_proposal(p_proposal_id uuid) returns jsonb
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
  item uuid;
begin
  select * into p from app.change_proposals where id = p_proposal_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;

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

  item := nullif(p.change ->> 'shopping_item_id', '')::uuid;
  if item is not null and not exists (select 1 from app.shopping_items where id = item and trip_id = d.trip_id and deleted_at is null) then
    raise exception 'NOT_FOUND' using errcode = 'PT404', detail = 'shopping item';
  end if;
  if item is not null and exists (
       select 1 from app.shopping_items i join app.stops s on s.id = i.planned_stop_id
        where i.id = item and s.deleted_at is null) then
    raise exception 'ALREADY_SCHEDULED' using errcode = 'PT409';
  end if;

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

  insert into app.stops (trip_id, day_id, place_id, raw_label, resolution_status, dwell_minutes, kind, sort_order, added_by, shopping_item_id)
  values (d.trip_id, d.id, (p.change ->> 'place_id')::uuid, p.change ->> 'raw_label', 'resolved',
          (p.change ->> 'dwell_minutes')::int,
          case when item is not null then 'purchase' else coalesce(p.change ->> 'kind', 'standard') end::app.stop_kind,
          pos, uid, item)
  returning id into new_stop;

  update app.change_proposals
     set status = 'confirmed', decided_by = uid, decided_at = now(), result_stop_id = new_stop,
         result_route_revision = d.route_revision + 1
   where id = p.id;

  update app.trip_days set route_revision = route_revision + 1 where id = d.id returning route_revision into new_rev;
  perform app.bump_trip(d.trip_id, 'day.itinerary_changed', d.id);
  if item is not null then
    perform app.bump_trip(d.trip_id, 'shopping.changed', item);
  end if;

  return jsonb_build_object('status', 'confirmed', 'route_revision', new_rev, 'stop_id', new_stop);
end;
$$;

-- 6. save_place:
--    * When an earlier share of the same URL couldn't be located and this one
--      could, the place is confirmed on that entry instead of being dropped.
--    * Two members saving the same place at the same moment: the second insert
--      hits the unique index; return the first one's entry as a duplicate.
create or replace function app.save_place(
  p_trip_id uuid,
  p_raw_label text,
  p_category app.saved_category default 'place',
  p_place_id uuid default null,
  p_source jsonb default null,
  p_client_op_id uuid default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  s app.saved_places;
  other app.saved_places;
  src uuid;
  canonical text := nullif(btrim(p_source ->> 'canonical_url'), '');
  duplicate boolean := false;
begin
  perform app.require_role(p_trip_id, array['owner', 'editor']::app.trip_role[]);

  -- A retried offline operation returns what the first attempt created.
  if p_client_op_id is not null then
    select * into s from app.saved_places where client_op_id = p_client_op_id and trip_id = p_trip_id;
    if found then
      return to_jsonb(s) || jsonb_build_object('duplicate', true);
    end if;
  end if;

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
    if duplicate and s.place_id is null and p_place_id is not null then
      select * into other from app.saved_places
       where trip_id = p_trip_id and place_id = p_place_id and status <> 'dismissed';
      if found then
        s := other;
      else
        update app.saved_places
           set place_id = p_place_id,
               status = case when exists (select 1 from app.stops
                                           where trip_id = p_trip_id and place_id = p_place_id and deleted_at is null)
                             then 'added_to_itinerary' else status end,
               updated_at = now()
         where id = s.id
        returning * into s;
        perform app.bump_trip(p_trip_id, 'saved.changed', s.id);
      end if;
    end if;
  end if;
  if not duplicate and p_place_id is not null then
    select * into s from app.saved_places
     where trip_id = p_trip_id and place_id = p_place_id and status <> 'dismissed';
    duplicate := found;
  end if;

  if not duplicate then
    begin
      if p_source is not null then
        insert into app.source_references (trip_id, type, url, canonical_url, summary, created_by)
        values (p_trip_id, coalesce(p_source ->> 'type', 'share')::app.source_type, p_source ->> 'url', canonical,
                left(p_source ->> 'summary', 2000), uid)
        on conflict (trip_id, canonical_url) where canonical_url is not null do update set canonical_url = excluded.canonical_url
        returning id into src;
      end if;

      insert into app.saved_places (trip_id, place_id, raw_label, category, source_id, added_by, status, client_op_id)
      values (p_trip_id, p_place_id, btrim(p_raw_label), p_category, src, uid,
              case when p_place_id is not null and exists (
                     select 1 from app.stops where trip_id = p_trip_id and place_id = p_place_id and deleted_at is null)
                   then 'added_to_itinerary' else 'saved' end::app.saved_status,
              p_client_op_id)
      returning * into s;
      perform app.bump_trip(p_trip_id, 'saved.changed', s.id);
    exception when unique_violation then
      -- A concurrent save of the same place (or the same retried op) committed first.
      select * into s from app.saved_places
       where trip_id = p_trip_id
         and ((p_client_op_id is not null and client_op_id = p_client_op_id)
              or (p_place_id is not null and place_id = p_place_id and status <> 'dismissed'))
       limit 1;
      if not found then
        raise;
      end if;
      duplicate := true;
    end;
  end if;

  insert into app.saved_interests (saved_id, user_id) values (s.id, uid) on conflict do nothing;

  return to_jsonb(s) || jsonb_build_object('duplicate', duplicate);
end;
$$;

-- 7. resolve_saved only fills in an unconfirmed entry (a confirmed place is not
--    silently re-pointed by another editor), and marks it added_to_itinerary
--    when the chosen place is already a stop of the trip.
create or replace function app.resolve_saved(p_saved_id uuid, p_place_id uuid) returns app.saved_places
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
  if s.place_id is not null then
    raise exception 'ALREADY_RESOLVED' using errcode = 'PT409';
  end if;
  if not exists (select 1 from app.places where id = p_place_id) then
    raise exception 'PLACE_NOT_FOUND' using errcode = 'PT422';
  end if;
  if exists (select 1 from app.saved_places where trip_id = s.trip_id and place_id = p_place_id
               and status <> 'dismissed' and id <> s.id) then
    raise exception 'DUPLICATE_SAVED' using errcode = 'PT409';
  end if;
  update app.saved_places
     set place_id = p_place_id,
         status = case when status = 'saved' and exists (
                         select 1 from app.stops where trip_id = s.trip_id and place_id = p_place_id and deleted_at is null)
                       then 'added_to_itinerary' else status end,
         updated_at = now()
   where id = s.id
  returning * into s;
  perform app.bump_trip(s.trip_id, 'saved.changed', s.id);
  return s;
end;
$$;
