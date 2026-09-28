-- 已確認 AI 店家可沒有座標；地址與來源屬於此行程，不修改全旅程共用 places。
alter table app.stops add column destination_name text check(length(destination_name)<=500),
 add column destination_address text check(length(destination_address)<=2000),
 add column destination_source text check(length(destination_source)<=2000);
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
  select * into d from app.trip_days where id = p_day_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;

  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);

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
             destination_name = case when s ? 'destination_name' then s->>'destination_name' when raw_label=s->>'raw_label' and place_id is not distinct from place then destination_name end,
             destination_address = case when s ? 'destination_address' then s->>'destination_address' when raw_label=s->>'raw_label' and place_id is not distinct from place then destination_address end,
             destination_source = case when s ? 'destination_source' then s->>'destination_source' when raw_label=s->>'raw_label' and place_id is not distinct from place then destination_source end,
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
        dwell_minutes, fixed, kind, sort_order, added_by, destination_name, destination_address, destination_source
      ) values (
        d.trip_id, p_day_id, place, s ->> 'raw_label',
        case when place is null then 'pending_text' else 'resolved' end::app.resolution_status,
        (s ->> 'start_time')::time, (s ->> 'end_time')::time,
        (s ->> 'dwell_minutes')::int, coalesce((s ->> 'fixed')::boolean, false),
        coalesce(s ->> 'kind', 'standard')::app.stop_kind, pos, uid, s->>'destination_name', s->>'destination_address', s->>'destination_source'
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


notify pgrst,'reload schema';
