\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('調整行程','2026-10-01','2026-10-02','Asia/Seoul') \gset
select id as first from app.trip_days where trip_id=:'trip' and display_order=0 \gset
select id as second from app.trip_days where trip_id=:'trip' and display_order=1 \gset
select app.commit_itinerary(:'first',0,'[{"raw_label":"可調整","start_time":"10:00"},{"raw_label":"訂位","fixed":true,"start_time":"18:00"}]');
select id as moving from app.stops where day_id=:'first' and not fixed \gset
select id as fixed from app.stops where day_id=:'first' and fixed \gset
select jsonb_build_array(jsonb_build_object('kind','stop_move','item_id',:'moving','day_id',:'second','source_day_id',:'first','operation_id',gen_random_uuid())) as actions \gset
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,gen_random_uuid())',:'trip',:'actions',jsonb_build_object(:'first',0,:'second',0)),'PT409','跨日移動必須核對來源日版本');
select gen_random_uuid() as op \gset
select app.confirm_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'first',1,:'second',0),:'op');
select tests.ok((select day_id=:'second' and start_time='10:00' from app.stops where id=:'moving'),'移至選定日且保留原時間');
select tests.ok((select route_revision=2 from app.trip_days where id=:'first') and (select route_revision=1 from app.trip_days where id=:'second'),'來源與目標日版本一起更新');
select app.confirm_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'first',1,:'second',0),:'op');
select tests.ok((select route_revision=1 from app.trip_days where id=:'second'),'重送不再移動一次');
select app.save_place(:'trip','新收藏') ->> 'id' as saved \gset
select jsonb_build_array(jsonb_build_object('kind','saved','item_id',:'saved','day_id',:'second','operation_id',gen_random_uuid()),jsonb_build_object('kind','stop_remove','item_id',:'fixed','day_id',:'first','source_day_id',:'first','operation_id',gen_random_uuid())) as invalid \gset
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,gen_random_uuid())',:'trip',:'invalid',jsonb_build_object(:'first',2,:'second',1)),'PT422','AI 不能移除固定站');
select tests.ok((select count(*)=2 from app.stops where trip_id=:'trip' and deleted_at is null),'固定站拒絕時前面的新增一起回滾');
select jsonb_build_array(jsonb_build_object('kind','stop_remove','item_id',:'moving','day_id',:'second','source_day_id',:'second','operation_id',gen_random_uuid())) as removing \gset
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,gen_random_uuid())',:'trip',:'removing'::jsonb || :'removing'::jsonb,jsonb_build_object(:'second',1)),'PT422','同站不能重複變更');
select app.confirm_ai_arrangements(:'trip',:'removing',jsonb_build_object(:'second',1),gen_random_uuid());
select tests.ok((select deleted_at is not null from app.stops where id=:'moving'),'選定移除只軟刪除該站');
select tests.ok((select deleted_at is null and fixed and start_time='18:00' from app.stops where id=:'fixed'),'未選固定站與時間維持不變');
