-- 分類修正只改個人項目；舊參數相容、權限與版本保護持續有效。
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.save_inbox_capture(gen_random_uuid(),repeat('c',64)) ->> 'id' as capture_id \gset
reset role;
insert into app.inbox_items(capture_id,ordinal,kind,display_name,source_span,origin_type,confidence,archived,
  store_hint,store_evidence,discovery_candidates,discovery_checked_at)
values(:'capture_id',0,'product','生紫蘇油冷麵','image:1','explicit','high',true,
  '錯誤門市','image:1','[]',now()) returning id as item_id \gset
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000b');
select tests.throws('select app.update_inbox_item(''' || :'item_id' || ''',0,null,null,''place'')', 'PT404', '別人不能改分類');
select tests.login('00000000-0000-0000-0000-00000000000a');
select tests.throws('select app.update_inbox_item(''' || :'item_id' || ''',0,null,null,''food'')', 'PT422', '拒絕未知分類');
select tests.ok((app.update_inbox_item(:'item_id',0,null,null,'place')).kind = 'place', '料理更正為想去');
select tests.ok((select archived and user_corrected and revision = 1 and store_hint is null
  and discovery_checked_at is null and place_id is null and resolution_status = 'unresolved'
  from app.inbox_items where id = :'item_id'), '保留收藏狀態並清除不適用的店家快取');
select tests.throws('select app.update_inbox_item(''' || :'item_id' || ''',0,null,null,''product'')', 'PT409', '舊版本不能改回');
select tests.ok((app.update_inbox_item(:'item_id',1,'冷麵餐廳',true)).kind = 'place', '舊版四參數仍可呼叫');
select tests.ok((select count(*)=0 from app.shopping_items), '不產生共同購物項目');
