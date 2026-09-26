-- 收藏可由使用者選日期排入旅程；沒有確認座標時保留為 pending_text。
-- 只新增單一停靠點，避免舊版 commit_itinerary 的整日替換語意誤刪其他行程。
alter table app.saved_places
  add column planned_stop_id uuid references app.stops(id) on delete set null,
  add column planned_client_op_id uuid;

create unique index saved_places_planned_stop_idx
  on app.saved_places(planned_stop_id) where planned_stop_id is not null;

-- 舊版 App 仍可用 commit_itinerary 修改行程；停靠點被移除時同步解除排程關聯。
create or replace function app.mark_saved_added() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.deleted_at is null and new.place_id is not null then
    update app.saved_places
       set status = 'added_to_itinerary', updated_at = now()
     where trip_id = new.trip_id and place_id = new.place_id and status = 'saved';
  end if;

  if tg_op = 'UPDATE' and old.deleted_at is null then
    if new.deleted_at is not null then
      update app.saved_places s
         set planned_stop_id = null,
             planned_client_op_id = null,
             status = case when s.place_id is not null and exists (
               select 1 from app.stops x where x.trip_id = s.trip_id
                 and x.place_id = s.place_id and x.deleted_at is null and x.id <> old.id
             ) then 'added_to_itinerary' else 'saved' end::app.saved_status,
             updated_at = now()
       where s.planned_stop_id = old.id and s.status <> 'dismissed';
    elsif new.place_id is not null and new.place_id is distinct from old.place_id then
      -- 使用者在行程裡定位待確認地點後，收藏也沿用該座標；不改其他旅程共用的 Place。
      update app.saved_places s
         set place_id = new.place_id, updated_at = now()
       where s.planned_stop_id = new.id and s.place_id is null and s.status <> 'dismissed'
         and not exists (
           select 1 from app.saved_places other
            where other.trip_id = s.trip_id and other.place_id = new.place_id
              and other.status <> 'dismissed' and other.id <> s.id
         );
    end if;

    if old.place_id is not null and new.place_id is distinct from old.place_id
       or old.place_id is not null and new.deleted_at is not null then
      update app.saved_places s
         set status = 'saved', updated_at = now()
       where s.trip_id = old.trip_id and s.place_id = old.place_id
         and s.status = 'added_to_itinerary' and s.planned_stop_id is null
         and not exists (
           select 1 from app.stops x where x.trip_id = old.trip_id
             and x.place_id = old.place_id and x.deleted_at is null and x.id <> old.id
         );
    end if;
  end if;
  return new;
end;
$$;

create function app.schedule_saved(
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

revoke execute on function app.schedule_saved(uuid,uuid,bigint,uuid,uuid,uuid)
  from public, anon;
grant execute on function app.schedule_saved(uuid,uuid,bigint,uuid,uuid,uuid)
  to authenticated;
