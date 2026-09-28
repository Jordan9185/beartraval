\set owner '00000000-0000-0000-0000-00000000000a'
\set viewer '00000000-0000-0000-0000-00000000000c'
set role authenticated;
select tests.login(:'owner');
create function pg_temp.revs(p_trip uuid) returns jsonb language sql as $$
  select jsonb_object_agg(id::text, route_revision) from app.trip_days where trip_id = p_trip $$;
-- 換店動作只帶使用者在畫面看到的候選店名、地址與來源。
create function pg_temp.swap(p_item uuid, p_from uuid, p_day uuid, p_idx int, p_remove boolean) returns jsonb language sql as $$
  select jsonb_build_object('kind','shopping_swap','item_id',i.id,'source_stop_id',p_from,
    'source_day_id',(select day_id from app.stops where id = p_from),'day_id',p_day,'candidate_index',p_idx,
    'source_url',i.store_suggestions->p_idx->>'source_url','store_name',i.store_suggestions->p_idx->>'name',
    'address_local',i.store_suggestions->p_idx->>'address_local','remove_empty_source',p_remove,'operation_id',gen_random_uuid())
  from app.shopping_items i where i.id = p_item $$;
create function pg_temp.stores(p_first text) returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('name',p_first,'address_local',p_first||'地址','search_query',p_first,'reason','來源','source_url','https://example.test/'||md5(p_first)),
    jsonb_build_object('name','店乙','address_local','店乙地址','search_query','店乙','reason','來源','source_url','https://example.test/b')) $$;
create function pg_temp.item(p_trip uuid, p_name text, p_store text, p_day uuid) returns uuid language plpgsql as $$
declare id uuid;
begin
  select (app.add_shopping_item(p_trip, p_name)).id into id;
  perform app.set_shopping_store_suggestions(id, pg_temp.stores(p_store));
  perform app.schedule_shopping_store(id, 0, 'https://example.test/'||md5(p_store), p_day,
    (select route_revision from app.trip_days where trip_days.id = p_day), gen_random_uuid());
  return id;
end $$;

select id as trip from app.create_trip('換店','2026-10-01','2026-10-02','Asia/Seoul') \gset
select id as day from app.trip_days where trip_id=:'trip' and display_order=0 \gset
select id as day2 from app.trip_days where trip_id=:'trip' and display_order=1 \gset

-- 兩件商品共用店甲，只換其中一件。
select pg_temp.item(:'trip','商品一','店甲',:'day') as item \gset
select pg_temp.item(:'trip','商品二','店甲',:'day') as other \gset
select planned_stop_id as shared from app.shopping_items where id=:'item' \gset
select tests.ok((select planned_stop_id=:'shared' from app.shopping_items where id=:'other'),'前提：兩件商品共站');
select app.set_shopping_quantities(:'item',0,3,1,null,'[]',gen_random_uuid());
select pg_temp.revs(:'trip') as old_revs \gset
select jsonb_build_array(pg_temp.swap(:'item',:'shared',:'day2',1,true)) as actions \gset
select gen_random_uuid() as op \gset

select tests.login(:'viewer');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,%L)',:'trip',:'actions',:'old_revs',:'op'),'PT403','檢視者不可換店');
select tests.login(:'owner');

select app.preview_ai_arrangements(:'trip',:'actions',:'old_revs',:'op') as preview \gset
select tests.ok((select planned_stop_id=:'shared' from app.shopping_items where id=:'item'),'預覽不保存換店');
select tests.ok(exists(select 1 from jsonb_array_elements(:'preview'::jsonb->'after') d, jsonb_array_elements(d->'stops') s
  where d->'day'->>'id'=:'day2' and s->>'raw_label'='店乙'),'預覽列出新店所在日期');
select tests.ok(exists(select 1 from jsonb_array_elements(:'preview'::jsonb->'after') d where d->'day'->>'id'=:'day'),'預覽同時列出原站日期');

