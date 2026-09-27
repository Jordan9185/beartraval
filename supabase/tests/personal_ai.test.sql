-- 佇列與正式寫入分離；同一需求去重、跨帳號隔離、過期租約及舊原文不得覆蓋。
\set owner '00000000-0000-0000-0000-00000000000a'
\set outsider '00000000-0000-0000-0000-00000000000d'
set role authenticated;
select tests.login(:'owner');
select id as import_id from app.create_import('東京五日','2026-10-01','2026-10-05','Asia/Tokyo','東京五日') \gset
select tests.throws($$select * from app.personal_ai_jobs$$, '42501', 'App 不可直接讀工作原文或租約');
select tests.throws($$select app.claim_personal_ai('00000000-0000-0000-0000-00000000000a')$$, '42501', 'App 不可冒充 Mac');
reset role;
set role service_role;
select id as job_id from app.enqueue_personal_ai(:'owner','parse','{"rawText":"東京五日"}',
  jsonb_build_object('import_id', :'import_id'), 'same-input') \gset
select id as duplicate_id from app.enqueue_personal_ai(:'owner','parse','{"rawText":"東京五日"}',
  jsonb_build_object('import_id', :'import_id'), 'same-input') \gset
reset role;
select tests.ok(:'job_id' = :'duplicate_id', '重試同一份原文沿用工作，不再推論');
select tests.ok((select parse_progress->>'stage' = 'queued' from app.import_sessions where id = :'import_id'), '等待 Mac 狀態可讀');
set role service_role;
select (app.claim_personal_ai(:'outsider')).id is null as isolated \gset
select lease as lease1 from app.claim_personal_ai(:'owner') \gset
reset role;
select tests.ok(:'isolated'::boolean, '不能領取其他帳號工作');
select tests.ok(not app.finish_personal_ai(:'owner', :'job_id', gen_random_uuid(), '{"status":"failed","reason":"test"}','codex/test'), '錯誤租約不能提交');
update app.personal_ai_jobs set lease_until = now() - interval '1 minute' where id = :'job_id';
select tests.ok(not app.finish_personal_ai(:'owner', :'job_id', :'lease1', '{"status":"failed","reason":"test"}','codex/test'), '過期租約不能提交');
set role service_role;
select lease as lease2 from app.claim_personal_ai(:'owner') \gset
reset role;
select tests.ok(:'lease1' <> :'lease2', '中斷後換新租約領回');
set role authenticated;
select tests.login(:'owner');
select app.update_import_text(:'import_id', '大阪五日');
reset role;
select tests.ok(app.finish_personal_ai(:'owner', :'job_id', :'lease2', '{"status":"parsed","parse_result":{"draft":{"days":[]},"issues":[]}}','codex/test'), '舊結果可以結束但不能覆蓋原文');
select tests.ok((select parse_status = 'pending' and raw_text = '大阪五日' from app.import_sessions where id = :'import_id'), '修改原文使舊結果失效');
select tests.ok((select result->>'reason' = 'superseded' and input = '{}' from app.personal_ai_jobs where id = :'job_id'), '已完成工作清除原文與圖片');
select tests.ok(not exists(select 1 from app.trips where name = '東京五日'), 'AI 完成不建立正式行程');

-- 成功解析只寫草稿，重复完成不再寫入。
select id as job2 from app.enqueue_personal_ai(:'owner','parse','{"rawText":"大阪五日"}',jsonb_build_object('import_id', :'import_id'),'new-input') \gset
select lease as lease3 from app.claim_personal_ai(:'owner') \gset
select tests.ok(app.finish_personal_ai(:'owner', :'job2', :'lease3', '{"status":"parsed","parse_result":{"draft":{"days":[]},"issues":[]}}','codex/gpt-5.6-luna'), '草稿可寫回');
select tests.ok(not app.finish_personal_ai(:'owner', :'job2', :'lease3', '{"status":"failed","reason":"overwrite"}','codex/test'), '重送完成不覆蓋既有結果');
select tests.ok((select parse_status = 'parsed' and model = 'codex/gpt-5.6-luna' from app.import_sessions where id = :'import_id'), '記錄實際 GPT 模型');

-- 收件、店家快取與問答也走同一個有租約的完成入口。
insert into app.inbox_captures(owner_id,client_capture_id,fingerprint,raw_text)
values(:'owner',gen_random_uuid(),repeat('a',64),'LOE 香水') returning id as capture_id \gset
select id as inbox_job from app.enqueue_personal_ai(:'owner','inbox','{}',jsonb_build_object('capture_id', :'capture_id'),'inbox') \gset
select lease as inbox_lease from app.claim_personal_ai(:'owner') \gset
select tests.ok(app.finish_personal_ai(:'owner', :'inbox_job', :'inbox_lease',
  '{"status":"ready","result":{"content_kind":"shopping","items":[{"kind":"product","display_name":"LOE 香水","source_span":"LOE 香水","origin_type":"explicit","confidence":"high","day_index":null,"auto_archive":true,"store_hint":"LOE","store_evidence":"LOE 香水"}],"template_days":[]}}',
  'codex/gpt-5.6-sol'), '收件完成可保存商品與店家線索');
select tests.ok((select store_hint = 'LOE' from app.inbox_items where capture_id = :'capture_id'), '保留線索但不改購物清單');
insert into app.inbox_items(capture_id,ordinal,kind,display_name,source_span,origin_type,confidence)
values(:'capture_id',1,'place','店名','店名','explicit','low') returning id as item_id \gset
select id as discovery_job from app.enqueue_personal_ai(:'owner','discover','{}',jsonb_build_object('item_id', :'item_id','revision',0),'discovery') \gset
select lease as discovery_lease from app.claim_personal_ai(:'owner') \gset
select tests.ok(app.finish_personal_ai(:'owner', :'discovery_job', :'discovery_lease', '{"status":"none","candidates":[]}', 'codex/test'), '店家補查寫入自己的候選快取');
select tests.ok((select discovery_checked_at is not null from app.inbox_items where id = :'item_id'), '候選快取保留檢查時間');
select tests.ok((app.enqueue_personal_ai(:'owner','discover','{}',jsonb_build_object('item_id', :'item_id','revision',0),'discovery')).id = :'discovery_job',
  '完成後相同需求重用同一工作，不再排隊');
select tests.ok((select attempts = 1 and result->>'status' = 'none' from app.personal_ai_jobs where id = :'discovery_job'),
  '零候選也是已保存結果，不重複呼叫模型');
set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('問答測試','2026-10-01','2026-10-01','Asia/Tokyo') \gset
reset role;
select id as ask_job from app.enqueue_personal_ai(:'owner','ask','{"question":"今天去哪裡"}',jsonb_build_object('trip_id', :'trip_id'),'ask') \gset
select lease as ask_lease from app.claim_personal_ai(:'owner') \gset
select tests.ok(app.finish_personal_ai(:'owner', :'ask_job', :'ask_lease', '{"status":"answered","answer":{"answer":"尚未安排","cannot_determine":true,"citations":[],"proposal":null}}','codex/test'), '問答完成保存答案');
select tests.ok((select count(*) = 1 from app.ai_messages where trip_id = :'trip_id'), '只有一份問答紀錄');
