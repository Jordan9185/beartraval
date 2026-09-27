-- 個人 Mac 的持久佇列；只儲存 AI 草稿，不改正式行程。
create table app.personal_ai_jobs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('parse','ask','extract','inbox','discover')),
  input jsonb not null,
  context jsonb not null default '{}',
  dedupe_key text not null,
  status text not null default 'queued' check (status in ('queued','running','completed','failed')),
  lease uuid,
  lease_until timestamptz,
  available_at timestamptz not null default now(),
  attempts integer not null default 0,
  reason text,
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index personal_ai_queue on app.personal_ai_jobs(owner_id, status, available_at);
create index personal_ai_dedupe on app.personal_ai_jobs(owner_id, kind, dedupe_key);
alter table app.personal_ai_jobs enable row level security;
-- 原文、圖片與工作租約只能由服務端讀取；App 透過狀態入口取得自己的結果。
revoke all on app.personal_ai_jobs from public, anon, authenticated;
grant all on app.personal_ai_jobs to service_role;

create function app.enqueue_personal_ai(p_owner uuid, p_kind text, p_input jsonb, p_context jsonb, p_key text)
returns app.personal_ai_jobs language plpgsql security definer set search_path = '' as $$
declare j app.personal_ai_jobs; a uuid; s app.import_sessions; c app.inbox_captures;
begin
  perform pg_advisory_xact_lock(hashtext('personal-ai:' || p_owner::text));
  select * into j from app.personal_ai_jobs where owner_id = p_owner and kind = p_kind and dedupe_key = p_key
    and (status in ('queued','running') or (p_kind not in ('parse','inbox') and status = 'completed' and created_at > now() - interval '24 hours'))
    order by created_at desc limit 1;
  if found then
    if p_kind = 'parse' and not exists (select 1 from app.import_sessions where id = (j.context->>'import_id')::uuid
      and parse_attempt = (j.context->>'attempt')::uuid and trip_id is null) then
      update app.personal_ai_jobs set status = 'failed', result = '{"status":"failed","reason":"superseded"}', input = '{}'
        where id = j.id;
    else return j; end if;
  end if;
  if (select count(*) from app.personal_ai_jobs where owner_id = p_owner and status in ('queued','running')) >= 30
     or (select count(*) from app.personal_ai_jobs where owner_id = p_owner and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'QUEUE_FULL' using errcode = 'PT429';
  end if;
  if p_kind = 'parse' then
    select * into s from app.import_sessions where id = (p_context->>'import_id')::uuid and created_by = p_owner for update;
    if not found or s.trip_id is not null or s.raw_text is distinct from p_input->>'rawText' then
      raise exception 'STALE' using errcode = 'PT409';
    end if;
    a := app.begin_parse(s.id);
    if a is null then raise exception 'BUSY' using errcode = 'PT409'; end if;
    p_context := p_context || jsonb_build_object('attempt', a);
    perform app.record_parse_progress(s.id, a, '{"stage":"queued","days":0,"stops":0,"last_place":null}');
  elsif p_kind = 'inbox' then
    select * into c from app.inbox_captures where id = (p_context->>'capture_id')::uuid and owner_id = p_owner for update;
    if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
    a := app.begin_inbox_analysis(c.id);
    if a is null then raise exception 'BUSY' using errcode = 'PT409'; end if;
    p_context := p_context || jsonb_build_object('attempt', a);
    update app.inbox_captures set error_code = 'personal_ai_waiting' where id = c.id;
  end if;
  insert into app.personal_ai_jobs(owner_id,kind,input,context,dedupe_key)
    values(p_owner,p_kind,p_input,p_context,p_key) returning * into j;
  return j;
end; $$;

create function app.claim_personal_ai(p_owner uuid) returns app.personal_ai_jobs
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
  select * into j from app.personal_ai_jobs where owner_id = p_owner and available_at <= now()
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

create function app.finish_personal_ai(p_owner uuid, p_id uuid, p_lease uuid, p_result jsonb, p_model text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare j app.personal_ai_jobs; saved boolean := true; item jsonb; item_ordinal integer := 0;
begin
  select * into j from app.personal_ai_jobs where id = p_id and owner_id = p_owner for update;
  if not found or j.status <> 'running' or j.lease is distinct from p_lease or j.lease_until < now() then return false; end if;
  if j.context ? 'trip_id' and not exists(select 1 from app.trip_members where trip_id = (j.context->>'trip_id')::uuid
      and user_id = p_owner and status = 'active') then
    p_result := '{"status":"failed","reason":"forbidden"}';
  end if;
  if j.kind = 'parse' then
    saved := app.record_parse_result((j.context->>'import_id')::uuid, (j.context->>'attempt')::uuid,
      case when p_result->>'status' = 'parsed' then 'parsed'::app.parse_status else 'failed'::app.parse_status end,
      case when p_result->>'status' = 'parsed' then p_result->'parse_result' else null end,
      p_result->>'reason', p_model);
  elsif j.kind = 'inbox' then
    saved := app.finish_inbox_analysis((j.context->>'capture_id')::uuid, (j.context->>'attempt')::uuid,
      p_result->'result', p_result->>'reason', p_model);
    if saved and p_result->>'status' = 'ready' then
      for item in select value from jsonb_array_elements(p_result->'result'->'items') loop
        if item->>'kind' = 'product' then
          update app.inbox_items set store_hint = item->>'store_hint', store_evidence = item->>'store_evidence'
            where capture_id = (j.context->>'capture_id')::uuid and app.inbox_items.ordinal = item_ordinal and not user_corrected;
        end if;
        item_ordinal := item_ordinal + 1;
      end loop;
    end if;
  elsif j.kind = 'ask' and p_result->>'reason' is distinct from 'forbidden' then
    insert into app.ai_messages(trip_id,user_id,question,answer,status,model)
      values((j.context->>'trip_id')::uuid,p_owner,j.input->>'question',p_result->'answer',p_result->>'status',p_model);
  elsif j.kind = 'discover' and j.context ? 'item_id' and p_result->>'status' in ('found','none') then
    update app.inbox_items set discovery_candidates = p_result->'candidates', discovery_checked_at = now()
      where id = (j.context->>'item_id')::uuid and capture_id in (select id from app.inbox_captures where owner_id = p_owner) and revision = (j.context->>'revision')::integer;
    saved := found;
  end if;
  if not saved then p_result := '{"status":"failed","reason":"superseded"}'; end if;
  update app.personal_ai_jobs set status = case when p_result->>'status' = 'failed' then 'failed' else 'completed' end,
    result = p_result, reason = p_result->>'reason', input = '{}', lease_until = null, updated_at = now() where id = j.id;
  return true;
end; $$;

revoke execute on function app.enqueue_personal_ai(uuid,text,jsonb,jsonb,text), app.claim_personal_ai(uuid),
  app.finish_personal_ai(uuid,uuid,uuid,jsonb,text) from public, anon, authenticated;
grant execute on function app.enqueue_personal_ai(uuid,text,jsonb,jsonb,text), app.claim_personal_ai(uuid),
  app.finish_personal_ai(uuid,uuid,uuid,jsonb,text) to service_role;
notify pgrst, 'reload schema';
