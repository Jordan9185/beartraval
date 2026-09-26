-- 個人 Travel Inbox。分享原文、候選與模板都不屬於共同 Trip。
create table app.inbox_captures (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  client_capture_id uuid not null,
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  canonical_url text check (length(canonical_url) <= 4000),
  source_url text check (length(source_url) <= 4000),
  title text check (length(title) <= 500),
  raw_text text not null default '' check (length(raw_text) <= 20000),
  unavailable_count int not null default 0 check (unavailable_count between 0 and 100),
  status text not null default 'saved' check (status in ('saved', 'processing', 'ready', 'insufficient', 'failed')),
  content_kind text check (content_kind in ('recommendations', 'shopping', 'itinerary', 'mixed', 'unknown')),
  error_code text,
  analysis_attempt uuid,
  processing_started_at timestamptz,
  model text,
  share_count int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_shared_at timestamptz not null default now(),
  unique (owner_id, client_capture_id),
  unique (owner_id, fingerprint)
);
create unique index inbox_captures_owner_url on app.inbox_captures(owner_id, canonical_url) where canonical_url is not null;
create index inbox_captures_owner_recent on app.inbox_captures(owner_id, last_shared_at desc);

create table app.inbox_assets (
  id uuid primary key default gen_random_uuid(),
  capture_id uuid not null references app.inbox_captures(id) on delete cascade,
  ordinal int not null check (ordinal between 0 and 99),
  kind text not null check (kind in ('image', 'video', 'audio')),
  mime_type text not null,
  byte_count bigint not null check (byte_count between 0 and 150000000),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path text,
  status text not null default 'local_only' check (status in ('local_only', 'uploaded', 'unavailable')),
  unique (capture_id, ordinal)
);

create table app.inbox_items (
  id uuid primary key default gen_random_uuid(),
  capture_id uuid not null references app.inbox_captures(id) on delete cascade,
  ordinal int not null,
  kind text not null check (kind in ('place', 'product')),
  display_name text not null check (length(btrim(display_name)) between 1 and 200),
  source_span text not null check (length(source_span) between 1 and 500),
  origin_type text not null check (origin_type in ('explicit', 'inferred')),
  confidence text not null check (confidence in ('high', 'medium', 'low')),
  day_index int check (day_index between 1 and 30),
  resolution_status text not null default 'unresolved' check (resolution_status in ('unresolved', 'candidate', 'verified')),
  place_id uuid references app.places(id) on delete set null,
  archived boolean not null default false,
  user_corrected boolean not null default false,
  revision int not null default 0,
  created_at timestamptz not null default now(),
  unique (capture_id, ordinal)
);
create index inbox_items_capture on app.inbox_items(capture_id, ordinal);

