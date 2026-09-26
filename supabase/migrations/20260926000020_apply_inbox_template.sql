-- 模板只能在使用者明確確認後套用；提交時重新檢查模板與每一天的版本。
create table app.inbox_template_applications (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  template_id uuid not null references app.itinerary_templates(id) on delete cascade,
  trip_id uuid not null references app.trips(id) on delete cascade,
  client_op_id uuid not null,
  created_at timestamptz not null default now(),
  unique(owner_id, client_op_id)
);
alter table app.inbox_template_applications enable row level security;
create policy inbox_template_applications_owner_read on app.inbox_template_applications
  for select to authenticated using (owner_id = auth.uid());
grant select on app.inbox_template_applications to authenticated;
revoke insert, update, delete, truncate on app.inbox_template_applications from authenticated, anon;

create function app.apply_inbox_template(
  p_template_id uuid,
  p_expected_template_revision int,
  p_client_op_id uuid,
  p_trip_id uuid default null,
  p_start_date date default null,
  p_time_zone text default null,
  p_expected_day_revisions jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := app.current_user_id();
  t app.itinerary_templates;
  existing app.inbox_template_applications;
  target app.trips;
  day_entry jsonb;
  stop_entry jsonb;
  target_day app.trip_days;
  day_number int;
  max_day int := 0;
  seen int[] := '{}';
  new_stops jsonb;
  old_stops jsonb;
  expected int;
begin
  if p_client_op_id is null then raise exception 'INVALID_REQUEST' using errcode = 'PT422'; end if;
  select * into existing from app.inbox_template_applications
   where owner_id = uid and client_op_id = p_client_op_id;
  if found then return jsonb_build_object('trip_id', existing.trip_id, 'duplicate', true); end if;

  select * into t from app.itinerary_templates where id = p_template_id and owner_id = uid for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  if t.revision <> p_expected_template_revision then raise exception 'STALE_REVISION' using errcode = 'PT409'; end if;
  if jsonb_typeof(t.draft -> 'days') <> 'array' or jsonb_array_length(t.draft -> 'days') = 0
     or jsonb_array_length(t.draft -> 'days') > 30 then
    raise exception 'INVALID_TEMPLATE' using errcode = 'PT422';
  end if;
  for day_entry in select value from jsonb_array_elements(t.draft -> 'days') loop
    day_number := nullif(day_entry ->> 'day_index', '')::int;
    if day_number is null or day_number not between 1 and 30 or day_number = any(seen)
       or jsonb_typeof(day_entry -> 'stops') <> 'array' then
      raise exception 'DAY_UNASSIGNED' using errcode = 'PT422';
    end if;
    seen := seen || day_number;
    max_day := greatest(max_day, day_number);
    for stop_entry in select value from jsonb_array_elements(day_entry -> 'stops') loop
      if length(btrim(coalesce(stop_entry ->> 'label', ''))) not between 1 and 200 then
        raise exception 'INVALID_STOPS' using errcode = 'PT422';
      end if;
    end loop;
  end loop;

  if p_trip_id is null then
    if p_start_date is null or p_time_zone is null then
      raise exception 'TRIP_DATE_REQUIRED' using errcode = 'PT422';
    end if;
    target := app.create_trip(t.title, p_start_date, p_start_date + max_day - 1, p_time_zone);
  else
    select * into target from app.trips where id = p_trip_id;
    if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
    perform app.require_role(target.id, array['owner', 'editor']::app.trip_role[]);
    if (select count(*) from app.trip_days where trip_id = target.id) < max_day then
      raise exception 'TRIP_TOO_SHORT' using errcode = 'PT422';
    end if;
  end if;

  -- 固定行程不搬動。先鎖定並檢查所有受影響的日子；任何一日過期就整筆交易回滾。
  for target_day in select d.* from app.trip_days d where d.trip_id = target.id
    and d.display_order + 1 = any(seen) order by d.id for update loop
    if p_trip_id is not null then
      expected := nullif(p_expected_day_revisions ->> target_day.id::text, '')::int;
      if expected is null or expected <> target_day.route_revision then
        raise exception 'STALE_REVISION' using errcode = 'PT409';
      end if;
    end if;
  end loop;

  for day_entry in select value from jsonb_array_elements(t.draft -> 'days') loop
    day_number := (day_entry ->> 'day_index')::int;
    select * into target_day from app.trip_days where trip_id = target.id and display_order = day_number - 1;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'place_id', s.place_id, 'raw_label', s.raw_label,
      'start_time', s.start_time, 'end_time', s.end_time,
      'dwell_minutes', s.dwell_minutes, 'fixed', s.fixed, 'kind', s.kind
    ) order by s.sort_order), '[]'::jsonb) into old_stops
      from app.stops s where s.day_id = target_day.id and s.deleted_at is null;
    select coalesce(jsonb_agg(jsonb_build_object(
      'raw_label', btrim(value ->> 'label'), 'fixed', false, 'kind', 'standard'
    ) order by ordinality), '[]'::jsonb) into new_stops
      from jsonb_array_elements(day_entry -> 'stops') with ordinality;
    if jsonb_array_length(new_stops) > 0 then
      perform app.commit_itinerary(target_day.id, target_day.route_revision, old_stops || new_stops);
    end if;
  end loop;
  insert into app.inbox_template_applications(owner_id, template_id, trip_id, client_op_id)
  values (uid, t.id, target.id, p_client_op_id);
  return jsonb_build_object('trip_id', target.id, 'duplicate', false);
end;
$$;

revoke execute on function app.apply_inbox_template(uuid,int,uuid,uuid,date,text,jsonb)
  from public, anon, authenticated;
grant execute on function app.apply_inbox_template(uuid,int,uuid,uuid,date,text,jsonb) to authenticated;

-- 只有歸屬帳號能確認 MapKit 地點；未確認項目不參與任何路線計算。
create function app.confirm_inbox_place(p_item_id uuid, p_expected_revision int, p_place_id uuid)
returns app.inbox_items language plpgsql security definer set search_path = '' as $$
declare uid uuid := app.current_user_id(); i app.inbox_items;
begin
  select x.* into i from app.inbox_items x join app.inbox_captures c on c.id = x.capture_id
   where x.id = p_item_id and c.owner_id = uid for update of x;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  if i.kind <> 'place' or p_place_id is null or not exists (select 1 from app.places where id = p_place_id) then
    raise exception 'INVALID_PLACE' using errcode = 'PT422';
  end if;
  if i.revision <> p_expected_revision then raise exception 'STALE_REVISION' using errcode = 'PT409'; end if;
  update app.inbox_items set place_id = p_place_id, resolution_status = 'verified',
    revision = revision + 1 where id = p_item_id returning * into i;
  return i;
end;
$$;
revoke execute on function app.confirm_inbox_place(uuid,int,uuid) from public, anon, authenticated;
grant execute on function app.confirm_inbox_place(uuid,int,uuid) to authenticated;
