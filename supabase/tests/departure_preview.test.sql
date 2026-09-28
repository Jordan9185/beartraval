\set owner '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set outsider '00000000-0000-0000-0000-00000000000d'
set role authenticated;
select tests.login(:'owner');
select id as trip from app.create_trip('退出影響','2026-10-01','2026-10-01','Asia/Tokyo') \gset
select app.create_invite(:'trip','editor') as token \gset
select tests.login(:'editor');
select app.accept_invite(:'token');
select app.save_packing_item(gen_random_uuid(),:'trip',0,'共同轉接頭',2,'',true,false,:'editor');
select app.save_packing_item(gen_random_uuid(),:'trip',0,'私人用品',1,'',false,false,:'editor');
select app.save_packing_item(gen_random_uuid(),:'trip',0,'已裝好的共同用品',1,'',true,true,:'editor');
select id as item from app.add_shopping_item(:'trip','共同待買') \gset
select app.set_shopping_quantities(:'item',0,5,2,:'editor');
select app.preview_trip_departure(:'trip') as preview \gset
select tests.ok(jsonb_array_length(:'preview'::jsonb->'items')=2,'只列未完成共同分工，不公開私人用品');
select tests.ok(exists(select 1 from jsonb_array_elements(:'preview'::jsonb->'items') x where x->>'kind'='shopping' and (x->>'quantity')::int=3),'待買顯示尚缺數量');
select tests.ok(exists(select 1 from jsonb_array_elements(:'preview'::jsonb->'items') x where x->>'name'='共同轉接頭' and (x->>'carrying')::boolean),'顯示攜帶分工');
select app.set_shopping_quantities(:'item',1,5,3,:'editor');
select tests.throws(format('select app.leave_trip(%L,%s)',:'trip',(:'preview'::jsonb->>'revision')),'PT409','預覽後變更需重新確認');
select tests.ok(app.trip_role_of(:'trip')='editor','拒絕過期確認後仍是旅伴');
select tests.login(:'outsider');
select tests.throws(format('select app.preview_trip_departure(%L)',:'trip'),'PT403','外人不可查看影響清單');
select tests.login(:'editor');
select app.preview_trip_departure(:'trip')->>'revision' as revision \gset
select app.leave_trip(:'trip',:'revision');
select tests.login(:'owner');
select tests.ok((select buyer_id is null from app.shopping_items where id=:'item'),'退出後未完成採買回待認領');
select tests.ok((select carrier_id is null from app.packing_items where trip_id=:'trip' and name='共同轉接頭'),'退出後未完成攜帶回待認領');
select tests.ok((select carrier_id=:'editor' from app.packing_items where trip_id=:'trip' and name='已裝好的共同用品'),'完成紀錄保留原攜帶人');
