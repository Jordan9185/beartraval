-- 個人收件：去重、背景結果、權限與更正的 revision。
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select tests.ok(app.consume_ai_quota('inbox'), '收件整理可寫入自己的 AI 額度紀錄');

select (app.save_inbox_capture(
  '11111111-1111-1111-1111-111111111111',
  repeat('a', 64), 'https://threads.com/post/1', 'https://threads.com/post/1?utm_source=x',
  '首爾三日遊', 'Day 1 明洞餃子\nDay 2 聖水咖啡')) ->> 'id' as capture_id \gset
select tests.ok((select count(*) = 1 from app.inbox_captures), '分享成功寫入個人收件');

select tests.ok((app.save_inbox_capture(
  '22222222-2222-2222-2222-222222222222',
  repeat('b', 64), 'https://threads.com/post/1', 'https://threads.com/post/1',
  '另一個標題', '另一段文字') ->> 'created') = 'false', '相同網址不新增收件');
select tests.ok((select share_count = 2 and raw_text like 'Day 1%' from app.inbox_captures where id = :'capture_id'),
  '重複分享只更新次數，原文不被覆寫');

select app.register_inbox_asset(:'capture_id', 0, 'video', 'video/mp4', 1000, repeat('c', 64));
select tests.ok((select status = 'local_only' from app.inbox_assets where capture_id = :'capture_id'),
  '影片尚未上傳時如實標示本機');
select tests.throws(
  'select app.register_inbox_asset(''' || :'capture_id' || ''', 1, ''image'', ''image/jpeg'', 100, ''' || repeat('d', 64) || ''', ''other-user/file.jpg'')',
  'PT422', '不可登記其他帳號的圖片路徑');

set role service_role;
select tests.ok(has_table_privilege('service_role', 'app.inbox_assets', 'SELECT'),
  '背景整理工作可讀取圖片中繼資料');
select app.begin_inbox_analysis(:'capture_id') as attempt \gset
select app.begin_inbox_analysis(:'capture_id') is null as running \gset
select app.finish_inbox_analysis(:'capture_id', :'attempt',
  '{"content_kind":"itinerary","items":[{"kind":"place","display_name":"明洞餃子","source_span":"明洞餃子","origin_type":"explicit","confidence":"high","day_index":1,"auto_archive":true}],"template_days":[{"day_index":1,"source_span":"Day 1 明洞餃子","stops":[{"label":"明洞餃子","source_span":"明洞餃子","origin_type":"explicit"}]}]}'::jsonb,
  null, 'claude-sonnet-5') as finished \gset
select app.begin_inbox_analysis(:'capture_id') is null as no_retry \gset

set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select tests.ok(:'running'::boolean, '同一份收件只有一個進行中的分析');
select tests.ok(:'finished'::boolean, '完成分析並保存候選和模板');
select tests.ok(:'no_retry'::boolean, '完成後重送不重新計費');
select tests.ok((select count(*) = 1 from app.inbox_items where archived), '明確來源可進個人收藏');
select tests.ok((select count(*) = 1 from app.itinerary_templates), '行程模板與正式 Trip 分離');
select id as item_id from app.inbox_items where capture_id = :'capture_id' \gset
select id as template_id from app.itinerary_templates where capture_id = :'capture_id' \gset
select tests.ok((app.update_inbox_item(:'item_id', 0, '明洞餃子本店', false)).revision = 1,
  '使用者可更正並撤銷歸檔');
select tests.throws('select app.update_inbox_item(''' || :'item_id' || ''', 0, null, true)', 'PT409',
  '過期 revision 不能覆蓋更正');

select tests.login('00000000-0000-0000-0000-00000000000b');
select tests.ok((select count(*) = 0 from app.inbox_captures) and (select count(*) = 0 from app.inbox_items)
  and (select count(*) = 0 from app.itinerary_templates), '另一帳號無法讀取原文、候選或模板');
select tests.throws('select app.update_inbox_item(''' || :'item_id' || ''', 1, null, true)', 'PT404',
  '另一帳號不能改候選');
select tests.throws('select app.update_inbox_template(''' || :'template_id' || ''', 0, ''偷改'', ''{}'')', 'PT404',
  '另一帳號不能改模板');

select tests.login('00000000-0000-0000-0000-00000000000a');
select tests.ok((app.update_inbox_template(:'template_id', 0, '我的首爾行程',
  '{"days":[{"day_index":1,"source_span":"Day 1 明洞餃子","stops":[{"label":"明洞餃子本店","source_span":"明洞餃子","origin_type":"explicit"}]}]}'::jsonb)).revision = 1,
  '本人可保存調整後模板');

select id as existing_trip from app.create_trip('既有旅程', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select id as day_id from app.trip_days where trip_id = :'existing_trip' \gset
select app.commit_itinerary(:'day_id', 0, '[{"raw_label":"固定機票","fixed":true}]');
select tests.throws('select app.apply_inbox_template(''' || :'template_id' || ''', 1,
  ''33333333-3333-3333-3333-333333333333'', ''' || :'existing_trip' || ''', null, null,
  ''{"' || :'day_id' || '":0}'')', 'PT409', '旅伴改過行程時拒絕過期套用');
select tests.ok((select count(*) = 1 from app.stops where trip_id = :'existing_trip' and deleted_at is null),
  '過期套用不留下部分寫入');

select tests.ok((app.apply_inbox_template(:'template_id', 1,
  '33333333-3333-3333-3333-333333333333', :'existing_trip', null, null,
  jsonb_build_object(:'day_id', 1)) ->> 'duplicate') = 'false', '確認後才套用既有旅程');
select tests.ok((select count(*) = 2 from app.stops where trip_id = :'existing_trip' and deleted_at is null)
  and (select fixed from app.stops where trip_id = :'existing_trip' and raw_label = '固定機票'),
  '固定行程未移動且新停靠點是待定位文字');
select tests.ok((app.apply_inbox_template(:'template_id', 1,
  '33333333-3333-3333-3333-333333333333', :'existing_trip', null, null,
  jsonb_build_object(:'day_id', 1)) ->> 'duplicate') = 'true', '網路重送不重複加入 Stop');

select (app.apply_inbox_template(:'template_id', 1,
  '44444444-4444-4444-4444-444444444444', null, '2026-11-01', 'Asia/Seoul')) ->> 'trip_id' as new_trip \gset
select tests.ok((select count(*) = 1 from app.stops where trip_id = :'new_trip' and resolution_status = 'pending_text'),
  '確認後可從模板建立新旅程，地點仍待確認');

select id as place_id from app.places limit 1 \gset
select tests.ok((app.confirm_inbox_place(:'item_id', 1, :'place_id')).resolution_status = 'verified',
  '個人項目確認 POI 後才標記為已定位');
select tests.login('00000000-0000-0000-0000-00000000000b');
select tests.throws('select app.confirm_inbox_place(''' || :'item_id' || ''', 2, ''' || :'place_id' || ''')',
  'PT404', '另一帳號不能確認個人 POI');
