-- 原始譯名與有來源的當地名稱分開保存；不自動修改已確認行程。
alter table app.saved_places add column native_name text check (length(btrim(native_name)) between 1 and 120);
drop function app.set_saved_address_hint(uuid,text,text);
create function app.set_saved_address_hint(p_saved_id uuid, p_address_hint text, p_source_url text default null, p_native_name text default null)
returns app.saved_places language plpgsql security definer set search_path = '' as $$
declare s app.saved_places;
begin
  select * into s from app.saved_places where id = p_saved_id and status <> 'dismissed' for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(s.trip_id, array['owner', 'editor']::app.trip_role[]);
  if length(btrim(coalesce(p_address_hint, ''))) not between 3 and 300 or
     (p_source_url is not null and
       (length(p_source_url) > 2000 or p_source_url !~ '^https://[^[:space:]]+$')) then
    raise exception 'INVALID_ADDRESS_HINT' using errcode = 'PT422';
  end if;
  if p_native_name is not null and (p_source_url is null or length(btrim(p_native_name)) not between 1 and 120) then
    raise exception 'INVALID_NATIVE_NAME' using errcode = 'PT422';
  end if;
  update app.saved_places
     set address_hint = btrim(p_address_hint), address_source_url = p_source_url, native_name = nullif(btrim(p_native_name), ''), updated_at = now()
   where id = p_saved_id returning * into s;
  perform app.bump_trip(s.trip_id, 'saved.changed', s.id);
  return s;
end;
$$;

revoke execute on function app.set_saved_address_hint(uuid,text,text,text) from public, anon;
grant execute on function app.set_saved_address_hint(uuid,text,text,text) to authenticated;

create or replace function app.schedule_saved(
  p_saved_id uuid,
  p_day_id uuid,
  p_expected_route_revision bigint,
  p_client_op_id uuid,
  p_before_stop_id uuid default null,
  p_after_stop_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := app.current_user_id();
  d app.trip_days;
  s app.saved_places;
  existing app.stops;
  anchor app.stops;
  new_stop uuid;
  new_rev bigint;
  pos int;
  dwell int;
begin
  select * into d from app.trip_days where id = p_day_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);

  select * into s from app.saved_places where id = p_saved_id and trip_id = d.trip_id
    and status <> 'dismissed' for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;

  update app.saved_places set arrangement_detached=false where id=s.id;

  -- 同一收藏不重複排程；網路重送可安全取得前次結果。
  if s.planned_stop_id is not null then
    select * into existing from app.stops where id = s.planned_stop_id and deleted_at is null;
  end if;
  if existing.id is null and s.place_id is not null then
    select * into existing from app.stops where trip_id = s.trip_id
      and place_id = s.place_id and deleted_at is null order by created_at limit 1;
  end if;
  if existing.id is not null then
    if s.planned_stop_id is distinct from existing.id then
      update app.saved_places set planned_stop_id = existing.id,
        status = 'added_to_itinerary', updated_at = now() where id = s.id;
    end if;
    return jsonb_build_object('status', 'already_scheduled', 'stop_id', existing.id,
      'day_id', existing.day_id, 'route_revision', d.route_revision);
  end if;

  if p_expected_route_revision is null or p_client_op_id is null
     or (p_before_stop_id is not null and p_after_stop_id is not null) then
    raise exception 'INVALID_SCHEDULE' using errcode = 'PT422';
  end if;
  if d.route_revision <> p_expected_route_revision then
    raise exception 'STALE_REVISION' using errcode = 'PT409';
  end if;

  if p_before_stop_id is not null then
    select * into anchor from app.stops where id = p_before_stop_id
      and day_id = d.id and deleted_at is null;
    if not found then raise exception 'STOP_NOT_IN_DAY' using errcode = 'PT422'; end if;
    pos := anchor.sort_order;
  elsif p_after_stop_id is not null then
    select * into anchor from app.stops where id = p_after_stop_id
      and day_id = d.id and deleted_at is null;
    if not found then raise exception 'STOP_NOT_IN_DAY' using errcode = 'PT422'; end if;
    pos := anchor.sort_order + 1;
  else
    select coalesce(max(sort_order) + 1, 0) into pos from app.stops
      where day_id = d.id and deleted_at is null;
  end if;

  dwell := case s.category when 'cafe' then 45 when 'shop' then 30 else 60 end;
  update app.stops set sort_order = sort_order + 1, updated_at = now()
    where day_id = d.id and deleted_at is null and sort_order >= pos;
  insert into app.stops(trip_id, day_id, place_id, raw_label, resolution_status,
    dwell_minutes, fixed, kind, sort_order, added_by)
  values (d.trip_id, d.id, s.place_id, s.raw_label,
    case when s.place_id is null then 'pending_text' else 'resolved' end::app.resolution_status,
    dwell, false, 'standard', pos, uid)
  returning id into new_stop;
  update app.stops set created_from_saved_id=s.id,destination_name=coalesce(s.native_name,s.raw_label),
    destination_address=s.address_hint,destination_source=s.address_source_url where id=new_stop;

  update app.saved_places set planned_stop_id = new_stop,
    planned_client_op_id = p_client_op_id, status = 'added_to_itinerary', updated_at = now()
    where id = s.id;
  update app.trip_days set route_revision = route_revision + 1 where id = d.id
    returning route_revision into new_rev;
  perform app.bump_trip(d.trip_id, 'day.itinerary_changed', d.id);
  perform app.bump_trip(d.trip_id, 'saved.changed', s.id);
  return jsonb_build_object('status', 'scheduled', 'stop_id', new_stop,
    'day_id', d.id, 'route_revision', new_rev);
end;
$$;


