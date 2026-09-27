-- 使用者確認 AI 店名／地址，與地圖座標驗證分開保存；舊 App 可忽略新欄位。
alter table app.inbox_items add column confirmed_discovery jsonb
  check (confirmed_discovery is null or jsonb_typeof(confirmed_discovery) = 'object');

create function app.confirm_inbox_discovery(p_item_id uuid, p_expected_revision int, p_candidate_index int)
returns app.inbox_items language plpgsql security definer set search_path = '' as $$
declare i app.inbox_items; choice jsonb;
begin
  select x.* into i from app.inbox_items x join app.inbox_captures c on c.id = x.capture_id
    where x.id = p_item_id and c.owner_id = app.current_user_id() for update of x;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  if i.revision <> p_expected_revision then raise exception 'STALE_REVISION' using errcode = 'PT409'; end if;
  if i.kind <> 'place' or i.place_id is not null then raise exception 'INVALID_ITEM' using errcode = 'PT422'; end if;
  if p_candidate_index is null or p_candidate_index < 0 then raise exception 'INVALID_CANDIDATE' using errcode = 'PT422'; end if;
  choice := i.discovery_candidates -> p_candidate_index;
  if choice is null or jsonb_typeof(choice) <> 'object'
    or nullif(btrim(choice ->> 'name'),'') is null
    or coalesce(choice ->> 'source_url','') not like 'https://%' then
    raise exception 'INVALID_CANDIDATE' using errcode = 'PT422';
  end if;
  update app.inbox_items set confirmed_discovery = choice, archived = true,
    user_corrected = true, revision = revision + 1 where id = i.id returning * into i;
  return i;
end; $$;
revoke all on function app.confirm_inbox_discovery(uuid,int,int) from public, anon;
grant execute on function app.confirm_inbox_discovery(uuid,int,int) to authenticated;

-- 改名、改分類或明確選定其他地圖地點後，原候選確認不再適用。
create function app.clear_inbox_discovery_confirmation() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.display_name is distinct from old.display_name or new.kind is distinct from old.kind
     or new.place_id is distinct from old.place_id then
    new.confirmed_discovery := null;
  end if;
  return new;
end; $$;
create trigger inbox_discovery_confirmation before update of display_name,kind,place_id on app.inbox_items
  for each row execute function app.clear_inbox_discovery_confirmation();
notify pgrst, 'reload schema';
