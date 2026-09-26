-- 有來源的商品店家可排入某日；待定位不等於可導航或保證有貨。
\set owner '00000000-0000-0000-0000-00000000000a'
\set viewer '00000000-0000-0000-0000-00000000000c'

set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('聖水洞', '2026-10-01', '2026-10-02', 'Asia/Seoul') \gset
select id as first_day from app.trip_days where trip_id = :'trip_id' and display_order = 0 \gset
select id as second_day from app.trip_days where trip_id = :'trip_id' and display_order = 1 \gset
select id as item_id from app.add_shopping_item(:'trip_id', 'LOE 香水') \gset
select app.set_shopping_store_suggestions(:'item_id',
  '[{"name":"LOE Seongsu","korean_name":"로에 성수","address_local":"서울특별시 성동구 연무장길 12","search_query":"로에 성수","reason":"品牌店面頁","source_url":"https://example.com/loe"}]'::jsonb);
select app.commit_itinerary(:'first_day', 0,
  '[{"raw_label":"已訂餐廳","start_time":"18:00","fixed":true}]');
select id as fixed_stop from app.stops where day_id = :'first_day' and fixed \gset

select (app.schedule_shopping_store(:'item_id', 0, 'https://example.com/loe', :'first_day', 1,
  '20000000-0000-0000-0000-000000000001')) as scheduled \gset
select tests.ok((:'scheduled'::jsonb ->> 'status') = 'scheduled', '商品候選排到選定日期');
select tests.ok((select kind = 'purchase' and resolution_status = 'pending_text' and place_id is null
                   from app.stops where id = (:'scheduled'::jsonb ->> 'stop_id')::uuid),
  '未定位店家只建立待定位購買站');
select tests.ok((select planned_stop_id = (:'scheduled'::jsonb ->> 'stop_id')::uuid
                     and scheduled_store_name = '로에 성수'
                     and scheduled_store_address_local = '서울특별시 성동구 연무장길 12'
                     and scheduled_store_source_url = 'https://example.com/loe'
                   from app.shopping_items where id = :'item_id'),
  '商品保留選定店名、韓文地址及來源');
select tests.ok((select fixed and start_time = '18:00' from app.stops where id = :'fixed_stop'),
  '安排購買不改固定行程');
select tests.ok((app.schedule_shopping_store(:'item_id', 0, 'https://example.com/loe', :'second_day', 0,
  '20000000-0000-0000-0000-000000000002') ->> 'status') = 'already_scheduled',
  '重送不建立第二筆購買站');

select tests.login(:'viewer');
select tests.throws(format($$select app.schedule_shopping_store(%L, 0, 'https://example.com/loe', %L, 2, %L)$$,
  :'item_id', :'first_day', '20000000-0000-0000-0000-000000000003'),
  'PT403', '只有檢視權限不能安排購買');
select tests.login(:'owner');

select id as item2 from app.add_shopping_item(:'trip_id', '餅乾') \gset
select app.set_shopping_store_suggestions(:'item2',
  '[{"name":"Milk Shop","search_query":"Milk Shop","reason":"店面頁","source_url":"https://example.com/milk"}]'::jsonb);
select tests.throws(format($$select app.schedule_shopping_store(%L, 0, 'https://example.com/wrong', %L, 2, %L)$$,
  :'item2', :'first_day', '20000000-0000-0000-0000-000000000004'),
  'PT409', '候選來源不同時不得排入');
select tests.throws(format($$select app.schedule_shopping_store(%L, 0, 'https://example.com/milk', %L, 0, %L)$$,
  :'item2', :'first_day', '20000000-0000-0000-0000-000000000005'),
  'PT409', '當天版本過期時不得排入');
select tests.ok((select planned_stop_id is null from app.shopping_items where id = :'item2'),
  '失敗的安排不更改商品');

select app.commit_itinerary(:'first_day', 2,
  format('[{"id":%s,"raw_label":"已訂餐廳","start_time":"18:00","fixed":true}]',
    to_json(:'fixed_stop'::text))::jsonb);
select tests.ok((select planned_stop_id is null and scheduled_store_name is null
                     and scheduled_store_address_local is null
                   from app.shopping_items where id = :'item_id'),
  '移除購買站後可重新選店安排');
