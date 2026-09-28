-- 使用者核對選定項目後一次提交；同日多項依固定順序追加，不依賴未勾選的新站。
create table app.arrangement_receipts (
 operation_id uuid primary key,
 trip_id uuid not null references app.trips(id) on delete cascade,
 actor_id uuid not null references auth.users(id) on delete cascade,
 result jsonb not null
);
alter table app.arrangement_receipts enable row level security;
revoke all on app.arrangement_receipts from public,anon,authenticated;
create function app.confirm_ai_arrangements(p_trip_id uuid,p_actions jsonb,p_day_revisions jsonb,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare action jsonb; d app.trip_days; results jsonb := '[]'; receipt jsonb; output jsonb;
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
 for action in select value from jsonb_array_elements(p_actions) loop
  select * into d from app.trip_days where id=(action->>'day_id')::uuid and trip_id=p_trip_id;
  if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
  if action->>'kind'='saved' then
   output:=app.schedule_saved((action->>'item_id')::uuid,d.id,d.route_revision,(action->>'operation_id')::uuid);
  elsif action->>'kind'='shopping' then
   output:=app.schedule_shopping_store((action->>'item_id')::uuid,(action->>'candidate_index')::integer,
     action->>'source_url',action->>'store_name',d.id,d.route_revision,(action->>'operation_id')::uuid,action->>'address_local');
  else raise exception 'INVALID_KIND' using errcode='PT422'; end if;
  results:=results||jsonb_build_array(output);
 end loop;
 insert into app.arrangement_receipts values(p_operation_id,p_trip_id,auth.uid(),results);
 return results;
end; $$;
revoke all on function app.confirm_ai_arrangements(uuid,jsonb,jsonb,uuid) from public,anon;
grant execute on function app.confirm_ai_arrangements(uuid,jsonb,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
