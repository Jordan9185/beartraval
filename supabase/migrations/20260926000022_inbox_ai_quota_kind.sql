-- Travel Inbox 已加入 consume_ai_quota，使用紀錄的種類限制也必須同步。
alter table app.ai_usage drop constraint ai_usage_kind_check;
alter table app.ai_usage add constraint ai_usage_kind_check
  check (kind in ('parse', 'ask', 'extract', 'inbox'));
