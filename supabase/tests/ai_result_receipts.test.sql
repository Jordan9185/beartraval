\set owner '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set outsider '00000000-0000-0000-0000-00000000000d'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('私人 AI 結果','2026-10-01','2026-10-01','Asia/Tokyo') \gset
select app.create_invite(:'trip','editor') as token \gset
select tests.login(:'editor');
select app.accept_invite(:'token');
reset role;
insert into app.ai_messages(trip_id,user_id,question,answer,status) values(:'trip',:'owner','我的私人問題','{"answer":"私人回答"}','answered') returning id as mine \gset
insert into app.ai_messages(trip_id,user_id,question,answer,status) values(:'trip',:'editor','旅伴私人問題','{"answer":"旅伴回答"}','answered') returning id as theirs \gset
insert into app.ai_messages(trip_id,user_id,question,status) values(:'trip',:'owner','失敗問題','failed');
set role authenticated;
select tests.login(:'owner');
select tests.ok(app.unread_ai_message_count(:'trip')=1,'只計本人已完成回答，不計失敗或旅伴資料');
select tests.ok((select count(*)=2 from app.ai_messages where trip_id=:'trip'),'擁有者不能查看旅伴私人對話');
select tests.throws(format('select app.mark_ai_message_read(%L)',:'theirs'),'PT404','擁有者不能更動旅伴已讀狀態');
select app.mark_ai_message_read(:'mine');
select tests.ok(app.unread_ai_message_count(:'trip')=0,'讀取後取消本人待查看提示');
select read_at as first_read from app.ai_messages where id=:'mine' \gset
select app.mark_ai_message_read(:'mine');
select tests.ok((select read_at=:'first_read'::timestamptz from app.ai_messages where id=:'mine'),'重送不改第一次確認時間');
select tests.login(:'outsider');
select tests.throws(format('select app.unread_ai_message_count(%L)',:'trip'),'PT403','無關帳號不能查看計數');
select tests.login(:'editor');
select tests.ok(app.unread_ai_message_count(:'trip')=1,'本人已讀不影響旅伴');
select app.leave_trip(:'trip');
select tests.throws(format('select app.mark_ai_message_read(%L)',:'theirs'),'PT404','退出後不可標示旅程結果');
select tests.ok((select count(*)=0 from app.ai_messages where trip_id=:'trip'),'退出後服務端不回傳私人旅程回答');
