-- Chinese display name for places (UI 以繁體中文呈現；店名保留原文並附中文).
--   name       provider name (depends on the device language that searched)
--   name_local original name in the local language (Korean, Japanese)
--   name_zh    Traditional Chinese name shown next to the original

alter table app.places add column name_zh text check (length(name_zh) <= 200);

drop function app.upsert_place(text, text, text, double precision, double precision, text, text, text);

-- First writer still wins for identity fields; missing local/Chinese names may
-- be filled in later (never overwritten), so a later search in another
-- language can complete a place without anyone renaming it.
create function app.upsert_place(
  p_provider text,
  p_provider_place_id text,
  p_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_name_local text default null,
  p_address text default null,
  p_country_code text default null,
  p_name_zh text default null
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

  insert into app.places (provider, provider_place_id, name, name_local, address, latitude, longitude, country_code, name_zh)
  values (p_provider, btrim(p_provider_place_id), btrim(p_name), nullif(btrim(p_name_local), ''),
          nullif(btrim(p_address), ''), p_latitude, p_longitude, upper(nullif(btrim(p_country_code), '')),
          nullif(btrim(p_name_zh), ''))
  on conflict (provider, provider_place_id) do update
    set name_local = coalesce(app.places.name_local, excluded.name_local),
        name_zh = coalesce(app.places.name_zh, excluded.name_zh)
  returning * into p;

  return p;
end;
$$;

revoke execute on function
  app.upsert_place(text, text, text, double precision, double precision, text, text, text, text)
from public, anon;
grant execute on function
  app.upsert_place(text, text, text, double precision, double precision, text, text, text, text)
to authenticated;