select app.confirm_ai_arrangements(:'trip',:'actions',:'old_revs',:'op') as result \gset
select planned_stop_id as moved from app.shopping_items where id=:'item' \gset
select tests.ok((select s.day_id=:'day2' and i.scheduled_store_name='店乙' and i.scheduled_store_source_url='https://example.test/b'
  from app.shopping_items i join app.stops s on s.id=i.planned_stop_id where i.id=:'item'),'換到選定日期的新店');
select tests.ok((select planned_stop_id=:'shared' from app.shopping_items where id=:'other'),'另一件商品不被搬走');
select tests.ok((select deleted_at is null from app.stops where id=:'shared'),'原站仍有其他商品使用就保留');
select tests.ok((:'result'::jsonb->0->'swapped_from'->>'removed')::boolean = false,'回傳原站保留');
select tests.ok((select bought_quantity=1 and desired_quantity=3 from app.shopping_items where id=:'item'),'不改已購買與需求數量');
select tests.ok((select count(*)=2 from app.shopping_items where trip_id=:'trip' and deleted_at is null),'不複製商品');

select count(*) as stops_before from app.stops where trip_id=:'trip' and deleted_at is null \gset
select app.confirm_ai_arrangements(:'trip',:'actions',:'old_revs',:'op') as retried \gset
select tests.ok(:'retried'::jsonb = :'result'::jsonb,'回應遺失後以同一操作查回原結果');
select tests.ok((select count(*)=:stops_before from app.stops where trip_id=:'trip' and deleted_at is null),'重送不新增站點');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,%L)',:'trip',:'actions',:'old_revs',gen_random_uuid()),'PT409','舊畫面另開一次換店被拒');

-- 另一件改到同一新店：沿用新站，不再新增；原站明確保留。
select app.confirm_ai_arrangements(:'trip',jsonb_build_array(pg_temp.swap(:'other',:'shared',:'day2',1,false)),pg_temp.revs(:'trip'),gen_random_uuid());
select tests.ok((select planned_stop_id=:'moved' from app.shopping_items where id=:'other'),'同店同日沿用已存在的新站');
select tests.ok((select deleted_at is null from app.stops where id=:'shared'),'未選擇移除時空站保留');

-- 確認前旅伴改了原日期：過期整批不寫。
select pg_temp.item(:'trip','商品三','店丙',:'day') as third \gset
select planned_stop_id as third_stop from app.shopping_items where id=:'third' \gset
select pg_temp.revs(:'trip') as seen \gset
-- 模擬旅伴先在原日完成另一項編輯。
reset role;
update app.trip_days set route_revision=route_revision+1 where id=:'day';
set role authenticated;
select tests.login(:'owner');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,%L)',:'trip',jsonb_build_array(pg_temp.swap(:'third',:'third_stop',:'day2',1,true)),:'seen',gen_random_uuid()),'PT409','確認前原日被改則拒絕');
select tests.ok((select planned_stop_id=:'third_stop' from app.shopping_items where id=:'third'),'過期時原安排不變');

-- 新店候選與畫面不符：撤回一併回滾。
select jsonb_set(pg_temp.swap(:'third',:'third_stop',:'day2',1,true),'{store_name}','"猜的分店"') as guessed \gset
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,%L)',:'trip',jsonb_build_array(:'guessed'::jsonb),pg_temp.revs(:'trip'),gen_random_uuid()),'PT409','店名不符不猜分店');
select tests.ok((select planned_stop_id=:'third_stop' and scheduled_store_name='店丙' from app.shopping_items where id=:'third'),'新店失敗時舊關聯回滾');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,%L)',:'trip',jsonb_build_array(pg_temp.swap(:'third',:'third_stop',:'day',0,true)),pg_temp.revs(:'trip'),gen_random_uuid()),'PT422','同店同日不算換店');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,%L)',:'trip',jsonb_build_array(pg_temp.swap(:'third',:'third_stop',:'day2',1,true),
  jsonb_build_object('kind','shopping','item_id',:'third','day_id',:'day2','candidate_index',1,'source_url','https://example.test/b','store_name','店乙','address_local','店乙地址','operation_id',gen_random_uuid())),
  pg_temp.revs(:'trip'),gen_random_uuid()),'PT422','同批不可重複處理同一商品');
