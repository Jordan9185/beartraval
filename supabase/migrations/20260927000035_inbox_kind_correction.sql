-- 舊 App 仍可省略 p_kind；更正只改個人清單，不搬動旅伴清單或正式行程。
drop function app.update_inbox_item(uuid,int,text,boolean);
create function app.update_inbox_item(p_item_id uuid, p_expected_revision int,
  p_display_name text default null, p_archived boolean default null, p_kind text default null)
returns app.inbox_items language plpgsql security definer set search_path = '' as $$
declare uid uuid := app.current_user_id(); i app.inbox_items; changed boolean;
begin
  select x.* into i from app.inbox_items x join app.inbox_captures c on c.id = x.capture_id
   where x.id = p_item_id and c.owner_id = uid for update of x;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  if i.revision <> p_expected_revision then raise exception 'STALE_REVISION' using errcode = 'PT409'; end if;
  if p_display_name is not null and length(btrim(p_display_name)) not between 1 and 200 then
    raise exception 'INVALID_NAME' using errcode = 'PT422';
  end if;
  if p_kind is not null and p_kind not in ('place','product') then
    raise exception 'INVALID_KIND' using errcode = 'PT422';
  end if;
  changed := (p_kind is not null and p_kind <> i.kind)
    or (p_display_name is not null and btrim(p_display_name) <> i.display_name);
  update app.inbox_items set display_name = coalesce(btrim(p_display_name), display_name),
    kind = coalesce(p_kind, kind), archived = coalesce(p_archived, archived),
    user_corrected = true, revision = revision + 1,
    place_id = case when changed then null else place_id end,
    resolution_status = case when changed then 'unresolved' else resolution_status end,
    discovery_candidates = case when changed then null else discovery_candidates end,
    discovery_checked_at = case when changed then null else discovery_checked_at end,
    store_hint = case when changed then null else store_hint end,
    store_evidence = case when changed then null else store_evidence end
   where id = p_item_id returning * into i;
  return i;
end; $$;
revoke all on function app.update_inbox_item(uuid,int,text,boolean,text) from public, anon;
grant execute on function app.update_inbox_item(uuid,int,text,boolean,text) to authenticated;
notify pgrst, 'reload schema';
