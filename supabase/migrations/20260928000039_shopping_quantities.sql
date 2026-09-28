-- 買齊與打包獨立。舊版整項勾選仍轉成需求總量，部分購買另以數量保存。
alter table app.shopping_items add column desired_quantity integer not null default 1 check(desired_quantity between 1 and 999);
alter table app.shopping_items add column bought_quantity integer not null default 0 check(bought_quantity between 0 and 999);
alter table app.shopping_items add column quantity_revision integer not null default 0;
alter table app.shopping_items add column buyer_id uuid references auth.users(id) on delete set null;
update app.shopping_items i set bought_quantity=1 where
 (select type from app.purchase_events where item_id=i.id order by id desc limit 1)='purchased';
create function app.sync_purchase_quantity() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update app.shopping_items set bought_quantity=case when new.type='purchased' then desired_quantity else 0 end,
 quantity_revision=quantity_revision+1 where id=new.item_id;
 return new;
end; $$;
create trigger purchase_quantity after insert on app.purchase_events for each row execute function app.sync_purchase_quantity();
create table app.shopping_demands (
 item_id uuid not null references app.shopping_items(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 quantity integer not null check(quantity between 1 and 999),
 primary key(item_id,user_id)
);
alter table app.shopping_demands enable row level security;
grant select on app.shopping_demands to authenticated;
create policy demand_read on app.shopping_demands for select to authenticated using(exists(
 select 1 from app.shopping_items i where i.id=item_id and app.trip_role_of(i.trip_id) is not null));
create function app.set_shopping_quantities(p_item_id uuid,p_expected_revision integer,p_desired integer,p_bought integer,
 p_buyer_id uuid default null,p_demands jsonb default '[]',p_client_op_id uuid default null)
returns app.shopping_items language plpgsql security definer set search_path='' as $$
declare i app.shopping_items; demand jsonb; total integer;
begin
 select * into i from app.shopping_items where id=p_item_id and deleted_at is null for update;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 perform app.require_role(i.trip_id,array['owner','editor']::app.trip_role[]);
 if p_client_op_id is not null and exists(select 1 from app.purchase_events where client_op_id=p_client_op_id and item_id=i.id) then return i; end if;
 if i.quantity_revision is distinct from p_expected_revision then raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 if p_desired is null or p_bought is null or p_desired not between 1 and 999 or p_bought not between 0 and 999
   or jsonb_typeof(p_demands) is distinct from 'array' then raise exception 'INVALID_ITEM' using errcode='PT422'; end if;
 if p_buyer_id is not null and not exists(select 1 from app.trip_members where trip_id=i.trip_id and user_id=p_buyer_id and status='active') then
 raise exception 'FORBIDDEN_ROLE' using errcode='PT403'; end if;
 total := 0;
 delete from app.shopping_demands where item_id=i.id;
 for demand in select value from jsonb_array_elements(p_demands) loop
   if not exists(select 1 from app.trip_members where trip_id=i.trip_id and user_id=(demand->>'user_id')::uuid and status='active')
      or (demand->>'quantity')::integer not between 1 and 999 then raise exception 'INVALID_ITEM' using errcode='PT422'; end if;
   insert into app.shopping_demands values(i.id,(demand->>'user_id')::uuid,(demand->>'quantity')::integer);
   total := total + (demand->>'quantity')::integer;
 end loop;
 if total>0 and total<>p_desired then raise exception 'INVALID_ITEM' using errcode='PT422'; end if;
 insert into app.purchase_events(item_id,actor_id,type,client_op_id) values(i.id,auth.uid(),
   case when p_bought>=p_desired then 'purchased'::app.purchase_event_type else 'undone'::app.purchase_event_type end,p_client_op_id);
 update app.shopping_items set desired_quantity=p_desired,bought_quantity=p_bought,buyer_id=p_buyer_id,
   quantity_revision=i.quantity_revision+1,updated_at=now() where id=i.id returning * into i;
 perform app.bump_trip(i.trip_id,'shopping.changed',i.id);
 return i;
end; $$;
revoke all on function app.set_shopping_quantities(uuid,integer,integer,integer,uuid,jsonb,uuid) from public,anon;
grant execute on function app.set_shopping_quantities(uuid,integer,integer,integer,uuid,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
