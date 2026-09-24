-- Lets clients register a confirmed POI before referencing it from a stop.
--
-- places is a shared cache of public business data keyed by (provider,
-- provider_place_id). The first writer wins: an existing row is returned as-is,
-- so one user cannot rename or move a place that other trips already use.

create function app.upsert_place(
  p_provider text,
  p_provider_place_id text,
  p_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_name_local text default null,
  p_address text default null,
  p_country_code text default null
) returns app.places
language plpgsql security definer
set search_path = ''
as $$
declare
  p app.places;
begin
  perform app.current_user_id();

  if p_provider is null or p_provider not in ('apple_mapkit', 'apple_maps_server') then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'unknown provider';
  end if;
  if length(btrim(coalesce(p_provider_place_id, ''))) = 0
     or length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'id and name are required';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'coordinates out of range';
  end if;

  insert into app.places (provider, provider_place_id, name, name_local, address, latitude, longitude, country_code)
  values (p_provider, btrim(p_provider_place_id), btrim(p_name), nullif(btrim(p_name_local), ''),
          nullif(btrim(p_address), ''), p_latitude, p_longitude, upper(nullif(btrim(p_country_code), '')))
  on conflict (provider, provider_place_id) do nothing
  returning * into p;

  if p.id is null then
    select * into p from app.places
     where provider = p_provider and provider_place_id = btrim(p_provider_place_id);
  end if;

  return p;
end;
$$;

revoke execute on function
  app.upsert_place(text, text, text, double precision, double precision, text, text, text)
from public, anon;

grant execute on function
  app.upsert_place(text, text, text, double precision, double precision, text, text, text)
to authenticated;
