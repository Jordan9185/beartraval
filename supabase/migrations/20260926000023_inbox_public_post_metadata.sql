-- 公開 Threads 分享連結的 Open Graph 文字另存，保留原始分享 payload 不被覆寫。
alter table app.inbox_captures
  add column public_text text check (length(public_text) <= 5000),
  add column resolved_source_url text check (length(resolved_source_url) <= 4000);
