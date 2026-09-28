-- 只有本人明確選擇才使用共用 Claude 額度。工作建立後模式固定。
create table app.ai_preferences (
 user_id uuid primary key references auth.users(id) on delete cascade,
 provider text not null check(provider in ('local_gpt','claude_api'))
);
alter table app.ai_preferences enable row level security;
grant select on app.ai_preferences to authenticated;
grant select on app.ai_preferences to service_role;
create policy ai_preference_read on app.ai_preferences for select to authenticated using(user_id=auth.uid());
create function app.set_ai_provider(p_provider text) returns void language plpgsql security definer set search_path = '' as $$
begin
 perform app.current_user_id();
 if p_provider not in ('local_gpt','claude_api') or p_provider is null then raise exception 'INVALID_REQUEST' using errcode='PT422'; end if;
 insert into app.ai_preferences values(auth.uid(),p_provider) on conflict(user_id) do update set provider=excluded.provider;
end; $$;
revoke all on function app.set_ai_provider(text) from public,anon;
grant execute on function app.set_ai_provider(text) to authenticated;
create or replace function app.claim_personal_ai(p_owner uuid) returns app.personal_ai_jobs
language plpgsql security definer set search_path = '' as $$
declare j app.personal_ai_jobs;
begin
  update app.personal_ai_jobs obsolete set status = 'failed', input = '{}',
    result = '{"status":"failed","reason":"superseded"}', lease_until = null
    where owner_id = p_owner and status in ('queued','running') and (
      (kind = 'parse' and not exists(select 1 from app.import_sessions s
        where s.id = (obsolete.context->>'import_id')::uuid and s.parse_attempt = (obsolete.context->>'attempt')::uuid and s.trip_id is null))
      or (kind = 'inbox' and not exists(select 1 from app.inbox_captures c
        where c.id = (obsolete.context->>'capture_id')::uuid and c.analysis_attempt = (obsolete.context->>'attempt')::uuid)));
  select * into j from app.personal_ai_jobs where owner_id = p_owner and coalesce(context->>'ai_provider','local_gpt') = 'local_gpt' and available_at <= now()
    and (status = 'queued' or (status = 'running' and lease_until < now()))
    order by created_at for update skip locked limit 1;
  if not found then return null; end if;
  update app.personal_ai_jobs set status = 'running', lease = gen_random_uuid(), lease_until = now() + interval '3 minutes',
    attempts = attempts + 1, reason = null, updated_at = now() where id = j.id returning * into j;
  if j.kind = 'parse' then
    perform app.record_parse_progress((j.context->>'import_id')::uuid, (j.context->>'attempt')::uuid,
      '{"stage":"reading","days":0,"stops":0,"last_place":null}');
  elsif j.kind = 'inbox' then
    update app.inbox_captures set error_code = null where id = (j.context->>'capture_id')::uuid
      and analysis_attempt = (j.context->>'attempt')::uuid;
  end if;
  return j;
end; $$;


-- Cloud 以 id 原子領取；App、Mac 都不能偽造供應商或租約。
create function app.claim_claude_ai(p_id uuid) returns app.personal_ai_jobs
language plpgsql security definer set search_path='' as $$
declare j app.personal_ai_jobs;
begin
 update app.personal_ai_jobs set status='running',lease=gen_random_uuid(),lease_until=now()+interval '8 minutes',
 attempts=attempts+1,updated_at=now()
 where id=p_id and context->>'ai_provider'='claude_api' and status='queued'
 returning * into j;
 return j;
end; $$;
revoke all on function app.claim_claude_ai(uuid) from public,anon,authenticated;
grant execute on function app.claim_claude_ai(uuid) to service_role;
notify pgrst,'reload schema';

-- 限制共用 API 每日工作數；命中同一工作不重複扣工作數，超額回滾此次入列。
alter function app.enqueue_personal_ai(uuid,text,jsonb,jsonb,text) rename to enqueue_personal_ai_internal;
revoke all on function app.enqueue_personal_ai_internal(uuid,text,jsonb,jsonb,text) from public,anon,authenticated;
create function app.enqueue_personal_ai(p_owner uuid,p_kind text,p_input jsonb,p_context jsonb,p_key text)
returns app.personal_ai_jobs language plpgsql security definer set search_path='' as $$
declare j app.personal_ai_jobs;
begin
 if p_context->>'ai_provider'='claude_api' then perform pg_advisory_xact_lock(hashtext('claude-shared-budget')); end if;
 j := app.enqueue_personal_ai_internal(p_owner,p_kind,p_input,p_context,p_key);
 if p_context->>'ai_provider'='claude_api' and (
   (select count(*) from app.personal_ai_jobs where context->>'ai_provider'='claude_api' and created_at >= date_trunc('day',now())) > 100 or
   (select count(*) from app.personal_ai_jobs where owner_id=p_owner and context->>'ai_provider'='claude_api' and created_at >= date_trunc('day',now())) > 20
 ) then raise exception 'API_DAILY_LIMIT' using errcode='PT429'; end if;
 return j;
end; $$;
revoke all on function app.enqueue_personal_ai(uuid,text,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function app.enqueue_personal_ai(uuid,text,jsonb,jsonb,text) to service_role;
