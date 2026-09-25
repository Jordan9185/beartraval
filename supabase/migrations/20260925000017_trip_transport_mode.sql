-- Whole-trip transport mode (walking / transit / driving = self-drive or taxi).
-- New trips default to transit, which Apple Maps can't estimate in Korea, so the
-- app lets the user pick a mode for the whole trip at creation or later.
-- Days whose mode changes bump route_revision (their open proposals go stale).

create function app.set_trip_transport_mode(p_trip_id uuid, p_transport_mode app.transport_mode) returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  changed int;
begin
  perform app.require_role(p_trip_id, array['owner', 'editor']::app.trip_role[]);
  if p_transport_mode is null then
    raise exception 'INVALID_MODE' using errcode = 'PT422';
  end if;
  update app.trip_days
     set transport_mode = p_transport_mode,
         route_revision = route_revision + 1
   where trip_id = p_trip_id and transport_mode <> p_transport_mode;
  get diagnostics changed = row_count;
  if changed > 0 then
    perform app.bump_trip(p_trip_id, 'day.settings_changed', p_trip_id);
  end if;
  return changed;
end;
$$;

revoke execute on function app.set_trip_transport_mode(uuid, app.transport_mode) from public, anon;
grant execute on function app.set_trip_transport_mode(uuid, app.transport_mode) to authenticated;
