\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('購物數量','2026-10-01','2026-10-02','Asia/Seoul') \gset
select id as item from app.add_shopping_item(:'trip','雨傘') \gset
select app.set_shopping_quantities(:'item',0,3,2,null,'[]','30000000-0000-0000-0000-000000000001');
select tests.ok((select bought_quantity=2 and desired_quantity=3 from app.shopping_items where id=:'item'),'部分購買保持未買齊');
select tests.ok((select type='undone' from app.purchase_events where item_id=:'item' order by id desc limit 1),'舊版也不顯示已完成');
select app.set_shopping_quantities(:'item',0,3,2,null,'[]','30000000-0000-0000-0000-000000000001');
select tests.ok((select count(*)=1 from app.purchase_events where item_id=:'item'),'重送不重複購買事件');
select tests.throws(format($$select app.set_shopping_quantities(%L,0,3,3)$$,:'item'),'PT409','數量修改拒絕過期版本');
select app.record_purchase(:'item',true);
select tests.ok((select bought_quantity=3 from app.shopping_items where id=:'item'),'舊版勾選等於全部買齊');
select app.record_purchase(:'item',false);
select tests.ok((select bought_quantity=0 from app.shopping_items where id=:'item'),'撤銷不改需求數量');
