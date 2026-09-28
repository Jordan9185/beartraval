-- 退出前列出本人未完成的共同分工；私人用品不列入共同移交。
create function app.preview_trip_departure(p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare rev bigint; items jsonb;
begin
 perform app.require_role(p_trip_id,array['editor','viewer']::app.trip_role[]);
 select revision into rev from app.trips where id=p_trip_id;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.kind,x.name,x.id),'[]'::jsonb) into items from (
  select id,'packing'::text as kind,name,quantity,
   carrier_id=auth.uid() as carrying,coalesce(buyer_id=auth.uid(),false) as buying
   from app.packing_items where trip_id=p_trip_id and shared and not packed and deleted_at is null
    and (carrier_id=auth.uid() or buyer_id=auth.uid())
  union all
  select id,'shopping',name,desired_quantity-bought_quantity,false,true
   from app.shopping_items where trip_id=p_trip_id and deleted_at is null
    and buyer_id=auth.uid() and bought_quantity<desired_quantity
 ) x;
 return jsonb_build_object('revision',rev,'items',items);
end; $$;
drop function app.leave_trip(uuid);
create function app.leave_trip(p_trip_id uuid,p_expected_revision bigint default null) returns void
language plpgsql security definer set search_path='' as $$
declare rev bigint;
begin
 select revision into rev from app.trips where id=p_trip_id for update;
 perform app.require_role(p_trip_id,array['editor','viewer']::app.trip_role[]);
 if p_expected_revision is not null and p_expected_revision<>rev then
  raise exception 'STALE_REVISION' using errcode='PT409';
 end if;
 update app.trip_members set status='removed' where trip_id=p_trip_id and user_id=auth.uid();
 delete from app.ownership_offers where trip_id=p_trip_id and to_user=auth.uid();
 perform app.bump_trip(p_trip_id,'member.changed',auth.uid());
end; $$;
revoke all on function app.preview_trip_departure(uuid),app.leave_trip(uuid,bigint) from public,anon;
grant execute on function app.preview_trip_departure(uuid),app.leave_trip(uuid,bigint) to authenticated;
notify pgrst,'reload schema';
