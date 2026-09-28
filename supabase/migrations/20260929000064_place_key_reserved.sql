-- 資安修正：共用地點快取的替代 key 可被用戶端預先建立，繞過「同 id 座標差 1 km 另建一列」的防護。
-- 保留字元 `~` 只由服務端產生；命中的替代列也再核對距離。既有列、參數與回傳型別不變，舊 App 相容。
create or replace function app.upsert_place(p_provider text, p_provider_place_id text, p_name text, p_latitude double precision, p_longitude double precision, p_name_local text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_country_code text DEFAULT NULL::text, p_name_zh text DEFAULT NULL::text, p_address_local text DEFAULT NULL::text)
 RETURNS app.places
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- `~` 保留給服務端產生的替代列，用戶端不能預先建立，避免搶註替代 key 繞過 1 km 檢查。
  if position('~' in key) > 0 then
    raise exception 'INVALID_PLACE' using errcode = 'PT422', detail = 'reserved character in id';
  end if;

  select * into p from app.places where provider = p_provider and provider_place_id = key;
  if found and app.distance_km(p.latitude, p.longitude, p_latitude, p_longitude) > 1 then
    key := key || '~' || left(md5(pg_catalog.format('%s|%s|%s', btrim(p_name), round(p_latitude::numeric, 4), round(p_longitude::numeric, 4))), 12);
    select * into p from app.places where provider = p_provider and provider_place_id = key;
    -- 替代列同樣要在 1 km 內；修正前被預先植入的替代列不沿用，改為此帳號專屬的列。
    if found and app.distance_km(p.latitude, p.longitude, p_latitude, p_longitude) > 1 then
      key := key || '~u' || left(md5(app.current_user_id()::text), 12);
      select * into p from app.places where provider = p_provider and provider_place_id = key;
    end if;
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
$function$;

notify pgrst, 'reload schema';
