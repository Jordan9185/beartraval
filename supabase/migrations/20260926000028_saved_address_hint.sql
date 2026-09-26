-- 辨識所得的地址保留在收藏項目，尚未定位時也可供使用者核對。
alter table app.saved_places
  add column address_hint text check (length(btrim(address_hint)) between 3 and 300),
  add column address_source_url text check (
    address_source_url is null or
    (length(address_source_url) <= 2000 and address_source_url ~ '^https://[^[:space:]]+$')
  );

create function app.set_saved_address_hint(p_saved_id uuid, p_address_hint text, p_source_url text default null)
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
  update app.saved_places
     set address_hint = btrim(p_address_hint), address_source_url = p_source_url, updated_at = now()
   where id = p_saved_id returning * into s;
  perform app.bump_trip(s.trip_id, 'saved.changed', s.id);
  return s;
end;
$$;

revoke execute on function app.set_saved_address_hint(uuid,text,text) from public, anon;
grant execute on function app.set_saved_address_hint(uuid,text,text) to authenticated;
