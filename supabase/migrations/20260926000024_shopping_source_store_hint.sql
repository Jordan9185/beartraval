-- 分享內容明確提到的店名只作候選線索，不能當成已證實販售或庫存。
alter table app.inbox_items
  add column store_hint text check (length(store_hint) between 1 and 200),
  add column store_evidence text check (length(store_evidence) between 1 and 500);

alter table app.shopping_items
  add column store_hint text check (length(store_hint) between 1 and 200),
  add column store_evidence text check (length(store_evidence) between 1 and 500);

create function app.set_shopping_store_hint(p_item_id uuid, p_store_hint text, p_store_evidence text default null)
returns app.shopping_items language plpgsql security definer set search_path = '' as $$
declare i app.shopping_items;
begin
  select * into i from app.shopping_items where id = p_item_id and deleted_at is null for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  perform app.require_role(i.trip_id, array['owner', 'editor']::app.trip_role[]);
  if length(btrim(coalesce(p_store_hint, ''))) not between 1 and 200
     or length(coalesce(p_store_evidence, '')) > 500 then
    raise exception 'INVALID_STORE_HINT' using errcode = 'PT422';
  end if;
  update app.shopping_items set store_hint = btrim(p_store_hint),
    store_evidence = nullif(btrim(p_store_evidence), ''), updated_at = now()
   where id = p_item_id returning * into i;
  perform app.bump_trip(i.trip_id, 'shopping.changed', i.id);
  return i;
end;
$$;

revoke execute on function app.set_shopping_store_hint(uuid,text,text) from public, anon;
grant execute on function app.set_shopping_store_hint(uuid,text,text) to authenticated;
