-- 同一來源網頁可能列多間分店；新 App 需連店名與地址一併核對，避免候選重排後選錯店。
-- 保留六參數版本供已安裝的 App 使用。
create function app.schedule_shopping_store(
  p_item_id uuid,
  p_suggestion_index int,
  p_source_url text,
  p_expected_store_name text,
  p_day_id uuid,
  p_expected_route_revision bigint,
  p_client_op_id uuid,
  p_expected_address_local text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d app.trip_days;
  i app.shopping_items;
  candidate jsonb;
  store_name text;
  address_text text;
begin
  select * into d from app.trip_days where id = p_day_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);
  select * into i from app.shopping_items where id = p_item_id
    and trip_id = d.trip_id and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;

  if i.planned_stop_id is null then
    if p_suggestion_index is null or p_suggestion_index < 0 or p_suggestion_index > 2 then
      raise exception 'INVALID_STORE_SUGGESTION' using errcode = 'PT422';
    end if;
    candidate := i.store_suggestions -> p_suggestion_index;
    store_name := coalesce(nullif(btrim(candidate ->> 'korean_name'), ''),
                           nullif(btrim(candidate ->> 'name'), ''));
    address_text := nullif(btrim(candidate ->> 'address_local'), '');
    if candidate is null or candidate ->> 'source_url' is distinct from p_source_url
       or store_name is distinct from nullif(btrim(p_expected_store_name), '')
       or address_text is distinct from nullif(btrim(p_expected_address_local), '') then
      raise exception 'STALE_STORE_SUGGESTION' using errcode = 'PT409';
    end if;
  end if;
  return app.schedule_shopping_store(p_item_id, p_suggestion_index, p_source_url,
    p_day_id, p_expected_route_revision, p_client_op_id);
end;
$$;

revoke execute on function app.schedule_shopping_store(uuid,int,text,text,uuid,bigint,uuid,text)
  from public, anon;
grant execute on function app.schedule_shopping_store(uuid,int,text,text,uuid,bigint,uuid,text)
  to authenticated;
