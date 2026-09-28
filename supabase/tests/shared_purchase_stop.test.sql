\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('同店購物','2026-10-01','2026-10-01','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' \gset
select id as one from app.add_shopping_item(:'trip','商品甲') \gset
select id as two from app.add_shopping_item(:'trip','商品乙') \gset
select app.set_shopping_store_suggestions(:'one','[{"name":"店甲","address_local":"測試地址","search_query":"店甲","reason":"來源","source_url":"https://example.test/a"}]');
select app.set_shopping_store_suggestions(:'two','[{"name":"店甲","address_local":"測試地址","search_query":"店甲","reason":"來源","source_url":"https://example.test/a"}]');
select app.schedule_shopping_store(:'one',0,'https://example.test/a',:'day',0,gen_random_uuid())->>'stop_id' as stop \gset
select app.schedule_shopping_store(:'two',0,'https://example.test/a',:'day',1,gen_random_uuid());
select tests.ok((select count(*)=1 from app.stops where trip_id=:'trip' and deleted_at is null),'同店同日共用一站');
select app.unschedule_purchase(:'one',:'stop',1);
select tests.ok((select planned_stop_id is null from app.shopping_items where id=:'one'),'只撤回選定商品');
select tests.ok((select planned_stop_id=:'stop' from app.shopping_items where id=:'two'),'其他商品仍保留安排');
select tests.ok((select deleted_at is null and shopping_item_id=:'two' from app.stops where id=:'stop'),'共用站保留並重新指定代表商品');
select app.unschedule_purchase(:'one',:'stop',1);
select tests.ok((select route_revision=2 from app.trip_days where id=:'day'),'重送撤回不重複修改');
select tests.throws(format('select app.unschedule_purchase(%L,%L,1)',:'two',:'stop'),'PT409','舊版本不能撤回另一件');
select app.unschedule_purchase(:'two',:'stop',2,true);
select tests.ok((select deleted_at is not null from app.stops where id=:'stop'),'最後商品撤回後移除空採買站');
select tests.ok((select count(*)=2 from app.shopping_items where trip_id=:'trip' and deleted_at is null),'購物清單仍保留');
select route_revision as revision from app.trip_days where id=:'day' \gset
select app.commit_itinerary(:'day',:'revision','[{"raw_label":"原有店家行程","destination_name":"店甲","destination_address":"測試地址","destination_source":"https://example.test/a"}]');
select id as existing from app.stops where trip_id=:'trip' and deleted_at is null \gset
select route_revision as revision from app.trip_days where id=:'day' \gset
select app.schedule_shopping_store(:'one',0,'https://example.test/a',:'day',:'revision',gen_random_uuid());
select tests.ok((select planned_stop_id=:'existing' from app.shopping_items where id=:'one'),'既有一般行程同店地址可直接沿用');
select app.unschedule_purchase(:'one',:'existing',:'revision',true);
select tests.ok((select deleted_at is null from app.stops where id=:'existing'),'即使要求移除空採買站，也保留原有的一般行程用途');
