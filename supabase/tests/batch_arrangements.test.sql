\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('批次安排','2026-10-01','2026-10-01','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' \gset
select app.save_place(:'trip','店家甲') ->> 'id' as saved1 \gset
select app.save_place(:'trip','店家乙') ->> 'id' as saved2 \gset
select jsonb_build_array(jsonb_build_object('kind','saved','item_id',:'saved1','day_id',:'day','operation_id','70000000-0000-0000-0000-000000000001'),
 jsonb_build_object('kind','saved','item_id',:'saved2','day_id',:'day','operation_id','70000000-0000-0000-0000-000000000002')) as actions \gset
select app.confirm_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'day',0),'80000000-0000-0000-0000-000000000001');
select tests.ok((select count(*)=2 from app.stops where day_id=:'day' and deleted_at is null),'同日兩筆一次追加');
select app.confirm_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'day',0),'80000000-0000-0000-0000-000000000001');
select tests.ok((select count(*)=2 from app.stops where day_id=:'day' and deleted_at is null),'整批重送不重複');
select tests.throws(format($$select app.confirm_ai_arrangements(%L,%L,%L,'80000000-0000-0000-0000-000000000002')$$,:'trip',:'actions',jsonb_build_object(:'day',0)),'PT409','旅伴修改後整批拒絕');
