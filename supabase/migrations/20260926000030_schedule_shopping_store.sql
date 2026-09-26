-- 商品辨識的店家線索可先排成待定位的購買站；店家存在不代表商品有賣或有庫存。
alter table app.shopping_items
  add column scheduled_store_name text,
  add column scheduled_store_address_local text,
  add column scheduled_store_source_url text;

-- 舊版 App 移除購買站時，清除該次選店線索；保留原始辨識候選供重新安排。
create or replace function app.link_purchase_stop() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.shopping_item_id is not null and new.deleted_at is null then
    update app.shopping_items set planned_stop_id = new.id, updated_at = now()
     where id = new.shopping_item_id and trip_id = new.trip_id;
  elsif new.shopping_item_id is not null and new.deleted_at is not null then
    update app.shopping_items set planned_stop_id = null,
      scheduled_store_name = null, scheduled_store_address_local = null,
      scheduled_store_source_url = null, updated_at = now()
     where id = new.shopping_item_id and planned_stop_id = new.id;
  end if;
  return new;
end;
$$;

create function app.schedule_shopping_store(
  p_item_id uuid,
  p_suggestion_index int,
  p_source_url text,
  p_day_id uuid,
  p_expected_route_revision bigint,
  p_client_op_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := app.current_user_id();
  d app.trip_days;
  i app.shopping_items;
  candidate jsonb;
  existing app.stops;
  new_stop uuid;
  new_rev bigint;
  store_name text;
  address_text text;
  pos int;
begin
  select * into d from app.trip_days where id = p_day_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);
  select * into i from app.shopping_items where id = p_item_id
    and trip_id = d.trip_id and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;

  if i.planned_stop_id is not null then
    select * into existing from app.stops where id = i.planned_stop_id and deleted_at is null;
  end if;
  if existing.id is not null then
    return jsonb_build_object('status', 'already_scheduled', 'stop_id', existing.id,
      'day_id', existing.day_id, 'route_revision', d.route_revision);
  end if;
  if p_client_op_id is null or p_expected_route_revision is null then
    raise exception 'INVALID_SCHEDULE' using errcode = 'PT422';
  end if;
  if d.route_revision <> p_expected_route_revision then
    raise exception 'STALE_REVISION' using errcode = 'PT409';
  end if;
  if p_suggestion_index is null or p_suggestion_index < 0 or p_suggestion_index > 2 then
    raise exception 'INVALID_STORE_SUGGESTION' using errcode = 'PT422';
  end if;
  candidate := i.store_suggestions -> p_suggestion_index;
  if candidate is null or candidate ->> 'source_url' is distinct from p_source_url then
    raise exception 'STALE_STORE_SUGGESTION' using errcode = 'PT409';
  end if;
  store_name := coalesce(nullif(btrim(candidate ->> 'korean_name'), ''),
                         nullif(btrim(candidate ->> 'name'), ''));
  address_text := nullif(btrim(candidate ->> 'address_local'), '');
  if store_name is null then
    raise exception 'INVALID_STORE_SUGGESTION' using errcode = 'PT422';
  end if;

  select coalesce(max(sort_order) + 1, 0) into pos from app.stops
    where day_id = d.id and deleted_at is null;
  insert into app.stops(trip_id, day_id, place_id, raw_label, resolution_status,
    dwell_minutes, fixed, kind, sort_order, added_by, shopping_item_id)
  values (d.trip_id, d.id, null, store_name, 'pending_text',
    30, false, 'purchase', pos, uid, i.id)
  returning id into new_stop;

  update app.shopping_items set planned_stop_id = new_stop,
    scheduled_store_name = store_name,
    scheduled_store_address_local = address_text,
    scheduled_store_source_url = p_source_url,
    updated_at = now() where id = i.id;
  update app.trip_days set route_revision = route_revision + 1 where id = d.id
    returning route_revision into new_rev;
  perform app.bump_trip(d.trip_id, 'day.itinerary_changed', d.id);
  perform app.bump_trip(d.trip_id, 'shopping.changed', i.id);
  return jsonb_build_object('status', 'scheduled', 'stop_id', new_stop,
    'day_id', d.id, 'route_revision', new_rev);
end;
$$;

revoke execute on function app.schedule_shopping_store(uuid,int,text,uuid,bigint,uuid)
  from public, anon;
grant execute on function app.schedule_shopping_store(uuid,int,text,uuid,bigint,uuid)
  to authenticated;
