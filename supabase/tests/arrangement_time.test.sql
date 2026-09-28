\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('指定時間','2026-10-01','2026-10-01','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' \gset
select app.commit_itinerary(:'day',0,'[{"raw_label":"可調整","start_time":"10:00","end_time":"11:00","dwell_minutes":60},{"raw_label":"固定","fixed":true,"start_time":"18:00"}]');
select id as moving from app.stops where day_id=:'day' and not fixed \gset
select id as fixed from app.stops where day_id=:'day' and fixed \gset
select jsonb_build_array(jsonb_build_object('kind','stop_move','item_id',:'moving','day_id',:'day','source_day_id',:'day','start_time','13:30','before_stop_id',:'fixed','operation_id',gen_random_uuid())) as change \gset
select app.confirm_ai_arrangements(:'trip',:'change',jsonb_build_object(:'day',1),gen_random_uuid());
select tests.ok((select start_time='13:30' and end_time is null and dwell_minutes=60 from app.stops where id=:'moving'),'新時間保存當地時刻，舊結束時間不冒充新結果');
select app.save_place(:'trip','新增店家') ->> 'id' as saved \gset
select jsonb_build_array(jsonb_build_object('kind','saved','item_id',:'saved','day_id',:'day','start_time','09:30','operation_id',gen_random_uuid())) as addition \gset
select app.confirm_ai_arrangements(:'trip',:'addition',jsonb_build_object(:'day',2),gen_random_uuid());
select tests.ok((select start_time='09:30' from app.stops where id=(select planned_stop_id from app.saved_places where id=:'saved')),'新增收藏可以指定當地開始時間');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,gen_random_uuid())',:'trip',jsonb_set(:'addition','{0,start_time}','"24:30"'),jsonb_build_object(:'day',3)),'PT422','不接受不存在的時刻');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,gen_random_uuid())',:'trip',jsonb_set(:'addition','{0,start_time}','"11:30"'),jsonb_build_object(:'day',3)),'PT422','新增時沿用既有站不能暗改原時間');
select tests.ok((select start_time='09:30' from app.stops where id=(select planned_stop_id from app.saved_places where id=:'saved')),'遭拒的時間不寫入');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,gen_random_uuid())',:'trip',jsonb_set(:'change','{0,item_id}',to_jsonb(:'fixed'::text)),jsonb_build_object(:'day',3)),'PT422','指定新時間也不能修改固定站');
select tests.ok((select start_time='18:00' and fixed from app.stops where id=:'fixed'),'固定時間保持不變');
