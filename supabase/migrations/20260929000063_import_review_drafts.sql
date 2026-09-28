-- C03 匯入確認草稿跨裝置保存：只屬於建立匯入的本人，不因共同旅程公開。
-- 每次保存核對草稿版本與來源版本；原文重新解析後，舊來源的草稿不能再寫入。
create table app.import_review_drafts (
  import_id uuid primary key references app.import_sessions(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  source_version text not null,
  revision bigint not null default 1,
  state jsonb not null check (pg_column_size(state) <= 524288),
  updated_at timestamptz not null default now()
);
alter table app.import_review_drafts enable row level security;
revoke all on app.import_review_drafts from public, anon, authenticated;

-- 解析完成時的來源識別：同一原文的同一次解析才是同一份草稿的基礎。
create function app.import_source_version(s app.import_sessions) returns text
language sql immutable set search_path = '' as $$
  select coalesce(s.parse_attempt::text, md5(s.raw_text || coalesce(s.parse_result::text, '')))
$$;

create function app.get_import_review(p_import_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s app.import_sessions; r app.import_review_drafts; version text;
begin
  select * into s from app.import_sessions where id = p_import_id and created_by = auth.uid();
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  version := app.import_source_version(s);
  select * into r from app.import_review_drafts where import_id = s.id and owner_id = auth.uid();
  -- 已建立旅程或來源已變更的草稿不再回傳，避免舊選擇套到新解析結果。
  if not found or s.trip_id is not null or s.parse_status <> 'parsed' or r.source_version <> version then
    return jsonb_build_object('source_version', version, 'revision', 0, 'state', null);
  end if;
  return jsonb_build_object('source_version', version, 'revision', r.revision, 'state', r.state);
end $$;

create function app.save_import_review(p_import_id uuid, p_source_version text, p_expected_revision bigint, p_state jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare s app.import_sessions; r app.import_review_drafts;
begin
  select * into s from app.import_sessions where id = p_import_id and created_by = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'PT404'; end if;
  if s.trip_id is not null or s.parse_status <> 'parsed' or p_source_version is distinct from app.import_source_version(s) then
    raise exception 'SOURCE_CHANGED' using errcode = 'PT409';
  end if;
  if jsonb_typeof(p_state) is distinct from 'object' or p_expected_revision is null then
    raise exception 'INVALID_REQUEST' using errcode = 'PT422';
  end if;
  select * into r from app.import_review_drafts where import_id = s.id;
  -- 來源已換的舊草稿從 0 起算；其餘一律比對版本，不以後寫覆蓋另一裝置先保存的選擇。
  if found and r.source_version = p_source_version then
    if r.revision <> p_expected_revision then raise exception 'STALE_REVISION' using errcode = 'PT409'; end if;
  elsif p_expected_revision <> 0 then
    raise exception 'STALE_REVISION' using errcode = 'PT409';
  end if;
  insert into app.import_review_drafts(import_id, owner_id, source_version, revision, state)
    values (s.id, auth.uid(), p_source_version, 1, p_state)
  on conflict (import_id) do update set source_version = excluded.source_version, state = excluded.state,
    revision = case when app.import_review_drafts.source_version = excluded.source_version
                    then app.import_review_drafts.revision + 1 else 1 end,
    updated_at = now()
  returning revision into r.revision;
  return r.revision;
end $$;

revoke all on function app.import_source_version(app.import_sessions), app.get_import_review(uuid),
  app.save_import_review(uuid, text, bigint, jsonb) from public, anon;
grant execute on function app.get_import_review(uuid), app.save_import_review(uuid, text, bigint, jsonb) to authenticated;
notify pgrst, 'reload schema';
