-- 圖片分享可能只有附件，舊版 iOS 的 Encodable 會省略 nil 欄位。
-- 讓未提供標題與網址的請求仍能找到同一個 RPC 簽名。
create or replace function app.save_inbox_capture(
  p_client_capture_id uuid, p_fingerprint text, p_canonical_url text default null,
  p_source_url text default null, p_title text default null, p_raw_text text default '',
  p_unavailable_count int default 0
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

notify pgrst, 'reload schema';
