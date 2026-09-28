-- 背景補查只填空白；舊呼叫仍保留明確覆寫語意。
drop function app.set_saved_address_hint(uuid,text,text,text);
create function app.set_saved_address_hint(p_saved_id uuid, p_address_hint text, p_source_url text default null, p_native_name text default null, p_only_if_missing boolean default false)
returns app.saved_places language plpgsql security definer set search_path = '' as $$
declare s app.saved_places;
begin
  select * into s from app.saved_places where id = p_saved_id and status <> 'dismissed' for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(s.trip_id, array['owner', 'editor']::app.trip_role[]);
  -- 背景 AI 晚回時，保留旅伴先保存的地址及其原名／來源，不改正式行程。
  if p_only_if_missing and s.address_hint is not null then return s; end if;
  if length(btrim(coalesce(p_address_hint, ''))) not between 3 and 300 or
     (p_source_url is not null and
       (length(p_source_url) > 2000 or p_source_url !~ '^https://[^[:space:]]+$')) then
    raise exception 'INVALID_ADDRESS_HINT' using errcode = 'PT422';
  end if;
  if p_native_name is not null and (p_source_url is null or length(btrim(p_native_name)) not between 1 and 120) then
    raise exception 'INVALID_NATIVE_NAME' using errcode = 'PT422';
  end if;
  update app.saved_places
     set address_hint = btrim(p_address_hint), address_source_url = p_source_url, native_name = nullif(btrim(p_native_name), ''), updated_at = now()
   where id = p_saved_id returning * into s;
  perform app.bump_trip(s.trip_id, 'saved.changed', s.id);
  return s;
end;
$$;

revoke execute on function app.set_saved_address_hint(uuid,text,text,text,boolean) from public, anon;
grant execute on function app.set_saved_address_hint(uuid,text,text,text,boolean) to authenticated;

notify pgrst,'reload schema';