create table app.itinerary_templates (
  id uuid primary key default gen_random_uuid(),
  capture_id uuid not null unique references app.inbox_captures(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (length(title) between 1 and 200),
  draft jsonb not null check (jsonb_typeof(draft) = 'object'),
  revision int not null default 0,
  user_corrected boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table app.inbox_captures enable row level security;
alter table app.inbox_assets enable row level security;
alter table app.inbox_items enable row level security;
alter table app.itinerary_templates enable row level security;
create policy inbox_captures_owner_read on app.inbox_captures for select to authenticated using (owner_id = auth.uid());
create policy inbox_assets_owner_read on app.inbox_assets for select to authenticated
  using (exists (select 1 from app.inbox_captures c where c.id = capture_id and c.owner_id = auth.uid()));
create policy inbox_items_owner_read on app.inbox_items for select to authenticated
  using (exists (select 1 from app.inbox_captures c where c.id = capture_id and c.owner_id = auth.uid()));
create policy itinerary_templates_owner_read on app.itinerary_templates for select to authenticated using (owner_id = auth.uid());
grant select on app.inbox_captures, app.inbox_assets, app.inbox_items, app.itinerary_templates to authenticated;
revoke insert, update, delete, truncate on app.inbox_captures, app.inbox_assets, app.inbox_items, app.itinerary_templates from authenticated, anon;

-- 同一來源只更新最後分享時間，不覆寫原文、AI 結果或使用者更正。
create function app.save_inbox_capture(
  p_client_capture_id uuid, p_fingerprint text, p_canonical_url text,
  p_source_url text, p_title text, p_raw_text text, p_unavailable_count int default 0
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := app.current_user_id();
  c app.inbox_captures;
  inserted boolean := false;
  same_client boolean := false;
begin
  if p_fingerprint !~ '^[0-9a-f]{64}$' or length(coalesce(p_raw_text, '')) > 20000
     or length(coalesce(p_canonical_url, '')) > 4000 or length(coalesce(p_source_url, '')) > 4000
     or length(coalesce(p_title, '')) > 500 or p_unavailable_count not between 0 and 100 then
    raise exception 'INVALID_CAPTURE' using errcode = 'PT422';
  end if;
  perform pg_advisory_xact_lock(hashtext(uid::text || coalesce(p_canonical_url, p_fingerprint)));
  select * into c from app.inbox_captures
   where owner_id = uid and (client_capture_id = p_client_capture_id
      or (p_canonical_url is not null and canonical_url = p_canonical_url)
      or fingerprint = p_fingerprint)
   order by created_at limit 1 for update;
  if found then
    same_client := c.client_capture_id = p_client_capture_id;
    update app.inbox_captures set last_shared_at = now(), share_count = share_count + 1,
      unavailable_count = greatest(unavailable_count, p_unavailable_count)
     where id = c.id;
  else
    insert into app.inbox_captures(owner_id, client_capture_id, fingerprint, canonical_url, source_url, title, raw_text, unavailable_count)
    values (uid, p_client_capture_id, p_fingerprint, nullif(p_canonical_url, ''), nullif(p_source_url, ''),
            nullif(btrim(p_title), ''), coalesce(p_raw_text, ''), p_unavailable_count) returning * into c;
    inserted := true;
  end if;
  return jsonb_build_object('id', c.id, 'created', inserted, 'same_client', same_client);
end;
$$;

create function app.register_inbox_asset(p_capture_id uuid, p_ordinal int, p_kind text,
  p_mime_type text, p_byte_count bigint, p_sha256 text, p_storage_path text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := app.current_user_id();
begin
  if not exists (select 1 from app.inbox_captures where id = p_capture_id and owner_id = uid) then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  if p_storage_path is not null and
     (p_kind <> 'image' or split_part(p_storage_path, '/', 1) <> uid::text
       or split_part(p_storage_path, '/', 2) <> p_capture_id::text) then
    raise exception 'INVALID_ASSET_PATH' using errcode = 'PT422';
  end if;
  insert into app.inbox_assets(capture_id, ordinal, kind, mime_type, byte_count, sha256, storage_path, status)
  values (p_capture_id, p_ordinal, p_kind, p_mime_type, p_byte_count, p_sha256,
          p_storage_path, case when p_storage_path is null then 'local_only' else 'uploaded' end)
  on conflict (capture_id, ordinal) do nothing;
end;
$$;

-- 只允許 owner 修改單項候選；之後 AI 重試不得覆寫已更正資料。
create function app.update_inbox_item(p_item_id uuid, p_expected_revision int,
  p_display_name text default null, p_archived boolean default null)
returns app.inbox_items language plpgsql security definer set search_path = '' as $$
declare uid uuid := app.current_user_id(); i app.inbox_items;
begin
  select x.* into i from app.inbox_items x join app.inbox_captures c on c.id = x.capture_id
   where x.id = p_item_id and c.owner_id = uid for update of x;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  if i.revision <> p_expected_revision then raise exception 'STALE_REVISION' using errcode = 'PT409'; end if;
  if p_display_name is not null and length(btrim(p_display_name)) not between 1 and 200 then
    raise exception 'INVALID_NAME' using errcode = 'PT422';
  end if;
  update app.inbox_items set display_name = coalesce(nullif(btrim(p_display_name), ''), display_name),
    archived = coalesce(p_archived, archived), user_corrected = true, revision = revision + 1
   where id = p_item_id returning * into i;
  return i;
end;
$$;

create function app.update_inbox_template(p_template_id uuid, p_expected_revision int,
  p_title text, p_draft jsonb) returns app.itinerary_templates
language plpgsql security definer set search_path = '' as $$
declare uid uuid := app.current_user_id(); t app.itinerary_templates;
begin
  select * into t from app.itinerary_templates where id = p_template_id and owner_id = uid for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  if t.revision <> p_expected_revision then raise exception 'STALE_REVISION' using errcode = 'PT409'; end if;
  if length(btrim(coalesce(p_title, ''))) not between 1 and 200
     or jsonb_typeof(p_draft) <> 'object' or length(p_draft::text) > 50000 then
    raise exception 'INVALID_TEMPLATE' using errcode = 'PT422';
  end if;
  update app.itinerary_templates set title = btrim(p_title), draft = p_draft,
    user_corrected = true, revision = revision + 1, updated_at = now()
   where id = p_template_id returning * into t;
  return t;
end;
$$;

-- Service-role worker claims one attempt. A stalled attempt may be retried after five minutes.
create function app.begin_inbox_analysis(p_capture_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c app.inbox_captures; attempt uuid := gen_random_uuid();
begin
  select * into c from app.inbox_captures where id = p_capture_id for update;
  if not found or c.status in ('ready', 'insufficient')
     or (c.status = 'processing' and c.processing_started_at > now() - interval '5 minutes') then return null; end if;
  update app.inbox_captures set status = 'processing', analysis_attempt = attempt,
    processing_started_at = now(), error_code = null, updated_at = now() where id = p_capture_id;
  return attempt;
end;
$$;

create function app.finish_inbox_analysis(p_capture_id uuid, p_attempt uuid,
  p_result jsonb, p_error text default null, p_model text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare c app.inbox_captures; entry jsonb; n int := 0; days jsonb;
begin
  select * into c from app.inbox_captures where id = p_capture_id for update;
  if not found or c.analysis_attempt is distinct from p_attempt or c.status <> 'processing' then return false; end if;
  if p_error is not null then
    update app.inbox_captures set status = 'failed', error_code = left(p_error, 100),
      analysis_attempt = null, updated_at = now() where id = p_capture_id;
    return true;
  end if;
  if jsonb_typeof(p_result) <> 'object' or jsonb_typeof(p_result -> 'items') <> 'array'
     or jsonb_array_length(p_result -> 'items') > 30 then
    raise exception 'INVALID_RESULT' using errcode = 'PT422';
  end if;
  for entry in select value from jsonb_array_elements(p_result -> 'items') loop
    insert into app.inbox_items(capture_id, ordinal, kind, display_name, source_span,
      origin_type, confidence, day_index, archived)
    values (p_capture_id, n, entry ->> 'kind', entry ->> 'display_name', entry ->> 'source_span',
      entry ->> 'origin_type', entry ->> 'confidence', nullif(entry ->> 'day_index', '')::int,
      coalesce((entry ->> 'auto_archive')::boolean, false));
    n := n + 1;
  end loop;
  days := p_result -> 'template_days';
  if jsonb_typeof(days) = 'array' and jsonb_array_length(days) > 0 then
    insert into app.itinerary_templates(capture_id, owner_id, title, draft)
    values (p_capture_id, c.owner_id, left(coalesce(nullif(c.title, ''), '分享的行程'), 200),
            jsonb_build_object('days', days));
  end if;
  update app.inbox_captures set status = case when n = 0 and
      (case when jsonb_typeof(days) = 'array' then jsonb_array_length(days) else 0 end) = 0
      then 'insufficient' else 'ready' end,
    content_kind = coalesce(p_result ->> 'content_kind', 'unknown'), model = p_model,
    analysis_attempt = null, updated_at = now() where id = p_capture_id;
  return true;
end;
$$;

-- 分析耗費另設個人額度；成功 claim 後才消耗。
create or replace function app.consume_ai_quota(p_kind text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare uid uuid := app.current_user_id(); per_hour int; per_day int;
begin
  select h, d into per_hour, per_day from
    (values ('parse', 10, 30), ('ask', 40, 200), ('extract', 30, 100), ('inbox', 15, 60)) as limits(k, h, d)
    where k = p_kind;
  if per_hour is null then raise exception 'INVALID_KIND' using errcode = 'PT422'; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text || p_kind));
  if (select count(*) from app.ai_usage where user_id = uid and kind = p_kind and created_at > now() - interval '1 hour') >= per_hour
    or (select count(*) from app.ai_usage where user_id = uid and kind = p_kind and created_at > now() - interval '1 day') >= per_day then
    return false;
  end if;
  insert into app.ai_usage(user_id, kind) values (uid, p_kind);
  delete from app.ai_usage where user_id = uid and created_at < now() - interval '2 days';
  return true;
end;
$$;

revoke execute on function app.save_inbox_capture(uuid,text,text,text,text,text,int),
  app.register_inbox_asset(uuid,int,text,text,bigint,text,text),
  app.update_inbox_item(uuid,int,text,boolean), app.update_inbox_template(uuid,int,text,jsonb),
  app.begin_inbox_analysis(uuid), app.finish_inbox_analysis(uuid,uuid,jsonb,text,text)
  from public, anon, authenticated;
grant execute on function app.save_inbox_capture(uuid,text,text,text,text,text,int),
  app.register_inbox_asset(uuid,int,text,text,bigint,text,text),
  app.update_inbox_item(uuid,int,text,boolean), app.update_inbox_template(uuid,int,text,jsonb)
  to authenticated;
grant execute on function app.begin_inbox_analysis(uuid), app.finish_inbox_analysis(uuid,uuid,jsonb,text,text)
  to service_role;

-- 只把供 AI 使用的縮圖放到私有 bucket。影片原檔暫存於裝置，待真機驗證後才上傳。
do $$ begin
  if to_regclass('storage.objects') is null then return; end if;
  insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
  values ('inbox-images', 'inbox-images', false, 10485760, array['image/jpeg']) on conflict(id) do nothing;
  execute $p$ create policy inbox_images_read on storage.objects for select to authenticated
    using (bucket_id = 'inbox-images' and (storage.foldername(name))[1] = auth.uid()::text) $p$;
  execute $p$ create policy inbox_images_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'inbox-images' and (storage.foldername(name))[1] = auth.uid()::text
      and exists (select 1 from app.inbox_captures c where c.id = app.uuid_or_null((storage.foldername(name))[2])
        and c.owner_id = auth.uid())) $p$;
  execute $p$ create policy inbox_images_delete on storage.objects for delete to authenticated
    using (bucket_id = 'inbox-images' and (storage.foldername(name))[1] = auth.uid()::text) $p$;
  execute $p$ create policy inbox_images_update on storage.objects for update to authenticated
    using (bucket_id = 'inbox-images' and (storage.foldername(name))[1] = auth.uid()::text)
    with check (bucket_id = 'inbox-images' and (storage.foldername(name))[1] = auth.uid()::text) $p$;
end $$;
