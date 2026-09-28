-- 中斷只結束原工作，不重新呼叫付費 API；同時結束匯入／收集的處理狀態。
create function app.expire_claude_ai(p_owner uuid) returns void
language plpgsql security definer set search_path='' as $$
declare j app.personal_ai_jobs;
begin
 for j in select * from app.personal_ai_jobs where owner_id=p_owner and context->>'ai_provider'='claude_api'
   and ((status='running' and lease_until<now()) or (status='queued' and created_at<now()-interval '8 minutes'))
   for update skip locked loop
  -- 在同一筆交易內建立僅供結案的租約，沿用既有 attempt 與權限檢查。
  update app.personal_ai_jobs set status='running',lease=gen_random_uuid(),lease_until=now()+interval '1 minute'
    where id=j.id returning * into j;
  perform app.finish_personal_ai(j.owner_id,j.id,j.lease,
    '{"status":"failed","reason":"claude_api_error","provider":"claude_api","usage":null}'::jsonb,null);
 end loop;
end; $$;
revoke all on function app.expire_claude_ai(uuid) from public,anon,authenticated;
grant execute on function app.expire_claude_ai(uuid) to service_role;
notify pgrst,'reload schema';
