-- 撤回單件商品的安排；共同採買站仍供其他商品使用。
create function app.unschedule_purchase(p_item_id uuid,p_stop_id uuid,p_route_revision bigint,p_remove_empty boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare d app.trip_days; s app.stops; i app.shopping_items; other_item uuid;
begin
 select * into s from app.stops where id=p_stop_id;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 select * into d from app.trip_days where id=s.day_id for update;
 perform app.require_role(d.trip_id,array['owner','editor']::app.trip_role[]);
 select * into i from app.shopping_items where id=p_item_id and trip_id=d.trip_id and deleted_at is null for update;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 if i.planned_stop_id is null then return; end if;
 if i.planned_stop_id<>p_stop_id or d.route_revision is distinct from p_route_revision then
  raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 update app.shopping_items set planned_stop_id=null,scheduled_store_name=null,scheduled_store_address_local=null,
  scheduled_store_source_url=null,updated_at=now() where id=i.id;
 select id into other_item from app.shopping_items where planned_stop_id=s.id and deleted_at is null order by id limit 1;
 if other_item is not null then
  if s.shopping_item_id=i.id then update app.stops set shopping_item_id=other_item,revision=revision+1 where id=s.id; end if;
 else
  -- 已手動固定或被收藏共用的站保留；不因商品撤回而刪除一般遊覽行程。
  update app.stops set shopping_item_id=null,
   deleted_at=case when p_remove_empty and kind='purchase' and not fixed and not exists(
     select 1 from app.saved_places where planned_stop_id=s.id and status<>'dismissed') then now() else deleted_at end,
   revision=revision+1 where id=s.id;
 end if;
 update app.trip_days set route_revision=route_revision+1 where id=d.id;
 perform app.bump_trip(d.trip_id,'day.itinerary_changed',d.id);
 perform app.bump_trip(d.trip_id,'shopping.changed',i.id);
end; $$;
revoke all on function app.unschedule_purchase(uuid,uuid,bigint,boolean) from public,anon;
grant execute on function app.unschedule_purchase(uuid,uuid,bigint,boolean) to authenticated;
notify pgrst,'reload schema';
