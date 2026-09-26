-- 公開貼文摘要能力新增後，先前只有連結而資訊不足的來源可重新整理。
-- insufficient 不含任何已確認項目或模板；ready 仍不可重算以免覆寫使用者更正。
create or replace function app.begin_inbox_analysis(p_capture_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c app.inbox_captures; attempt uuid := gen_random_uuid();
begin
  select * into c from app.inbox_captures where id = p_capture_id for update;
  if not found or c.status = 'ready'
     or (c.status = 'processing' and c.processing_started_at > now() - interval '5 minutes') then return null; end if;
  update app.inbox_captures set status = 'processing', analysis_attempt = attempt,
    processing_started_at = now(), error_code = null, updated_at = now() where id = p_capture_id;
  return attempt;
end;
$$;
