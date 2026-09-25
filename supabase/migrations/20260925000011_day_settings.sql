-- Per-day settings (multi-country trips): each day has its own time zone and
-- transport mode. Changing either changes how routes are computed for that
-- day, so it bumps route_revision (open proposals for the day become stale).

create function app.update_day(
  p_day_id uuid,
  p_time_zone text default null,
  p_transport_mode app.transport_mode default null
) returns app.trip_days
language plpgsql security definer
set search_path = ''
as $$
declare
  d app.trip_days;
begin
  select * into d from app.trip_days where id = p_day_id for update;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);

  if p_time_zone is not null
     and not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'INVALID_TIME_ZONE' using errcode = 'PT422';
  end if;
  if (p_time_zone is null or p_time_zone = d.time_zone)
     and (p_transport_mode is null or p_transport_mode = d.transport_mode) then
    return d;
  end if;

  update app.trip_days
     set time_zone = coalesce(p_time_zone, time_zone),
         transport_mode = coalesce(p_transport_mode, transport_mode),
         route_revision = route_revision + 1
   where id = d.id
  returning * into d;
  perform app.bump_trip(d.trip_id, 'day.settings_changed', d.id);
  return d;
end;
$$;

revoke execute on function app.update_day(uuid, text, app.transport_mode) from public, anon;
grant execute on function app.update_day(uuid, text, app.transport_mode) to authenticated;
