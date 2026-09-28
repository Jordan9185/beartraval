-- 用品與個人封存：私人物品不出現在旅伴的查詢／同步內容中。
create table app.packing_items (
  id uuid primary key,
  trip_id uuid not null references app.trips(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  shared boolean not null default false,
  name text not null check (length(trim(name)) between 1 and 120),
  quantity integer not null default 1 check (quantity between 1 and 999),
  note text not null default '' check (length(note) <= 2000),
  packed boolean not null default false,
  carrier_id uuid references auth.users(id) on delete set null,
  buyer_id uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  revision integer not null default 1,
  last_operation_id uuid,
  deleted_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table app.packing_items enable row level security;
grant select on app.packing_items to authenticated;
create policy packing_read on app.packing_items for select to authenticated using (
  app.trip_role_of(trip_id) is not null and (shared or owner_id = auth.uid())
);
create function app.save_packing_item(p_id uuid, p_trip_id uuid, p_expected_revision integer,
  p_name text, p_quantity integer, p_note text, p_shared boolean, p_packed boolean,
  p_carrier_id uuid default null, p_buyer_id uuid default null, p_deleted boolean default false, p_client_op_id uuid default null)
returns app.packing_items language plpgsql security definer set search_path = '' as $$
declare old app.packing_items; result app.packing_items; changed boolean;
begin
  perform pg_advisory_xact_lock(hashtext('packing:' || p_id::text));
  select * into old from app.packing_items where id = p_id for update;
  if old.id is not null and (old.trip_id <> p_trip_id or (not old.shared and old.owner_id <> auth.uid())) then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(p_trip_id, array['owner','editor']::app.trip_role[]);
  if p_client_op_id is not null and old.last_operation_id = p_client_op_id and old.updated_by = auth.uid() then return old; end if;
  if old.id is null and p_expected_revision is distinct from 0 or old.id is not null and old.revision is distinct from p_expected_revision then
    raise exception 'STALE_REVISION' using errcode = 'PT409';
  end if;
  -- 共享範圍建立時選定；不讓其他旅伴把共同項目變成自己的私人資料。
  if old.id is not null and old.shared <> p_shared then raise exception 'INVALID_ITEM' using errcode = 'PT422'; end if;
  if p_name is null or length(trim(p_name)) not between 1 and 120 or p_quantity is null
    or p_quantity not between 1 and 999 or length(coalesce(p_note,'')) > 2000 then
    raise exception 'INVALID_ITEM' using errcode = 'PT422';
  end if;
  if exists(select 1 from unnest(array[p_carrier_id,p_buyer_id]) u where u is not null and (
    (not p_shared and u <> auth.uid()) or not exists(select 1 from app.trip_members m
      where m.trip_id = p_trip_id and m.user_id = u and m.status = 'active'))) then
    raise exception 'FORBIDDEN_ROLE' using errcode = 'PT403';
  end if;
  changed := old.id is not null and (old.name <> trim(p_name) or p_quantity > old.quantity or old.carrier_id is distinct from p_carrier_id);
  insert into app.packing_items(id,trip_id,owner_id,shared,name,quantity,note,packed,carrier_id,buyer_id,updated_by,deleted_at,last_operation_id)
    values(p_id,p_trip_id,auth.uid(),p_shared,trim(p_name),p_quantity,coalesce(p_note,''),p_packed,p_carrier_id,p_buyer_id,auth.uid(),case when p_deleted then now() end,p_client_op_id)
    on conflict(id) do update set name = excluded.name, quantity = excluded.quantity, note = excluded.note,
      packed = case when changed then false else excluded.packed end, carrier_id = excluded.carrier_id,
      buyer_id = excluded.buyer_id, updated_by = auth.uid(), revision = old.revision + 1,
      deleted_at = excluded.deleted_at, last_operation_id = p_client_op_id, updated_at = now() returning * into result;
  if p_shared then perform app.bump_trip(p_trip_id,'packing.changed',p_id); end if;
  return result;
end; $$;
revoke all on function app.save_packing_item(uuid,uuid,integer,text,integer,text,boolean,boolean,uuid,uuid,boolean,uuid) from public,anon;
grant execute on function app.save_packing_item(uuid,uuid,integer,text,integer,text,boolean,boolean,uuid,uuid,boolean,uuid) to authenticated;

create table app.trip_archives (
  user_id uuid not null references auth.users(id) on delete cascade,
  trip_id uuid not null references app.trips(id) on delete cascade,
  archived_at timestamptz not null default now(),
  primary key(user_id,trip_id)
);
alter table app.trip_archives enable row level security;
grant select on app.trip_archives to authenticated;
create policy archive_read on app.trip_archives for select to authenticated using (user_id = auth.uid());
create function app.set_trip_archived(p_trip_id uuid,p_archived boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_role(p_trip_id,array['owner','editor','viewer']::app.trip_role[]);
  if p_archived then insert into app.trip_archives(user_id,trip_id) values(auth.uid(),p_trip_id) on conflict do nothing;
  else delete from app.trip_archives where user_id = auth.uid() and trip_id = p_trip_id; end if;
end; $$;
revoke all on function app.set_trip_archived(uuid,boolean) from public,anon;
grant execute on function app.set_trip_archived(uuid,boolean) to authenticated;
notify pgrst, 'reload schema';
