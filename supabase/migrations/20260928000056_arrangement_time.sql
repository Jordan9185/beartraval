-- 指定時間以所選日的當地時刻保存；沿用既有站時不能藉新增操作改它的時間。
create or replace function app.confirm_ai_arrangements(p_trip_id uuid,p_actions jsonb,p_day_revisions jsonb,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare action jsonb; d app.trip_days; results jsonb := '[]'; receipt jsonb; output jsonb; before_id uuid; anchor_position int; new_id uuid; existing_ids uuid[]; changed app.stops; source_day uuid; destination_pos integer; requested_time time;
begin
 perform app.require_role(p_trip_id,array['owner','editor']::app.trip_role[]);
 perform pg_advisory_xact_lock(hashtext('ai-arrangements:'||p_trip_id::text));
 select result into receipt from app.arrangement_receipts where operation_id=p_operation_id and trip_id=p_trip_id and actor_id=auth.uid();
 if found then return receipt; end if;
 if p_operation_id is null or jsonb_typeof(p_actions) is distinct from 'array'
 or jsonb_array_length(p_actions) not between 1 and 30 or jsonb_typeof(p_day_revisions) is distinct from 'object' then
 raise exception 'INVALID_REQUEST' using errcode='PT422'; end if;
 if exists(select 1 from jsonb_array_elements(p_actions) a where a->>'kind' in ('stop_move','stop_remove') group by a->>'item_id' having count(*)>1) then
   raise exception 'INVALID_REQUEST' using errcode='PT422'; end if;
 -- 先按固定順序鎖住所有日期，再比對使用者看過的版本；任一失敗整批不寫。
 for d in select * from app.trip_days where id in (select (value->>'day_id')::uuid from jsonb_array_elements(p_actions) union select (value->>'source_day_id')::uuid from jsonb_array_elements(p_actions) where value->>'kind' in ('stop_move','stop_remove') union select key::uuid from jsonb_object_keys(p_day_revisions) key) order by id for update loop
   if d.trip_id<>p_trip_id or d.route_revision is distinct from (p_day_revisions->>d.id::text)::bigint then
     raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 end loop;
 -- 位置只能參照確認畫面已有的站；不能依賴本批尚未建立的項目。
 select array_agg(id) into existing_ids from app.stops where trip_id=p_trip_id and deleted_at is null;
 for action in select value from jsonb_array_elements(p_actions) loop
  select * into d from app.trip_days where id=(action->>'day_id')::uuid and trip_id=p_trip_id;
  if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
  if nullif(action->>'start_time','') is not null and (action->>'start_time') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'INVALID_TIME' using errcode='PT422'; end if;
  requested_time:=nullif(action->>'start_time','')::time;
  before_id:=(action->>'before_stop_id')::uuid;
  if before_id is not null and not exists(select 1 from app.stops where id=before_id and day_id=d.id and deleted_at is null and id=any(existing_ids)) then
    raise exception 'STOP_NOT_IN_DAY' using errcode='PT422'; end if;
  if action->>'kind' in ('stop_move','stop_remove') then
    source_day:=(action->>'source_day_id')::uuid;
    select * into changed from app.stops where id=(action->>'item_id')::uuid and trip_id=p_trip_id and deleted_at is null;
    if not found or source_day is null or changed.day_id is distinct from source_day then
      raise exception 'STALE_REVISION' using errcode='PT409'; end if;
    if changed.fixed then raise exception 'FIXED_STOP' using errcode='PT422'; end if;
    if before_id=changed.id then raise exception 'INVALID_REQUEST' using errcode='PT422'; end if;
    if action->>'kind'='stop_remove' then
      if d.id<>source_day or before_id is not null or requested_time is not null then raise exception 'INVALID_REQUEST' using errcode='PT422'; end if;
      update app.stops set deleted_at=now(),revision=revision+1,updated_at=now() where id=changed.id;
    else
      if before_id is not null then select sort_order into destination_pos from app.stops where id=before_id;
      else select coalesce(max(sort_order)+1,0) into destination_pos from app.stops where day_id=d.id and deleted_at is null; end if;
      update app.stops set sort_order=sort_order+1,updated_at=now()
        where day_id=d.id and deleted_at is null and id<>changed.id and sort_order>=destination_pos;
      update app.stops set day_id=d.id,sort_order=destination_pos,
        start_time=coalesce(requested_time,start_time),end_time=case when requested_time is not null then null else end_time end,
        revision=revision+1,updated_at=now() where id=changed.id;
    end if;
    update app.trip_days set route_revision=route_revision+1 where id in (source_day,d.id);
    perform app.bump_trip(p_trip_id,'day.itinerary_changed',source_day);
    if source_day<>d.id then perform app.bump_trip(p_trip_id,'day.itinerary_changed',d.id); end if;
    results:=results||jsonb_build_array(jsonb_build_object('status',action->>'kind','stop_id',changed.id,'day_id',d.id));
    continue;
  end if;
  if action->>'kind'='saved' then
   output:=app.schedule_saved((action->>'item_id')::uuid,d.id,d.route_revision,(action->>'operation_id')::uuid);
  elsif action->>'kind'='shopping' then
   output:=app.schedule_shopping_store((action->>'item_id')::uuid,(action->>'candidate_index')::integer,
     action->>'source_url',action->>'store_name',d.id,d.route_revision,(action->>'operation_id')::uuid,action->>'address_local');
  else raise exception 'INVALID_KIND' using errcode='PT422'; end if;
  new_id:=(output->>'stop_id')::uuid;
  if requested_time is not null then
    if new_id=any(coalesce(existing_ids,array[]::uuid[])) then
      raise exception 'EXISTING_STOP_TIME' using errcode='PT422'; end if;
    update app.stops set start_time=requested_time,end_time=null,revision=revision+1 where id=new_id;
  end if;
  -- 重用原站時維持原位；只有這批新建的站能插入，固定站的時間與相對順序不動。
  if before_id is not null and not (new_id=any(coalesce(existing_ids,array[]::uuid[]))) then
    select sort_order into anchor_position from app.stops where id=before_id;
    update app.stops set sort_order=sort_order+1,updated_at=now()
      where day_id=d.id and deleted_at is null and id<>new_id and sort_order>=anchor_position;
    update app.stops set sort_order=anchor_position,updated_at=now() where id=new_id;
  end if;
  existing_ids:=array_append(existing_ids,new_id);
  results:=results||jsonb_build_array(output);
 end loop;
 insert into app.arrangement_receipts values(p_operation_id,p_trip_id,auth.uid(),results);
 return results;
end; $$;
revoke all on function app.confirm_ai_arrangements(uuid,jsonb,jsonb,uuid) from public,anon;
grant execute on function app.confirm_ai_arrangements(uuid,jsonb,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
