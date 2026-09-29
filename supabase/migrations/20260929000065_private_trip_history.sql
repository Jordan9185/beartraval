-- C06（產品擁有者 2026-09-29 決定：保留本人私人歷史）。
-- 退出／被移出旅程或旅程被刪除時，把該成員「自己的」私人用品與私人採買另存一份唯讀快照。
-- 快照只屬於本人：旅伴與原旅程都讀不到；不複製任何共同資料；本人可刪除；刪帳號時隨帳號一併清除。
create table app.private_trip_history (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  -- 原旅程可能已刪除，只作識別與去重，不設外鍵。
  trip_id uuid not null,
  trip_name text not null,
  start_date date,
  end_date date,
  reason text not null check (reason in ('left', 'trip_deleted')),
  packing jsonb not null default '[]',
  purchases jsonb not null default '[]',
  created_at timestamptz not null default now()
);
create index private_trip_history_owner on app.private_trip_history(owner_id, created_at desc);
alter table app.private_trip_history enable row level security;
revoke all on app.private_trip_history from public, anon, authenticated;
grant select on app.private_trip_history to authenticated;
create policy private_history_own_read on app.private_trip_history for select to authenticated using (owner_id = auth.uid());

-- 快照內容只取本人私人用品（shared = false）與本人私人採買；兩者皆無則不建立紀錄。
create function app.snapshot_private_history(p_trip app.trips, p_user uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare packing jsonb; purchases jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'quantity', quantity, 'note', nullif(note, ''),
           'packed', packed) order by name), '[]')
    into packing from app.packing_items
   where trip_id = p_trip.id and owner_id = p_user and not shared and deleted_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'desired_quantity', desired_quantity,
           'bought_quantity', bought_quantity, 'purchase_timing', purchase_timing) order by name), '[]')
    into purchases from app.personal_purchases
   where trip_id = p_trip.id and owner_id = p_user;
  if packing = '[]'::jsonb and purchases = '[]'::jsonb then return; end if;
  -- 同一旅程同一原因只留最新一份，避免反覆退出／加入累積重複紀錄。
  delete from app.private_trip_history where owner_id = p_user and trip_id = p_trip.id and reason = p_reason;
  insert into app.private_trip_history(owner_id, trip_id, trip_name, start_date, end_date, reason, packing, purchases)
  values (p_user, p_trip.id, p_trip.name, p_trip.start_date, p_trip.end_date, p_reason, packing, purchases);
end $$;
revoke all on function app.snapshot_private_history(app.trips, uuid, text) from public, anon, authenticated;

create function app.keep_private_history_on_departure() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t app.trips;
begin
  select * into t from app.trips where id = new.trip_id;
  if old.status = 'active' and new.status <> 'active' then
    perform app.snapshot_private_history(t, new.user_id, 'left');
  elsif old.status <> 'active' and new.status = 'active' then
    -- 重新加入後原私人資料重新可見，移除退出時的快照，避免同一份資料出現兩處。
    delete from app.private_trip_history where owner_id = new.user_id and trip_id = new.trip_id and reason = 'left';
  end if;
  return new;
end $$;
revoke all on function app.keep_private_history_on_departure() from public, anon, authenticated;
create trigger keep_private_history_on_departure after update of status on app.trip_members
  for each row when (old.status is distinct from new.status) execute function app.keep_private_history_on_departure();

-- 旅程刪除前（子資料仍在）為每位仍在旅程中的成員留存各自的私人資料。
create function app.keep_private_history_on_trip_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
declare m record;
begin
  for m in select user_id from app.trip_members where trip_id = old.id and status = 'active' loop
    perform app.snapshot_private_history(old, m.user_id, 'trip_deleted');
  end loop;
  return old;
end $$;
revoke all on function app.keep_private_history_on_trip_delete() from public, anon, authenticated;
create trigger keep_private_history_on_trip_delete before delete on app.trips
  for each row execute function app.keep_private_history_on_trip_delete();

-- 本人明確刪除一份快照；刪除後無法復原。
create function app.delete_private_history(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from app.private_trip_history where id = p_id and owner_id = app.current_user_id();
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
end $$;
revoke all on function app.delete_private_history(uuid) from public, anon;
grant execute on function app.delete_private_history(uuid) to authenticated;
notify pgrst, 'reload schema';
