\set owner '00000000-0000-0000-0000-00000000000a'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('附近收藏','2026-10-01','2026-10-01','Asia/Seoul') \gset
select id as first from app.save_station_place(:'trip','甜點店','地址甲','https://example.test/shops','介紹','eat') \gset
select tests.ok((app.save_station_place(:'trip','甜點店','地址甲','https://example.test/shops','介紹','eat')).id=:'first','關閉再開或重送仍同一收藏');
select tests.ok((app.save_station_place(:'trip','甜點店','地址乙','https://example.test/shops','介紹','eat')).id<>:'first','同頁面的不同分店不能合併');
select tests.ok((select address_hint='地址甲' from app.saved_places where id=:'first'),'名稱與地址原子保存');
select app.dismiss_saved(:'first');
select tests.ok((app.save_station_place(:'trip','甜點店','地址甲','https://example.test/shops','介紹','eat')).id<>:'first','明確重新收藏可建立有效項目');
select tests.ok((app.save_station_place(p_trip_id=>:'trip',p_name=>'地址待確認',p_url=>'https://example.test/unknown')).id is not null,'省略未知地址可收藏，不因 RPC 參數缺失而失敗');

select tests.throws(format($$select app.save_station_place(p_trip_id=>%L,p_name=>'地址待確認',p_url=>'https://example.test/unknown')$$,:'trip'),'PT409','地址未知的同名來源要求核對，不猜合併');
