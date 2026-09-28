-- 暫不安排與刪除清單不同；恢復後可再次納入 AI。
alter table app.saved_places add column ai_suppressed boolean not null default false;
alter table app.shopping_items add column ai_suppressed boolean not null default false;
create function app.set_arrangement_suppressed(p_kind text,p_id uuid,p_suppressed boolean) returns void
language plpgsql security definer set search_path='' as $$
declare trip uuid;
begin
 if p_kind='saved' then select trip_id into trip from app.saved_places where id=p_id and status<>'dismissed';
 elsif p_kind='shopping' then select trip_id into trip from app.shopping_items where id=p_id and deleted_at is null;
 else raise exception 'INVALID_KIND' using errcode='PT422'; end if;
 if trip is null then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 perform app.require_role(trip,array['owner','editor']::app.trip_role[]);
 if p_kind='saved' then update app.saved_places set ai_suppressed=p_suppressed where id=p_id;
 else update app.shopping_items set ai_suppressed=p_suppressed where id=p_id; end if;
 perform app.bump_trip(trip,'collection.changed',p_id);
end; $$;
revoke all on function app.set_arrangement_suppressed(text,uuid,boolean) from public,anon;
grant execute on function app.set_arrangement_suppressed(text,uuid,boolean) to authenticated;

-- 刪除共同採買站時，所有關聯商品都回待安排，不留下指向墓碑的引用。
create or replace function app.link_purchase_stop() returns trigger language plpgsql set search_path='' as $$
begin
 if new.deleted_at is not null then
  update app.shopping_items set planned_stop_id=null,scheduled_store_name=null,scheduled_store_address_local=null,
    scheduled_store_source_url=null,updated_at=now() where planned_stop_id=new.id;
 elsif new.shopping_item_id is not null then
  update app.shopping_items set planned_stop_id=new.id,updated_at=now() where id=new.shopping_item_id and trip_id=new.trip_id;
 end if;
 return new;
end; $$;
notify pgrst,'reload schema';
