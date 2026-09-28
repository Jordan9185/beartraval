\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('安排位置','2026-10-01','2026-10-02','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' and display_order=0 \gset
select id as other_day from app.trip_days where trip_id=:'trip' and display_order=1 \gset
select app.commit_itinerary(:'day',0,'[{"raw_label":"早餐"},{"raw_label":"固定晚餐","fixed":true,"start_time":"18:00"}]');
select id as anchor from app.stops where day_id=:'day' and fixed \gset
select app.commit_itinerary(:'other_day',0,'[{"raw_label":"隔日行程"}]');
select id as wrong from app.stops where day_id=:'other_day' \gset
select app.save_place(:'trip','新增甲') ->> 'id' as a \gset
select app.save_place(:'trip','新增乙') ->> 'id' as b \gset
select jsonb_build_array(jsonb_build_object('kind','saved','item_id',:'a','day_id',:'day','operation_id',gen_random_uuid(),'before_stop_id',:'anchor'),jsonb_build_object('kind','saved','item_id',:'b','day_id',:'day','operation_id',gen_random_uuid(),'before_stop_id',:'wrong')) as invalid \gset
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,gen_random_uuid())',:'trip',:'invalid',jsonb_build_object(:'day',1)),'PT422','跨日錨點不可插入');
select tests.ok((select count(*)=2 from app.stops where day_id=:'day' and deleted_at is null),'第二項失敗第一項也回滾');
select jsonb_set(:'invalid'::jsonb,'{1,before_stop_id}',to_jsonb(:'anchor'::text)) as actions \gset
select gen_random_uuid() as op \gset
select app.confirm_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'day',1),:'op');
select tests.ok((select array_agg(raw_label order by sort_order)=array['早餐','新增甲','新增乙','固定晚餐'] from app.stops where day_id=:'day' and deleted_at is null),'同一位置按預覽順序插入');
select tests.ok((select fixed and start_time='18:00' from app.stops where id=:'anchor'),'固定時段不改動');
select app.confirm_ai_arrangements(:'trip',:'actions',jsonb_build_object(:'day',1),:'op');
select tests.ok((select count(*)=4 from app.stops where day_id=:'day' and deleted_at is null),'位置安排重送不重複');
select id as product from app.add_shopping_item(:'trip','商品甲') \gset
select id as product2 from app.add_shopping_item(:'trip','商品乙') \gset
select app.set_shopping_store_suggestions(:'product','[{"name":"採買店","address_local":"完整地址","search_query":"採買店","reason":"來源","source_url":"https://example.test/store"}]');
select app.set_shopping_store_suggestions(:'product2','[{"name":"採買店","address_local":"完整地址","search_query":"採買店","reason":"來源","source_url":"https://example.test/store"}]');
select route_revision as revision from app.trip_days where id=:'day' \gset
select jsonb_build_array(jsonb_build_object('kind','shopping','item_id',:'product','day_id',:'day','candidate_index',0,'source_url','https://example.test/store','store_name','採買店','address_local','完整地址','operation_id',gen_random_uuid(),'before_stop_id',:'anchor'),jsonb_build_object('kind','shopping','item_id',:'product2','day_id',:'day','candidate_index',0,'source_url','https://example.test/store','store_name','採買店','address_local','完整地址','operation_id',gen_random_uuid(),'before_stop_id',:'anchor')) as shopping_actions \gset
select app.confirm_ai_arrangements(:'trip',:'shopping_actions',jsonb_build_object(:'day',:'revision'::bigint),gen_random_uuid());
select tests.ok((select array_agg(raw_label order by sort_order)=array['早餐','新增甲','新增乙','採買店','固定晚餐'] from app.stops where day_id=:'day' and deleted_at is null),'多商品插入同一位置只共用一站');
select app.save_place(:'trip','固定收藏') ->> 'id' as fixed_saved \gset
select route_revision as revision from app.trip_days where id=:'day' \gset
select app.schedule_saved(:'fixed_saved',:'day',:'revision',gen_random_uuid())->>'stop_id' as fixed_saved_stop \gset
select route_revision as revision from app.trip_days where id=:'day' \gset
select jsonb_agg(jsonb_build_object('id',id,'raw_label',raw_label,'fixed',fixed or id=:'fixed_saved_stop','start_time',start_time) order by sort_order) as drafts from app.stops where day_id=:'day' and deleted_at is null \gset
select app.commit_itinerary(:'day',:'revision',:'drafts');
select route_revision as revision from app.trip_days where id=:'day' \gset
select app.unschedule_saved(:'fixed_saved',:'fixed_saved_stop',:'revision',true);
select tests.ok((select deleted_at is null and fixed from app.stops where id=:'fixed_saved_stop'),'收藏建立後手動固定的行程仍保留');
