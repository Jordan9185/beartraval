-- 明確安排另一次到訪，不覆蓋原本的採買站，也不複製商品或購買紀錄。
create table app.shopping_extra_visits (
 stop_id uuid primary key references app.stops(id) on delete cascade,
 item_id uuid not null references app.shopping_items(id) on delete cascade,
 trip_id uuid not null references app.trips(id) on delete cascade,
 operation_id uuid not null unique,
 actor_id uuid references auth.users(id) on delete set null,
 removed_at timestamptz
);
alter table app.shopping_extra_visits enable row level security;
revoke all on app.shopping_extra_visits from public,anon,authenticated;
grant select on app.shopping_extra_visits to authenticated;
create policy extra_visits_read on app.shopping_extra_visits for select to authenticated using(app.trip_role_of(trip_id) is not null);
create function app.add_shopping_visit(p_item_id uuid,p_source_stop uuid,p_day_id uuid,p_route_revision bigint,p_operation_id uuid,p_before_stop uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare d app.trip_days; i app.shopping_items; source app.stops; destination uuid; pos integer;
 name text; address text; url text;
begin
 select * into d from app.trip_days where id=p_day_id for update;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 perform app.require_role(d.trip_id,array['owner','editor']::app.trip_role[]);
 select * into i from app.shopping_items where id=p_item_id and trip_id=d.trip_id and deleted_at is null for update;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 select stop_id into destination from app.shopping_extra_visits where operation_id=p_operation_id and item_id=i.id and actor_id=auth.uid();
 if found then return destination; end if;
 if p_operation_id is null or d.route_revision is distinct from p_route_revision then raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 if i.purchase_timing='before_trip' then raise exception 'INVALID_SCHEDULE' using errcode='PT422'; end if;
 select * into source from app.stops where id=p_source_stop and trip_id=d.trip_id and deleted_at is null
  and (id=i.planned_stop_id or exists(select 1 from app.shopping_extra_visits where stop_id=p_source_stop and item_id=i.id and removed_at is null));
 if not found then raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 select coalesce(source.destination_name,case when source.id=i.planned_stop_id then i.scheduled_store_name end,p.name_local,p.name,source.raw_label),
  coalesce(source.destination_address,case when source.id=i.planned_stop_id then i.scheduled_store_address_local end,p.address_local,p.address),
  coalesce(source.destination_source,case when source.id=i.planned_stop_id then i.scheduled_store_source_url end)
  into name,address,url from (select 1) seed left join app.places p on p.id=source.place_id;
 if nullif(btrim(address),'') is null then raise exception 'INVALID_SCHEDULE' using errcode='PT422'; end if;
 if p_before_stop is not null then
  select sort_order into pos from app.stops where id=p_before_stop and day_id=d.id and deleted_at is null;
  if not found then raise exception 'STOP_NOT_IN_DAY' using errcode='PT422'; end if;
 else select coalesce(max(sort_order)+1,0) into pos from app.stops where day_id=d.id and deleted_at is null; end if;
 update app.stops set sort_order=sort_order+1 where day_id=d.id and deleted_at is null and sort_order>=pos;
 insert into app.stops(trip_id,day_id,place_id,raw_label,resolution_status,dwell_minutes,fixed,kind,sort_order,added_by,destination_name,destination_address,destination_source)
 values(d.trip_id,d.id,source.place_id,name,source.resolution_status,30,false,'purchase',pos,auth.uid(),name,address,url) returning id into destination;
 insert into app.shopping_extra_visits(stop_id,item_id,trip_id,operation_id,actor_id) values(destination,i.id,d.trip_id,p_operation_id,auth.uid());
 update app.trip_days set route_revision=route_revision+1 where id=d.id;
 perform app.bump_trip(d.trip_id,'day.itinerary_changed',d.id);
 perform app.bump_trip(d.trip_id,'shopping.changed',i.id);
 return destination;
end; $$;
create function app.remove_shopping_visit(p_item_id uuid,p_stop_id uuid,p_route_revision bigint,p_remove_empty boolean default false)
returns void language plpgsql security definer set search_path='' as $$
declare d app.trip_days; s app.stops;
begin
 select * into s from app.stops where id=p_stop_id;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 select * into d from app.trip_days where id=s.day_id for update;
 perform app.require_role(d.trip_id,array['owner','editor']::app.trip_role[]);
 if not exists(select 1 from app.shopping_extra_visits where stop_id=s.id and item_id=p_item_id and removed_at is null) then return; end if;
 if d.route_revision is distinct from p_route_revision then raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 update app.shopping_extra_visits set removed_at=now() where stop_id=s.id and item_id=p_item_id;
 if p_remove_empty and not s.fixed and s.kind='purchase'
  and not exists(select 1 from app.shopping_items where planned_stop_id=s.id and deleted_at is null)
  and not exists(select 1 from app.saved_places where planned_stop_id=s.id and status<>'dismissed') then
   update app.stops set deleted_at=now(),revision=revision+1 where id=s.id;
 end if;
 update app.trip_days set route_revision=route_revision+1 where id=d.id;
 perform app.bump_trip(d.trip_id,'day.itinerary_changed',d.id);
 perform app.bump_trip(d.trip_id,'shopping.changed',p_item_id);
end; $$;
revoke all on function app.add_shopping_visit(uuid,uuid,uuid,bigint,uuid,uuid),app.remove_shopping_visit(uuid,uuid,bigint,boolean) from public,anon;
grant execute on function app.add_shopping_visit(uuid,uuid,uuid,bigint,uuid,uuid),app.remove_shopping_visit(uuid,uuid,bigint,boolean) to authenticated;

create or replace function app.unschedule_purchase(p_item_id uuid,p_stop_id uuid,p_route_revision bigint,p_remove_empty boolean default false)
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
   deleted_at=case when p_remove_empty and not exists(select 1 from app.shopping_extra_visits where stop_id=s.id and removed_at is null) and kind='purchase' and not fixed and not exists(
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
