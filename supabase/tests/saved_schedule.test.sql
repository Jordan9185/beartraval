-- 收藏從地址線索排到某天；待定位項不能混入路線，重送與過期修改不能重複或覆蓋。
\set owner '00000000-0000-0000-0000-00000000000a'
\set viewer '00000000-0000-0000-0000-00000000000c'

set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('首爾', '2026-10-01', '2026-10-02', 'Asia/Seoul') \gset
select id as first_day from app.trip_days where trip_id = :'trip_id' and display_order = 0 \gset
select id as second_day from app.trip_days where trip_id = :'trip_id' and display_order = 1 \gset
select ((app.save_place(:'trip_id', '無垢屋人參雞', 'eat')) ->> 'id') as saved_id \gset
select app.set_saved_address_hint(:'saved_id', '서울특별시 성동구 연무장길 1', 'https://example.com/store');

select app.commit_itinerary(:'first_day', 0,
  '[{"raw_label":"已訂餐廳","start_time":"18:00","fixed":true}]');
select id as fixed_stop from app.stops where day_id = :'first_day' and fixed \gset
select (app.schedule_saved(:'saved_id', :'first_day', 1,
  '10000000-0000-0000-0000-000000000001')) as scheduled \gset
select tests.ok((:'scheduled'::jsonb ->> 'status') = 'scheduled', '收藏排到選定日期');
select tests.ok((select resolution_status = 'pending_text' and place_id is null
                   from app.stops where id = (:'scheduled'::jsonb ->> 'stop_id')::uuid),
  '只有地址線索時仍是待定位行程點');
select tests.ok((select status = 'added_to_itinerary' and planned_stop_id = (:'scheduled'::jsonb ->> 'stop_id')::uuid
                     and address_hint = '서울특별시 성동구 연무장길 1'
                   from app.saved_places where id = :'saved_id'),
  '收藏與行程點連結並保留韓文地址');
select tests.ok((select fixed and start_time = '18:00' from app.stops where id = :'fixed_stop'),
  '新增收藏不改固定行程');

select tests.ok((app.schedule_saved(:'saved_id', :'second_day', 0,
  '10000000-0000-0000-0000-000000000002') ->> 'status') = 'already_scheduled',
  '重送或換日期不能新增第二筆');
select tests.ok((select count(*) from app.stops where trip_id = :'trip_id' and deleted_at is null) = 2,
  '仍只有固定行程和一筆收藏');

select tests.login(:'viewer');
select tests.throws(format($$select app.schedule_saved(%L, %L, 2, %L)$$,
  :'saved_id', :'first_day', '10000000-0000-0000-0000-000000000003'),
  'PT403', '只有檢視權限的旅伴不能排程');

select tests.login(:'owner');
select app.commit_itinerary(:'second_day', 0, '[{"raw_label":"機場"}]');
select ((app.save_place(:'trip_id', '另一間店', 'cafe')) ->> 'id') as other_saved \gset
select tests.throws(format($$select app.schedule_saved(%L, %L, 0, %L)$$,
  :'other_saved', :'second_day', '10000000-0000-0000-0000-000000000004'),
  'PT409', '當天版本過期不寫入');
select tests.ok((select status = 'saved' and planned_stop_id is null
                   from app.saved_places where id = :'other_saved'),
  '過期請求沒有改收藏');

select (app.upsert_place('apple_mapkit', 'muguok', '무구옥', 37.54, 127.06)).id as place_id \gset
select app.commit_itinerary(:'first_day', 2,
  format('[{"id":%s,"raw_label":"已訂餐廳","start_time":"18:00","fixed":true},
           {"id":%s,"place_id":%s,"raw_label":"無垢屋人參雞"}]',
    to_json(:'fixed_stop'::text),
    to_json((:'scheduled'::jsonb ->> 'stop_id')),
    to_json(:'place_id'::text))::jsonb);
select tests.ok((select place_id = :'place_id' and status = 'added_to_itinerary'
                   from app.saved_places where id = :'saved_id'),
  '行程內確認地點後收藏也改用已確認座標');

select app.commit_itinerary(:'first_day', 3,
  format('[{"id":%s,"raw_label":"已訂餐廳","start_time":"18:00","fixed":true}]',
    to_json(:'fixed_stop'::text))::jsonb);
select tests.ok((select status = 'saved' and planned_stop_id is null
                   from app.saved_places where id = :'saved_id'),
  '移除行程點後收藏可再次排程');
select tests.ok((select fixed and start_time = '18:00' from app.stops where id = :'fixed_stop'),
  '移除收藏仍保留固定行程');

select (app.schedule_saved(:'saved_id', :'second_day', 1,
  '10000000-0000-0000-0000-000000000005')) as located_schedule \gset
select tests.ok((select resolution_status = 'resolved' and place_id = :'place_id'
                   from app.stops where id = (:'located_schedule'::jsonb ->> 'stop_id')::uuid),
  '已確認座標的收藏排程後是可計算路線的行程點');
select tests.ok((select planned_stop_id = (:'located_schedule'::jsonb ->> 'stop_id')::uuid
                   from app.saved_places where id = :'saved_id'),
  '重新排程仍只連到一個有效行程點');
