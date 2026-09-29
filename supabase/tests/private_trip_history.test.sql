\set owner '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set other '00000000-0000-0000-0000-00000000000c'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('私人歷史','2026-10-01','2026-10-03','Asia/Seoul') \gset
select app.create_invite(:'trip','editor') as token \gset
select app.save_packing_item('20000000-0000-0000-0000-000000000001',:'trip',0,'擁有者私人藥品',1,'',false,false);

select tests.login(:'editor');
select app.accept_invite(:'token');
select app.save_packing_item('20000000-0000-0000-0000-000000000002',:'trip',0,'旅伴私人雨傘',2,'折疊',false,true);
select app.save_packing_item('20000000-0000-0000-0000-000000000003',:'trip',0,'共同轉接頭',1,'',true,false);
select app.request_packing_purchase('20000000-0000-0000-0000-000000000002',1,'before_trip');
select app.leave_trip(:'trip');

select tests.ok((select count(*)=1 from app.private_trip_history where reason='left'),'退出後本人留有一份私人紀錄');
select tests.ok((select trip_name='私人歷史' and jsonb_array_length(packing)=1 and packing->0->>'name'='旅伴私人雨傘'
  and (packing->0->>'packed')::boolean and jsonb_array_length(purchases)=1 from app.private_trip_history),'只含本人私人用品與私人採買');
select tests.ok((select not (packing::text like '%共同轉接頭%') from app.private_trip_history),'共同用品不複製到私人紀錄');
select tests.ok((select count(*)=0 from app.packing_items),'退出後仍讀不到原旅程用品');

select tests.login(:'owner');
select tests.ok((select count(*)=0 from app.private_trip_history),'擁有者看不到旅伴的私人紀錄');
select tests.throws($$select app.delete_private_history((select id from app.private_trip_history limit 1))$$,'PT404','不能刪除他人紀錄');
reset role;
select id as editor_history from app.private_trip_history where owner_id=:'editor' \gset
set role authenticated;
select tests.login(:'owner');
select tests.throws(format('select app.delete_private_history(%L)',:'editor_history'),'PT404','擁有者不能刪旅伴紀錄');

-- 重新加入：原私人資料再次可見，退出快照移除，不重複。
select app.create_invite(:'trip','editor') as token2 \gset
select tests.login(:'editor');
select app.accept_invite(:'token2');
select tests.ok((select count(*)=0 from app.private_trip_history),'重新加入後移除退出快照');
select tests.ok((select count(*)=1 from app.packing_items where not shared),'原私人用品重新可見');

-- 刪除旅程：每位成員各自留下私人紀錄。
select tests.login(:'owner');
select app.delete_trip(:'trip');
select tests.ok((select count(*)=1 and bool_and(reason='trip_deleted') from app.private_trip_history),'擁有者留下自己的私人紀錄');
select tests.ok((select packing->0->>'name'='擁有者私人藥品' from app.private_trip_history),'內容是擁有者本人的私人用品');
select tests.login(:'editor');
select tests.ok((select count(*)=1 and bool_and(reason='trip_deleted') from app.private_trip_history),'旅伴也留下自己的私人紀錄');
select id as mine from app.private_trip_history \gset
select app.delete_private_history(:'mine');
select tests.ok((select count(*)=0 from app.private_trip_history),'本人可明確刪除紀錄');

-- 沒有私人資料的成員不建立空白紀錄；刪帳號時紀錄一併清除。
select tests.login(:'other');
select id as trip2 from app.create_trip('空白旅程','2026-11-01','2026-11-01','Asia/Seoul') \gset
select app.delete_trip(:'trip2');
select tests.ok((select count(*)=0 from app.private_trip_history),'沒有私人資料不建立紀錄');
reset role;
select tests.ok((select count(*)=1 from app.private_trip_history where owner_id=:'owner'),'前提：擁有者仍有紀錄');
delete from auth.users where id=:'owner';
select tests.ok((select count(*)=0 from app.private_trip_history where owner_id=:'owner'),'刪帳號時私人紀錄一併清除');
