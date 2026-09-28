-- 私人物品的採買仍私人；共同用品才連到共同 Shopping。兩種打包狀態都獨立。
alter table app.packing_items add column shopping_item_id uuid references app.shopping_items(id) on delete set null;
alter table app.packing_items add column purchase_timing text check(purchase_timing in ('before_trip','during_trip'));
alter table app.shopping_items add column purchase_timing text not null default 'during_trip' check(purchase_timing in ('before_trip','during_trip'));
create table app.personal_purchases (
 id uuid primary key default gen_random_uuid(),
 packing_item_id uuid unique references app.packing_items(id) on delete set null,
 trip_id uuid not null references app.trips(id) on delete cascade,
 owner_id uuid not null references auth.users(id) on delete cascade,
 name text not null,
 desired_quantity integer not null check(desired_quantity between 1 and 999),
 bought_quantity integer not null default 0 check(bought_quantity between 0 and 999),
 purchase_timing text not null check(purchase_timing in ('before_trip','during_trip')),
 revision integer not null default 1
);
alter table app.personal_purchases enable row level security;
grant select on app.personal_purchases to authenticated;
create policy personal_purchase_read on app.personal_purchases for select to authenticated using(owner_id=auth.uid());
create function app.request_packing_purchase(p_item_id uuid,p_expected_revision integer,p_timing text) returns void
language plpgsql security definer set search_path='' as $$
declare item app.packing_items; shopping app.shopping_items;
begin
 select * into item from app.packing_items where id=p_item_id and deleted_at is null for update;
 if not found or (not item.shared and item.owner_id<>auth.uid()) then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 perform app.require_role(item.trip_id,array['owner','editor']::app.trip_role[]);
 if item.purchase_timing is not null then return; end if;
 if item.revision is distinct from p_expected_revision then raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 if p_timing is null or p_timing not in ('before_trip','during_trip') then raise exception 'INVALID_ITEM' using errcode='PT422'; end if;
 if item.shared then
  shopping:=app.add_shopping_item(item.trip_id,item.name,item.note,null,item.id);
  update app.shopping_items set desired_quantity=item.quantity,buyer_id=item.buyer_id,purchase_timing=p_timing where id=shopping.id;
 else
  insert into app.personal_purchases(packing_item_id,trip_id,owner_id,name,desired_quantity,purchase_timing)
  values(item.id,item.trip_id,item.owner_id,item.name,item.quantity,p_timing);
 end if;
 update app.packing_items set shopping_item_id=shopping.id,purchase_timing=p_timing,revision=revision+1,updated_by=auth.uid(),updated_at=now() where id=item.id;
 if item.shared then perform app.bump_trip(item.trip_id,'packing.changed',item.id); end if;
end; $$;
create function app.set_personal_purchase(p_id uuid,p_expected_revision integer,p_desired integer,p_bought integer) returns void
language plpgsql security definer set search_path='' as $$
declare item app.personal_purchases;
begin
 select * into item from app.personal_purchases where id=p_id and owner_id=auth.uid() for update;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 if item.revision is distinct from p_expected_revision then raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 if p_desired is null or p_bought is null or p_desired not between 1 and 999 or p_bought not between 0 and 999 then raise exception 'INVALID_ITEM' using errcode='PT422'; end if;
 update app.personal_purchases set desired_quantity=p_desired,bought_quantity=p_bought,revision=revision+1 where id=item.id;
end; $$;
-- 服務端阻擋把出發前必需品排成旅途中才買，不只靠畫面禁用。
create function app.guard_pretrip_purchase() returns trigger language plpgsql set search_path='' as $$
begin
 if new.shopping_item_id is not null and exists(select 1 from app.shopping_items where id=new.shopping_item_id and purchase_timing='before_trip') then
 raise exception 'PRETRIP_PURCHASE' using errcode='PT422'; end if;
 return new;
end; $$;
create trigger pretrip_purchase_guard before insert or update of shopping_item_id on app.stops for each row execute function app.guard_pretrip_purchase();
revoke all on function app.request_packing_purchase(uuid,integer,text),app.set_personal_purchase(uuid,integer,integer,integer) from public,anon;
grant execute on function app.request_packing_purchase(uuid,integer,text),app.set_personal_purchase(uuid,integer,integer,integer) to authenticated;
notify pgrst,'reload schema';
