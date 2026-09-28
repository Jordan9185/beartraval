\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as draft from app.create_import('首爾','2026-10-01','2026-10-01','Asia/Seoul','第一天 無垢屋') \gset
select id as trip from app.commit_import(:'draft','[{"date":"2026-10-01","stops":[{"raw_label":"無垢屋","destination_name":"來源中的韓文店名","destination_address":"來源中的韓文地址","destination_source":"https://example.test/shop","fixed":true}]}]') \gset
select tests.ok((select place_id is null and destination_address='來源中的韓文地址' and fixed from app.stops where trip_id=:'trip'),'無座標店家保留地址、來源及固定狀態');
select day_id as day,id as stop from app.stops where trip_id=:'trip' \gset
select app.commit_itinerary(:'day',1,jsonb_build_array(jsonb_build_object('id',:'stop','raw_label','無垢屋','fixed',true)));
select tests.ok((select destination_address='來源中的韓文地址' from app.stops where id=:'stop'),'舊版未帶地址仍保留');
select app.commit_itinerary(:'day',2,jsonb_build_array(jsonb_build_object('id',:'stop','raw_label','另一間店','fixed',true)));
select tests.ok((select destination_address is null from app.stops where id=:'stop'),'改店名不沿用舊地址');
select id as abandoned from app.create_import('等待測試','2026-10-01','2026-10-01','Asia/Seoul','第一天餐廳') \gset
reset role;
set role service_role;
select id as job from app.enqueue_personal_ai(:'owner','parse','{"rawText":"第一天餐廳"}',jsonb_build_object('ai_provider','claude_api','import_id',:'abandoned'),'expiry-parse') \gset
select app.claim_claude_ai(:'job');
reset role;
update app.personal_ai_jobs set lease_until=now()-interval '1 minute' where id=:'job';
set role service_role;
select app.expire_claude_ai(:'owner');
reset role;
select tests.ok((select status='failed' and result->'usage'='null'::jsonb from app.personal_ai_jobs where id=:'job'),'逾時保留未知用量，不重跑');
select tests.ok((select parse_status='failed' and raw_text='第一天餐廳' from app.import_sessions where id=:'abandoned'),'匯入結束處理中並保留原文');
set role authenticated;
select tests.throws(format('select app.expire_claude_ai(%L)',:'owner'),'42501','客戶端不能自行結案');
