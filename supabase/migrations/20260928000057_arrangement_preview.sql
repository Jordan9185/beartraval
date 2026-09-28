-- 用同一套正式驗證產生整日差異；子交易回滾所有試排寫入與通知，只回傳預覽。
create function app.preview_ai_arrangements(p_trip_id uuid,p_actions jsonb,p_day_revisions jsonb,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare before_days jsonb; after_days jsonb; changes jsonb; affected uuid[];
begin
 perform app.require_role(p_trip_id,array['owner','editor']::app.trip_role[]);
 if jsonb_typeof(p_actions) is distinct from 'array' or jsonb_array_length(p_actions) not between 1 and 30 then
  raise exception 'INVALID_REQUEST' using errcode='PT422'; end if;
 select array_agg(distinct id) into affected from (
  select (value->>'day_id')::uuid as id from jsonb_array_elements(p_actions)
  union select (value->>'source_day_id')::uuid from jsonb_array_elements(p_actions) where value->>'kind' in ('stop_move','stop_remove')
 ) ids;
 select coalesce(jsonb_agg(jsonb_build_object('day',to_jsonb(d),'stops',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order) from app.stops s where s.day_id=d.id and s.deleted_at is null),'[]'::jsonb)) order by d.display_order),'[]'::jsonb)
 into before_days from app.trip_days d where d.trip_id=p_trip_id;
 begin
  changes:=app.confirm_ai_arrangements(p_trip_id,p_actions,p_day_revisions,p_operation_id);
  select array_agg(distinct id) into affected from (
    select unnest(affected) as id union select (value->>'day_id')::uuid from jsonb_array_elements(changes)
  ) actual_days;
  select coalesce(jsonb_agg(value order by (value->'day'->>'display_order')::integer),'[]'::jsonb) into before_days
    from jsonb_array_elements(before_days) where (value->'day'->>'id')::uuid=any(affected);
  if exists(select 1 from jsonb_array_elements(before_days) b
    where (b->'day'->>'route_revision')::bigint is distinct from (p_day_revisions->>(b->'day'->>'id'))::bigint) then
    raise exception 'STALE_REVISION' using errcode='PT409'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('day',to_jsonb(d),'stops',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order) from app.stops s where s.day_id=d.id and s.deleted_at is null),'[]'::jsonb)) order by d.display_order),'[]'::jsonb)
  into after_days from app.trip_days d where d.trip_id=p_trip_id and d.id=any(affected);
  -- PL/pgSQL 變數保留預覽，資料表、receipt、版本與通知全部回滾。
  raise exception using errcode='PZ001',message='ROLLBACK_PREVIEW';
 exception when sqlstate 'PZ001' then null;
 end;
 return jsonb_build_object('before',before_days,'after',after_days,'outcomes',changes);
end; $$;
revoke all on function app.preview_ai_arrangements(uuid,jsonb,jsonb,uuid) from public,anon;
grant execute on function app.preview_ai_arrangements(uuid,jsonb,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
