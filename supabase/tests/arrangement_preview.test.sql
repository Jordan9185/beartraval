\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('完整預覽','2026-10-01','2026-10-02','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' and display_order=0 \gset
select id as second from app.trip_days where trip_id=:'trip' and display_order=1 \gset
select app.commit_itinerary(:'day',0,'[{"raw_label":"固定晚餐","start_time":"18:00","fixed":true}]');
select id as fixed from app.stops where day_id=:'day' \gset
select app.save_place(:'trip','新增咖啡') ->> 'id' as saved \gset
select revision as trip_revision from app.trips where id=:'trip' \gset
select gen_random_uuid() as op \gset
select jsonb_build_array(jsonb_build_object('kind','saved','item_id',:'saved','day_id',:'day','start_time','15:00','before_stop_id',:'fixed','operation_id',gen_random_uuid())) as actions \gset
select app.preview_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'day',1),:'op') as preview \gset
select tests.ok(jsonb_array_length(:'preview'::jsonb->'before'->0->'stops')=1 and jsonb_array_length(:'preview'::jsonb->'after'->0->'stops')=2,'預覽呈現原本與變更後完整日程');
select tests.ok(:'preview'::jsonb->'after'->0->'stops'->0->>'start_time'='15:00:00','預覽帶入指定當地時間');
select tests.ok((select count(*)=1 from app.stops where trip_id=:'trip' and deleted_at is null),'預覽不保存新站');
select tests.ok((select planned_stop_id is null and status='saved' from app.saved_places where id=:'saved'),'預覽不更改收藏');
select tests.ok((select route_revision=1 from app.trip_days where id=:'day') and (select revision=:'trip_revision' from app.trips where id=:'trip'),'預覽不增加正式版本');
reset role;
select tests.ok((select count(*)=0 from app.arrangement_receipts where operation_id=:'op'),'預覽不留下正式提交憑據');
set role authenticated;
select tests.login(:'owner');
select app.confirm_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'day',1),:'op');
select tests.ok((select count(*)=2 from app.stops where trip_id=:'trip' and deleted_at is null),'同份預覽確認後才正式寫入');
select app.preview_ai_arrangements(:'trip',jsonb_build_array(jsonb_build_object('kind','saved','item_id',:'saved','day_id',:'second','operation_id',gen_random_uuid())),jsonb_build_object(:'second',0,:'day',2),gen_random_uuid()) as reuse \gset
select tests.ok(jsonb_array_length(:'reuse'::jsonb->'after')=2,'跨日沿用既有站會一併顯示實際所在日');
select tests.ok(:'reuse'::jsonb->'outcomes'->0->>'status'='already_scheduled','預覽明示沿用既有站，不假稱新增到另一天');
