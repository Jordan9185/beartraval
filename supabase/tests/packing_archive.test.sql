\set owner '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('用品測試','2026-10-01','2026-10-03','Asia/Seoul') \gset
select app.create_invite(:'trip','editor') as token \gset
select app.save_packing_item('10000000-0000-0000-0000-000000000001',:'trip',0,'雨傘',1,'',false,true);
select app.save_packing_item('10000000-0000-0000-0000-000000000002',:'trip',0,'轉接頭',1,'',true,true);
select app.save_packing_item('10000000-0000-0000-0000-000000000001',:'trip',1,'雨傘',2,'',false,true);
select tests.ok((select not packed from app.packing_items where name='雨傘'),'增加數量重設打包');
select tests.throws(format($$select app.save_packing_item('10000000-0000-0000-0000-000000000001',%L,1,'雨傘',3,'',false,true)$$,:'trip'),'PT409','拒絕過期修改');
select app.set_trip_archived(:'trip',true);
select tests.ok((select count(*)=1 from app.trip_archives),'手動封存');
select tests.ok((select count(*)=1 from app.trips where id=:'trip'),'封存保留旅程');
select tests.login(:'editor');
select app.accept_invite(:'token');
select tests.ok((select count(*)=1 from app.packing_items),'旅伴只看共同用品');
select tests.ok((select count(*)=0 from app.trip_archives),'封存不影響旅伴');
select tests.throws(format($$select app.save_packing_item('10000000-0000-0000-0000-000000000001',%L,2,'雨傘',2,'',false,true)$$,:'trip'),'PT404','不能修改他人私人用品');
select app.save_packing_item('10000000-0000-0000-0000-000000000002',:'trip',1,'轉接頭',1,'已裝好',true,true);
select tests.ok((select updated_by=:'editor'::uuid from app.packing_items),'共同代勾保留操作者');
select tests.login(:'owner');
select app.set_trip_archived(:'trip',false);
select tests.ok((select count(*)=0 from app.trip_archives),'明確恢復');
-- 用品購買的共享範圍與打包獨立。
select app.request_packing_purchase('10000000-0000-0000-0000-000000000001',2,'before_trip');
select tests.ok((select count(*)=1 from app.personal_purchases),'私人用品連私人購買');
select tests.ok((select count(*)=0 from app.shopping_items where trip_id=:'trip'),'私人用品不建立共同商品');
select app.request_packing_purchase('10000000-0000-0000-0000-000000000002',2,'before_trip');
select tests.ok((select count(*)=1 from app.shopping_items where trip_id=:'trip' and purchase_timing='before_trip'),'共同用品進共同購物且保留時機');
select tests.login(:'editor');
select tests.ok((select count(*)=0 from app.personal_purchases),'旅伴看不到私人採買');
select tests.ok((select count(*)=1 from app.shopping_items where trip_id=:'trip'),'旅伴能看到共同採買');
select app.save_packing_item('10000000-0000-0000-0000-000000000003',:'trip',0,'帽子',1,'',false,false,null,null,false,'20000000-0000-0000-0000-000000000003');
select app.save_packing_item('10000000-0000-0000-0000-000000000003',:'trip',0,'帽子',1,'',false,false,null,null,false,'20000000-0000-0000-0000-000000000003');
select tests.ok((select revision=1 from app.packing_items where name='帽子'),'用品重送不增加版本或重建');
