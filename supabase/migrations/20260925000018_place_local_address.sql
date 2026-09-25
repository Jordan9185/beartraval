-- Address in the local language (Korean, Japanese) for places.
--   address        provider address; Apple localises it to the searching device's
--                  language, so a Taiwanese phone gets 「南韓首爾特別市明洞…」
--   address_local  the same address written the local way (서울특별시 중구 …),
--                  shown on the taxi card and used when opening local maps
--
-- Same rules as the names: set on insert, and a missing value may be filled in
-- later only while no trip the caller isn't in uses the place.

alter table app.places add column address_local text check (length(address_local) <= 300);

drop function app.upsert_place(text, text, text, double precision, double precision, text, text, text, text);

create function app.upsert_place(
  p_provider text,
  p_provider_place_id text,
  p_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_name_local text default null,
  p_address text default null,
  p_country_code text default null,
  p_name_zh text default null,
  p_address_local text default null
) returns app.places
language plpgsql security definer
set search_path = ''
as $$
declare
  p app.places;
  key text := btrim(coalesce(p_provider_place_id, ''));
begin
  perform app.current_user_id();

  if p_provider is null or p_provider not in ('apple_mapkit', 'apple_maps_server') then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'unknown provider';
  end if;
  if length(key) = 0 or length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'id and name are required';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'coordinates out of range';
  end if;

  select * into p from app.places where provider = p_provider and provider_place_id = key;
  if found and app.distance_km(p.latitude, p.longitude, p_latitude, p_longitude) > 1 then
    key := key || '~' || left(md5(pg_catalog.format('%s|%s|%s', btrim(p_name), round(p_latitude::numeric, 4), round(p_longitude::numeric, 4))), 12);
    select * into p from app.places where provider = p_provider and provider_place_id = key;
  end if;

  if not found then
    insert into app.places (provider, provider_place_id, name, name_local, address, latitude, longitude, country_code, name_zh, address_local)
    values (p_provider, key, btrim(p_name), nullif(btrim(p_name_local), ''),
            nullif(btrim(p_address), ''), p_latitude, p_longitude, upper(nullif(btrim(p_country_code), '')),
            nullif(btrim(p_name_zh), ''), nullif(btrim(p_address_local), ''))
    on conflict (provider, provider_place_id) do nothing
    returning * into p;
    if p.id is null then
      select * into p from app.places where provider = p_provider and provider_place_id = key;
    end if;
    return p;
  end if;

  if (p.name_local is null or p.name_zh is null or p.address_local is null) and not app.place_used_by_others(p.id) then
    update app.places
       set name_local = coalesce(name_local, nullif(btrim(p_name_local), '')),
           name_zh = coalesce(name_zh, nullif(btrim(p_name_zh), '')),
           address_local = coalesce(address_local, nullif(btrim(p_address_local), ''))
     where id = p.id
    returning * into p;
  end if;
  return p;
end;
$$;

revoke execute on function
  app.upsert_place(text, text, text, double precision, double precision, text, text, text, text, text)
from public, anon;
grant execute on function
  app.upsert_place(text, text, text, double precision, double precision, text, text, text, text, text)
to authenticated;