select tests.throws(format('select app.confirm_ai_arrangements(%L,%L,%L,%L)',:'trip',jsonb_build_array(pg_temp.swap(:'third',:'third_stop',:'day2',1,true),
  jsonb_build_object('kind','stop_remove','item_id',:'shared','day_id',:'day','source_day_id',:'day2')),pg_temp.revs(:'trip'),gen_random_uuid()),'PT409','同批其他失敗整批回滾');
select tests.ok((select planned_stop_id=:'third_stop' from app.shopping_items where id=:'third'),'整批回滾保留原安排');

-- 明確移除無其他用途的採買站。
select app.confirm_ai_arrangements(:'trip',jsonb_build_array(pg_temp.swap(:'third',:'third_stop',:'day2',1,true)),pg_temp.revs(:'trip'),gen_random_uuid()) as removed \gset
select tests.ok((select deleted_at is not null from app.stops where id=:'third_stop'),'明確同意才刪除空採買站');
select tests.ok((:'removed'::jsonb->0->'swapped_from'->>'removed')::boolean,'回傳原站已移除');

-- 固定站與收藏共站，即使要求移除也保留。
select pg_temp.item(:'trip','商品四','店丁',:'day') as fixed_item \gset
select planned_stop_id as fixed_stop from app.shopping_items where id=:'fixed_item' \gset
reset role;
update app.stops set fixed=true where id=:'fixed_stop';
set role authenticated;
select tests.login(:'owner');
select app.confirm_ai_arrangements(:'trip',jsonb_build_array(pg_temp.swap(:'fixed_item',:'fixed_stop',:'day2',1,true)),pg_temp.revs(:'trip'),gen_random_uuid());
select tests.ok((select deleted_at is null and fixed from app.stops where id=:'fixed_stop'),'固定站不因換店刪除');

select pg_temp.item(:'trip','商品五','店戊',:'day') as saved_item \gset
select planned_stop_id as saved_stop from app.shopping_items where id=:'saved_item' \gset
select app.save_place(:'trip','店戊','shop') ->> 'id' as saved \gset
reset role;
update app.saved_places set planned_stop_id=:'saved_stop' where id=:'saved';
set role authenticated;
select tests.login(:'owner');
select app.confirm_ai_arrangements(:'trip',jsonb_build_array(pg_temp.swap(:'saved_item',:'saved_stop',:'day2',1,true)),pg_temp.revs(:'trip'),gen_random_uuid());
select tests.ok((select deleted_at is null from app.stops where id=:'saved_stop'),'收藏共用站不因換店刪除');

-- 另次到訪是使用者另外安排的行程，換主要店家不撤掉它。
select pg_temp.item(:'trip','商品六','店己',:'day') as visit_item \gset
select planned_stop_id as visit_stop from app.shopping_items where id=:'visit_item' \gset
select app.add_shopping_visit(:'visit_item',:'visit_stop',:'day2',(select route_revision from app.trip_days where id=:'day2'),gen_random_uuid()) as extra \gset
select app.confirm_ai_arrangements(:'trip',jsonb_build_array(pg_temp.swap(:'visit_item',:'visit_stop',:'day2',1,true)),pg_temp.revs(:'trip'),gen_random_uuid());
select tests.ok((select removed_at is null from app.shopping_extra_visits where stop_id=:'extra'),'另次到訪保留');
select tests.ok((select deleted_at is null from app.stops where id=:'extra'),'另次到訪站保留');
