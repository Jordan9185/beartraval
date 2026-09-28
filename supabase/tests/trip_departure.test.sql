\set owner '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set outsider '00000000-0000-0000-0000-00000000000d'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('移交測試','2026-10-01','2026-10-01','Asia/Seoul') \gset
select app.create_invite(:'trip','editor') as token \gset
select tests.login(:'editor');
select app.accept_invite(:'token');
select tests.login(:'owner');
select tests.throws(format('select app.leave_trip(%L)',:'trip'),'PT403','擁有者不可直接退出');
select app.offer_trip_ownership(:'trip',:'editor');
select tests.ok((select owner_id=:'owner' from app.trips where id=:'trip'),'發出邀請仍保留原擁有權');
select tests.login(:'outsider');
select tests.ok((select count(*)=0 from app.ownership_offers),'無關帳號看不到移交');
select tests.throws(format('select app.respond_trip_ownership(%L,%L,true)',:'trip',:'owner'),'PT403','無關帳號不能接任');
select tests.login(:'editor');
select app.respond_trip_ownership(:'trip',:'owner',true);
select tests.ok((select owner_id=:'editor' from app.trips where id=:'trip'),'只有本人接受才轉移');
select tests.ok((select count(*)=1 from app.trip_members where trip_id=:'trip' and role='owner' and status='active'),'旅程只有一個擁有者');
select tests.login(:'owner');
select app.leave_trip(:'trip');
select tests.ok(app.trip_role_of(:'trip') is null,'退出立即撤回操作權');
select tests.throws(format('select app.add_shopping_item(%L,%L)',:'trip','退出後送出的離線商品'),'PT403','離線裝置重送也被拒絕');
select tests.login(:'editor');
select tests.ok((select count(*)=1 from app.trips where id=:'trip'),'旅程仍留給其他成員');
