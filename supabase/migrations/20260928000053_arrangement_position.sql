-- 新增安排可選擇插在原站之前；重用站點不移位，保留整批原子性。
create or replace function app.confirm_ai_arrangements(p_trip_id uuid,p_actions jsonb,p_day_revisions jsonb,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare action jsonb; d app.trip_days; results jsonb := '[]'; receipt jsonb; output jsonb; before_id uuid; anchor_position int; new_id uuid; existing_ids uuid[];
begin
 perform app.require_role(p_trip_id,array['owner','editor']::app.trip_role[]);
 perform pg_advisory_xact_lock(hashtext('ai-arrangements:'||p_trip_id::text));
 select result into receipt from app.arrangement_receipts where operation_id=p_operation_id and trip_id=p_trip_id and actor_id=auth.uid();
 if found then return receipt; end if;
 if p_operation_id is null or jsonb_typeof(p_actions) is distinct from 'array'
 or jsonb_array_length(p_actions) not between 1 and 30 or jsonb_typeof(p_day_revisions) is distinct from 'object' then
 raise exception 'INVALID_REQUEST' using errcode='PT422'; end if;
 -- 先按固定順序鎖住所有日期，再比對使用者看過的版本；任一失敗整批不寫。
 for d in select * from app.trip_days where id in (select (value->>'day_id')::uuid from jsonb_array_elements(p_actions)) order by id for update loop
   if d.trip_id<>p_trip_id or d.route_revision is distinct from (p_day_revisions->>d.id::text)::bigint then
     raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 end loop;
 -- 位置只能參照確認畫面已有的站；不能依賴本批尚未建立的項目。
 select array_agg(id) into existing_ids from app.stops where trip_id=p_trip_id and deleted_at is null;
 for action in select value from jsonb_array_elements(p_actions) loop
  select * into d from app.trip_days where id=(action->>'day_id')::uuid and trip_id=p_trip_id;
  if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
  before_id:=(action->>'before_stop_id')::uuid;
  if before_id is not null and not exists(select 1 from app.stops where id=before_id and day_id=d.id and deleted_at is null and id=any(existing_ids)) then
    raise exception 'STOP_NOT_IN_DAY' using errcode='PT422'; end if;
  if action->>'kind'='saved' then
   output:=app.schedule_saved((action->>'item_id')::uuid,d.id,d.route_revision,(action->>'operation_id')::uuid);
  elsif action->>'kind'='shopping' then
   output:=app.schedule_shopping_store((action->>'item_id')::uuid,(action->>'candidate_index')::integer,
     action->>'source_url',action->>'store_name',d.id,d.route_revision,(action->>'operation_id')::uuid,action->>'address_local');
  else raise exception 'INVALID_KIND' using errcode='PT422'; end if;
  new_id:=(output->>'stop_id')::uuid;
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
