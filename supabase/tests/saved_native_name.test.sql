\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('日本原文名稱','2026-10-01','2026-10-01','Asia/Tokyo') \gset
select id as day from app.trip_days where trip_id=:'trip' \gset
select app.save_place(:'trip','使用者譯名','eat') ->> 'id' as saved \gset
select tests.throws(format('select app.set_saved_address_hint(%L,%L,null,%L)',:'saved','東京都測試地址','原文店名'),'PT422','原文店名需要來源');
select app.set_saved_address_hint(:'saved','東京都測試地址','https://example.test/store','原文店名');
select tests.ok((select raw_label='使用者譯名' and native_name='原文店名' from app.saved_places where id=:'saved'),'原始譯名與查得店名分開保存');
select app.schedule_saved(:'saved',:'day',0,gen_random_uuid()) ->> 'stop_id' as stop \gset
select tests.ok((select destination_name='原文店名' and raw_label='使用者譯名' and destination_address='東京都測試地址' and place_id is null from app.stops where id=:'stop'),'沒有座標仍把原文店名及地址帶入行程');
select app.set_saved_address_hint(:'saved','東京都新地址','https://example.test/other','新原文店名');
select tests.ok((select destination_name='原文店名' and destination_address='東京都測試地址' from app.stops where id=:'stop'),'補查收藏不偷偷改正式行程');
select app.set_saved_address_hint(:'saved','舊版更新地址');
select tests.ok((select native_name is null from app.saved_places where id=:'saved'),'舊版參數仍可呼叫且不留下不同來源的店名');
