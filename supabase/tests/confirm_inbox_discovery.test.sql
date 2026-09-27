set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.save_inbox_capture(gen_random_uuid(),repeat('e',64)) ->> 'id' as capture_id \gset
reset role;
insert into app.inbox_items(capture_id,ordinal,kind,display_name,source_span,origin_type,confidence,discovery_candidates)
values(:'capture_id',0,'place','原始餐廳','image:1','explicit','low',
 '[{"name":"第一間","source_url":"https://example.com/one","address_local":"서울 첫째길 1"},
   {"name":"第二間","source_url":"https://example.com/two","address_local":"서울 둘째길 2"}]') returning id as item_id \gset
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000b');
select tests.throws(format('select app.confirm_inbox_discovery(%L,0,0)', :'item_id'), 'PT404', '不得確認別人的候選');
select tests.login('00000000-0000-0000-0000-00000000000a');
select tests.throws(format('select app.confirm_inbox_discovery(%L,0,-1)', :'item_id'), 'PT422', '拒絕負索引');
select tests.throws(format('select app.confirm_inbox_discovery(%L,0,2)', :'item_id'), 'PT422', '拒絕不存在的候選');
select tests.throws(format('select app.confirm_inbox_discovery(%L,0,null)', :'item_id'), 'PT422', '不得自動猜選候選');
select count(*) as places_before from app.places \gset
select count(*) as stops_before from app.stops \gset
select app.confirm_inbox_discovery(:'item_id',0,1);
select tests.ok((select confirmed_discovery = discovery_candidates -> 1 and archived and user_corrected and revision = 1
 from app.inbox_items where id = :'item_id'), '只確認使用者指定的第二間，保存地址來源並收藏');
select tests.ok((select place_id is null and resolution_status <> 'verified' from app.inbox_items where id = :'item_id'), '店家確認不冒充地圖座標已驗證');
select tests.ok((select count(*) from app.places) = :'places_before'::bigint
 and (select count(*) from app.stops) = :'stops_before'::bigint, '不建立猜測座標或正式行程');
select tests.throws(format('select app.confirm_inbox_discovery(%L,0,0)', :'item_id'), 'PT409', '舊版本不能改成另一間');
select app.update_inbox_item(:'item_id',1,null,false);
select tests.ok((select confirmed_discovery ->> 'name' = '第二間' from app.inbox_items where id = :'item_id'), '撤銷收藏保留確認資訊');
select app.update_inbox_item(:'item_id',2,'更正後餐廳',true);
select tests.ok((select confirmed_discovery is null from app.inbox_items where id = :'item_id'), '改名清除不再適用的候選確認');
select tests.throws(format('select app.confirm_inbox_discovery(%L,3,0)', :'item_id'), 'PT422', '清除候選後不得確認舊結果');
