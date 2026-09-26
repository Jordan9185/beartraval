-- 商品辨識後的有來源店家線索跟著購物項目保存；不當作已確認販售或庫存。
alter table app.shopping_items
  add column store_suggestions jsonb not null default '[]'::jsonb
    check (jsonb_typeof(store_suggestions) = 'array' and jsonb_array_length(store_suggestions) <= 3),
  add column store_suggestions_checked boolean not null default false;

create function app.set_shopping_store_suggestions(p_item_id uuid, p_suggestions jsonb)
returns app.shopping_items language plpgsql security definer set search_path = '' as $$
declare i app.shopping_items;
begin
  select * into i from app.shopping_items where id = p_item_id and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(i.trip_id, array['owner', 'editor']::app.trip_role[]);
  if p_suggestions is null or jsonb_typeof(p_suggestions) <> 'array' then
    raise exception 'INVALID_STORE_SUGGESTIONS' using errcode = 'PT422';
  end if;
  if jsonb_array_length(p_suggestions) > 3 then
    raise exception 'INVALID_STORE_SUGGESTIONS' using errcode = 'PT422';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_suggestions) as s(value)
    where jsonb_typeof(s.value) is distinct from 'object'
       or jsonb_typeof(s.value -> 'name') is distinct from 'string'
       or length(btrim(coalesce(s.value ->> 'name', ''))) not between 2 and 120
       or jsonb_typeof(s.value -> 'search_query') is distinct from 'string'
       or length(btrim(coalesce(s.value ->> 'search_query', ''))) not between 2 and 200
       or jsonb_typeof(s.value -> 'reason') is distinct from 'string'
       or length(btrim(coalesce(s.value ->> 'reason', ''))) not between 2 and 250
       or jsonb_typeof(s.value -> 'source_url') is distinct from 'string'
       or length(coalesce(s.value ->> 'source_url', '')) > 2000
       or coalesce(s.value ->> 'source_url', '') !~ '^https://[^[:space:]]+$'
       or (s.value ? 'korean_name' and s.value -> 'korean_name' <> 'null'::jsonb
           and (jsonb_typeof(s.value -> 'korean_name') <> 'string'
                or length(s.value ->> 'korean_name') > 120))
       or (s.value ? 'address_local' and s.value -> 'address_local' <> 'null'::jsonb
           and (jsonb_typeof(s.value -> 'address_local') <> 'string'
                or length(s.value ->> 'address_local') > 300))
  ) then
    raise exception 'INVALID_STORE_SUGGESTIONS' using errcode = 'PT422';
  end if;
  update app.shopping_items
     set store_suggestions = p_suggestions, store_suggestions_checked = true, updated_at = now()
   where id = p_item_id returning * into i;
  perform app.bump_trip(i.trip_id, 'shopping.changed', i.id);
  return i;
end;
$$;

revoke execute on function app.set_shopping_store_suggestions(uuid,jsonb) from public, anon;
grant execute on function app.set_shopping_store_suggestions(uuid,jsonb) to authenticated;
