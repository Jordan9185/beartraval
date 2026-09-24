-- Shopping (WP8): items people want to buy, possible merchants with evidence,
-- purchase stops through proposals, and purchase/undo events (spec §3.6).
-- "想買" (interest) and "誰買到" (purchase events) are separate on purpose.

create type app.evidence_type as enum ('official_locator', 'poi_category', 'user');
create type app.inventory_status as enum ('unknown', 'verified');
create type app.purchase_event_type as enum ('purchased', 'undone');

create table app.shopping_items (
  id               uuid primary key default gen_random_uuid(),
  trip_id          uuid not null references app.trips (id) on delete cascade,
  name             text not null check (length(btrim(name)) between 1 and 200),
  note             text check (length(note) <= 2000),
  url              text,
  added_by         uuid not null references auth.users (id),
  -- Set when a purchase stop for this item is confirmed on the itinerary.
  planned_stop_id  uuid references app.stops (id) on delete set null,
  client_op_id     uuid unique,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);

create table app.shopping_interests (
  item_id     uuid not null references app.shopping_items (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (item_id, user_id)
);

-- "可能販售" only: evidence says where it may be sold, never stock (rule 6).
create table app.merchant_candidates (
  id                uuid primary key default gen_random_uuid(),
  item_id           uuid not null references app.shopping_items (id) on delete cascade,
  place_id          uuid not null references app.places (id),
  evidence_type     app.evidence_type not null,
  evidence_url      text,
  evidence_note     text check (length(evidence_note) <= 1000),
  evidence_at       timestamptz not null default now(),
  -- D8: evidence expires after 30 days.
  expires_at        timestamptz not null default now() + interval '30 days',
  inventory_status  app.inventory_status not null default 'unknown',
  added_by          uuid not null references auth.users (id),
  unique (item_id, place_id)
);

-- Who bought it is an event log, so a mistaken tick can be undone (AC-11).
create table app.purchase_events (
  id            bigint generated always as identity primary key,
  item_id       uuid not null references app.shopping_items (id) on delete cascade,
  actor_id      uuid not null references auth.users (id),
  type          app.purchase_event_type not null,
  client_op_id  uuid unique,
  created_at    timestamptz not null default now()
);

create index purchase_events_item_idx on app.purchase_events (item_id, id desc);

alter table app.stops add column shopping_item_id uuid references app.shopping_items (id) on delete set null;

alter table app.shopping_items enable row level security;
alter table app.shopping_interests enable row level security;
alter table app.merchant_candidates enable row level security;
alter table app.purchase_events enable row level security;

create policy shopping_items_member_read on app.shopping_items
  for select to authenticated using (app.trip_role_of(trip_id) is not null);
create policy shopping_interests_member_read on app.shopping_interests
  for select to authenticated using (exists (select 1 from app.shopping_items i where i.id = item_id and app.trip_role_of(i.trip_id) is not null));
create policy merchant_candidates_member_read on app.merchant_candidates
  for select to authenticated using (exists (select 1 from app.shopping_items i where i.id = item_id and app.trip_role_of(i.trip_id) is not null));
create policy purchase_events_member_read on app.purchase_events
  for select to authenticated using (exists (select 1 from app.shopping_items i where i.id = item_id and app.trip_role_of(i.trip_id) is not null));

grant select on app.shopping_items, app.shopping_interests, app.merchant_candidates, app.purchase_events to authenticated;
revoke insert, update, delete, truncate on app.shopping_items, app.shopping_interests, app.merchant_candidates, app.purchase_events from authenticated, anon;

-- A confirmed purchase stop links back to its item.
create function app.link_purchase_stop() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.shopping_item_id is not null and new.deleted_at is null then
    update app.shopping_items set planned_stop_id = new.id, updated_at = now()
     where id = new.shopping_item_id and trip_id = new.trip_id;
  elsif new.shopping_item_id is not null and new.deleted_at is not null then
    update app.shopping_items set planned_stop_id = null, updated_at = now()
     where id = new.shopping_item_id and planned_stop_id = new.id;
  end if;
  return new;
end;
$$;

create trigger stops_link_purchase
  after insert or update of shopping_item_id, deleted_at on app.stops
  for each row execute function app.link_purchase_stop();

create function app.add_shopping_item(
  p_trip_id uuid,
  p_name text,
  p_note text default null,
  p_url text default null,
  p_client_op_id uuid default null
) returns app.shopping_items
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  i app.shopping_items;
begin
  perform app.require_role(p_trip_id, array['owner', 'editor']::app.trip_role[]);
  if p_client_op_id is not null then
    select * into i from app.shopping_items where client_op_id = p_client_op_id and trip_id = p_trip_id;
    if found then return i; end if;
  end if;
  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'INVALID_ITEM' using errcode = 'PT422';
  end if;
  insert into app.shopping_items (trip_id, name, note, url, added_by, client_op_id)
  values (p_trip_id, btrim(p_name), nullif(btrim(p_note), ''), nullif(btrim(p_url), ''), uid, p_client_op_id)
  returning * into i;
  insert into app.shopping_interests (item_id, user_id) values (i.id, uid);
  perform app.bump_trip(p_trip_id, 'shopping.changed', i.id);
  return i;
end;
$$;

create function app.set_shopping_interest(p_item_id uuid, p_interested boolean) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  i app.shopping_items;
begin
  select * into i from app.shopping_items where id = p_item_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(i.trip_id, array['owner', 'editor']::app.trip_role[]);
  if p_interested then
    insert into app.shopping_interests (item_id, user_id) values (i.id, uid) on conflict do nothing;
  else
    delete from app.shopping_interests where item_id = i.id and user_id = uid;
  end if;
  perform app.bump_trip(i.trip_id, 'shopping.changed', i.id);
end;
$$;

create function app.add_merchant_candidate(
  p_item_id uuid,
  p_place_id uuid,
  p_evidence_type app.evidence_type,
  p_evidence_url text default null,
  p_evidence_note text default null
) returns app.merchant_candidates
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  i app.shopping_items;
  m app.merchant_candidates;
begin
  select * into i from app.shopping_items where id = p_item_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(i.trip_id, array['owner', 'editor']::app.trip_role[]);
  if not exists (select 1 from app.places where id = p_place_id) then
    raise exception 'PLACE_NOT_FOUND' using errcode = 'PT422';
  end if;
  -- Official evidence must point somewhere checkable.
  if p_evidence_type = 'official_locator' and length(btrim(coalesce(p_evidence_url, ''))) = 0 then
    raise exception 'EVIDENCE_REQUIRED' using errcode = 'PT422';
  end if;

  insert into app.merchant_candidates (item_id, place_id, evidence_type, evidence_url, evidence_note, added_by)
  values (i.id, p_place_id, p_evidence_type, nullif(btrim(p_evidence_url), ''), nullif(btrim(p_evidence_note), ''), uid)
  on conflict (item_id, place_id) do update
    set evidence_type = excluded.evidence_type, evidence_url = excluded.evidence_url,
        evidence_note = excluded.evidence_note, evidence_at = now(), expires_at = now() + interval '30 days'
  returning * into m;
  perform app.bump_trip(i.trip_id, 'shopping.changed', i.id);
  return m;
end;
$$;

-- purchased = true records a purchase; false undoes the latest one.
-- Undo is limited to the buyer or the owner (plan §3.3).
create function app.record_purchase(p_item_id uuid, p_purchased boolean, p_client_op_id uuid default null) returns text
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
    if last_event.actor_id <> uid and role <> 'owner' then
      raise exception 'FORBIDDEN_ROLE' using errcode = 'PT403', detail = 'only the buyer or the owner can undo';
    end if;
    insert into app.purchase_events (item_id, actor_id, type, client_op_id) values (i.id, uid, 'undone', p_client_op_id);
  end if;
  perform app.bump_trip(i.trip_id, 'shopping.changed', i.id);
  return case when p_purchased then 'purchased' else 'undone' end;
end;
$$;

-- confirm_proposal now also carries the shopping item for purchase stops.
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

revoke execute on function
  app.link_purchase_stop(),
  app.add_shopping_item(uuid, text, text, text, uuid),
  app.set_shopping_interest(uuid, boolean),
  app.add_merchant_candidate(uuid, uuid, app.evidence_type, text, text),
  app.record_purchase(uuid, boolean, uuid)
from public, anon, authenticated;

grant execute on function
  app.add_shopping_item(uuid, text, text, text, uuid),
  app.set_shopping_interest(uuid, boolean),
  app.add_merchant_candidate(uuid, uuid, app.evidence_type, text, text),
  app.record_purchase(uuid, boolean, uuid)
to authenticated;
