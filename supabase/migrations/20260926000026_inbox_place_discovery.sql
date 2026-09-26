-- 地點補查結果保存在個人項目上，避免每次進入收藏都重複搜尋。
-- 只存有引用來源的店名與來源原文地址，不存 AI 推測的座標。
alter table app.inbox_items
  add column discovery_candidates jsonb check (discovery_candidates is null or
    (jsonb_typeof(discovery_candidates) = 'array' and jsonb_array_length(discovery_candidates) <= 3)),
  add column discovery_checked_at timestamptz;
