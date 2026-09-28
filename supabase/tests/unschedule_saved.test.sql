\set owner '00000000-0000-0000-0000-00000000000a'
\set viewer '00000000-0000-0000-0000-00000000000c'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('撤回收藏','2026-10-01','2026-10-01','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' \gset
select (app.upsert_place('apple_mapkit','withdraw-test','原文店名',37.54,127.06)).id as place \gset
select app.save_place(:'trip','原文店名','eat') ->> 'id' as saved \gset
select app.resolve_saved(:'saved',:'place');
select app.schedule_saved(:'saved',:'day',0,gen_random_uuid()) ->> 'stop_id' as stop \gset
select tests.login(:'viewer');
select tests.throws(format('select app.unschedule_saved(%L,%L,1)',:'saved',:'stop'),'PT403','檢視者不可撤回');
select tests.login(:'owner');
select tests.throws(format('select app.unschedule_saved(%L,%L,0)',:'saved',:'stop'),'PT409','過期版本不可撤回');
select app.unschedule_saved(:'saved',:'stop',1);
select tests.ok((select status='saved' and planned_stop_id is null and arrangement_detached from app.saved_places where id=:'saved'),'保留收藏及明確解除關聯');
select tests.ok((select deleted_at is null from app.stops where id=:'stop'),'預設不刪行程');
select app.unschedule_saved(:'saved',:'stop',1);
select tests.ok((select route_revision=2 from app.trip_days where id=:'day'),'重送不重複變更版本');
select app.commit_itinerary(:'day',2,jsonb_build_array(jsonb_build_object('id',:'stop','place_id',:'place','raw_label','原文店名')));
select tests.ok((select status='saved' from app.saved_places where id=:'saved'),'編輯保留的站不會重新關聯已撤回收藏');
select app.schedule_saved(:'saved',:'day',3,gen_random_uuid());
select tests.ok((select not arrangement_detached and planned_stop_id=:'stop' from app.saved_places where id=:'saved'),'再次明確安排可重用原站');
select app.unschedule_saved(:'saved',:'stop',3,true);
select tests.ok((select deleted_at is not null from app.stops where id=:'stop'),'明確同意才移除由收藏建立的無其他用途站');
select app.commit_itinerary(:'day',4,jsonb_build_array(jsonb_build_object('place_id',:'place','raw_label','原有行程')));
select id as original from app.stops where day_id=:'day' and deleted_at is null \gset
select app.schedule_saved(:'saved',:'day',5,gen_random_uuid());
select app.unschedule_saved(:'saved',:'original',5,true);
select tests.ok((select deleted_at is null from app.stops where id=:'original'),'既有一般行程即使要求刪除仍保留');
select app.save_place(:'trip','共享店家','shop') ->> 'id' as shared_saved \gset
select app.set_saved_address_hint(:'shared_saved','測試地址','https://example.test/shared');
select app.schedule_saved(:'shared_saved',:'day',6,gen_random_uuid()) ->> 'stop_id' as shared_stop \gset
select id as product from app.add_shopping_item(:'trip','共享商品') \gset
select app.set_shopping_store_suggestions(:'product','[{"name":"共享店家","address_local":"測試地址","search_query":"共享店家","reason":"來源","source_url":"https://example.test/shared"}]');
select app.schedule_shopping_store(:'product',0,'https://example.test/shared',:'day',7,gen_random_uuid());
select tests.ok((select planned_stop_id=:'shared_stop' from app.shopping_items where id=:'product'),'商品沿用收藏建立的站');
select app.unschedule_saved(:'shared_saved',:'shared_stop',7,true);
select tests.ok((select deleted_at is null and destination_address='測試地址' from app.stops where id=:'shared_stop'),'共享採買站與地址不因收藏撤回消失');
