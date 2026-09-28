\set owner '00000000-0000-0000-0000-00000000000a'
\set viewer '00000000-0000-0000-0000-00000000000c'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('再訪店家','2026-10-01','2026-10-02','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' and display_order=0 \gset
select id as day2 from app.trip_days where trip_id=:'trip' and display_order=1 \gset
select id as item from app.add_shopping_item(:'trip','商品甲') \gset
select app.set_shopping_store_suggestions(:'item','[{"name":"店甲","address_local":"完整地址","search_query":"店甲","reason":"來源","source_url":"https://example.test/a"}]');
select app.schedule_shopping_store(:'item',0,'https://example.test/a',:'day',0,gen_random_uuid())->>'stop_id' as original \gset
select gen_random_uuid() as op \gset
select tests.login(:'viewer');
select tests.throws(format('select app.add_shopping_visit(%L,%L,%L,0,%L)',:'item',:'original',:'day2',:'op'),'PT403','檢視者不能新增到訪');
select tests.ok((select count(*)=0 from app.shopping_extra_visits),'其他帳號不可讀取再訪');
select tests.login(:'owner');
select tests.throws(format('select app.add_shopping_visit(%L,%L,%L,9,%L)',:'item',:'original',:'day2',:'op'),'PT409','過期版本不新增');
select app.add_shopping_visit(:'item',:'original',:'day2',0,:'op') as extra \gset
select tests.ok((select planned_stop_id=:'original' from app.shopping_items where id=:'item'),'原採買安排不被覆蓋');
select tests.ok((select count(*)=1 from app.shopping_items where trip_id=:'trip'),'不複製商品需求');
select tests.ok((select destination_address='完整地址' and day_id=:'day2' from app.stops where id=:'extra'),'新到訪保留店名地址及選定日');
select app.add_shopping_visit(:'item',:'original',:'day2',0,:'op');
select tests.ok((select count(*)=2 from app.stops where trip_id=:'trip' and deleted_at is null),'重送不變成第三次到訪');
select app.remove_shopping_visit(:'item',:'extra',1,true);
select tests.ok((select deleted_at is null from app.stops where id=:'original'),'撤回再訪仍保留原站');
select tests.ok((select deleted_at is not null from app.stops where id=:'extra'),'明確同意才移除再訪站');
select app.add_shopping_visit(:'item',:'original',:'day2',0,:'op');
select tests.ok((select count(*)=1 from app.stops where trip_id=:'trip' and deleted_at is null),'撤回後遲到的舊重送不復活站點');
select app.add_shopping_visit(:'item',:'original',:'day2',2,gen_random_uuid()) as shared_extra \gset
select id as other_item from app.add_shopping_item(:'trip','商品乙') \gset
select app.set_shopping_store_suggestions(:'other_item','[{"name":"店甲","address_local":"完整地址","search_query":"店甲","reason":"來源","source_url":"https://example.test/a"}]');
select app.schedule_shopping_store(:'other_item',0,'https://example.test/a',:'day2',3,gen_random_uuid());
select tests.ok((select planned_stop_id=:'shared_extra' from app.shopping_items where id=:'other_item'),'其他商品可共用追加到訪站');
select app.unschedule_purchase(:'other_item',:'shared_extra',3,true);
select tests.ok((select deleted_at is null from app.stops where id=:'shared_extra'),'撤回其他商品不刪除仍有追加到訪用途的站');
select app.commit_itinerary(:'day2',4,jsonb_build_array(jsonb_build_object('id',:'shared_extra','raw_label','店甲','fixed',true,'start_time','18:00')));
select app.remove_shopping_visit(:'item',:'shared_extra',5,true);
select tests.ok((select deleted_at is null and fixed from app.stops where id=:'shared_extra'),'追加到訪改為固定後撤回仍保留固定站');
