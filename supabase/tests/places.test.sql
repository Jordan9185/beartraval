-- upsert_place: validation, first-writer-wins, and use from commit_itinerary.

\set owner    '00000000-0000-0000-0000-00000000000a'
\set outsider '00000000-0000-0000-0000-00000000000d'

set role authenticated;

select tests.throws($$select app.upsert_place('apple_mapkit', 'x', 'X', 37.5, 127.0)$$,
                    'PT401', 'anonymous caller rejected');

select tests.login(:'owner');
select tests.throws($$select app.upsert_place('google', 'x', 'X', 37.5, 127.0)$$,
                    'PT422', 'unknown provider rejected');
select tests.throws($$select app.upsert_place('apple_mapkit', ' ', 'X', 37.5, 127.0)$$,
                    'PT422', 'blank provider id rejected');
select tests.throws($$select app.upsert_place('apple_mapkit', 'x', '', 37.5, 127.0)$$,
                    'PT422', 'blank name rejected');
select tests.throws($$select app.upsert_place('apple_mapkit', 'x', 'X', 91, 127.0)$$,
                    'PT422', 'latitude out of range rejected');

select (app.upsert_place('apple_mapkit', 'gwangjang', 'Gwangjang Market', 37.5700, 126.9996,
                         '광장시장', '서울특별시 종로구 창경궁로 88', 'kr')).id as place_id \gset
select tests.ok((select country_code = 'KR' and name_local = '광장시장' from app.places where id = :'place_id'),
                'place stored with normalized country code');

-- Another user registering the same provider id at the same spot gets the existing row back unchanged.
select tests.login(:'outsider');
select tests.ok((app.upsert_place('apple_mapkit', 'gwangjang', 'Renamed', 37.5702, 126.9998)).id = :'place_id',
                'same provider id returns existing place');
-- Far from the registered spot: the caller gets their own row, the existing one is untouched.
select tests.ok((app.upsert_place('apple_mapkit', 'gwangjang', 'Planted', 0, 0)).id <> :'place_id',
                'mismatched coordinates get a separate place');
reset role;
select tests.ok((select name = 'Gwangjang Market' and latitude = 37.5700 from app.places where id = :'place_id'),
                'existing place not overwritten');
set role authenticated;

-- Clients still cannot write places directly.
select tests.throws($$insert into app.places (provider, provider_place_id, name, latitude, longitude)
                      values ('apple_mapkit', 'direct', 'Direct', 0, 0)$$,
                    '42501', 'direct insert denied');

-- A registered place can be referenced by a stop.
select tests.login(:'owner');
select id as trip_id from app.create_trip('Seoul', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select id as day_id from app.trip_days where trip_id = :'trip_id' \gset
select tests.ok(app.commit_itinerary(:'day_id', 0, format('[{"place_id": %s, "raw_label": "광장시장"}]',
                to_json(:'place_id'::text))::jsonb) = 1, 'stop references upserted place');
select tests.ok((select resolution_status = 'resolved' from app.stops where day_id = :'day_id'),
                'stop with place is resolved');

-- Chinese and local names can be filled in later but never overwritten.
select tests.login(:'owner');
select app.upsert_place('apple_mapkit', 'kyoja', '明洞餃子', 37.5625, 126.9856, null, null, 'KR', '明洞餃子');
select tests.login(:'outsider');
select app.upsert_place('apple_mapkit', 'kyoja', 'Myeongdong Kyoja', 37.5626, 126.9857, '명동교자 본점', null, 'KR', '別的名字');
reset role;
select tests.ok((select name = '明洞餃子' and name_local = '명동교자 본점' and name_zh = '明洞餃子' and latitude = 37.5625
                   from app.places where provider_place_id = 'kyoja'), 'missing local name filled, others kept');

-- Once another trip uses a place, a stranger can't fill in its names.
set role authenticated;
select tests.login(:'owner');
select (app.upsert_place('apple_mapkit', 'tower', 'N Seoul Tower', 37.5512, 126.9882)).id as tower_id \gset
select app.commit_itinerary(:'day_id', 1, format('[{"place_id": %s, "raw_label": "tower"}]', to_json(:'tower_id'::text))::jsonb);
select tests.login(:'outsider');
select app.upsert_place('apple_mapkit', 'tower', 'N Seoul Tower', 37.5512, 126.9882, 'N서울타워', null, 'KR', '陌生人取的名字');
reset role;
select tests.ok((select name_zh is null and name_local is null from app.places where id = :'tower_id'),
                'stranger cannot rename a place other trips use');

-- The local-language address follows the same rules: set on insert, a missing
-- one can be filled in, an existing one is never overwritten.
set role authenticated;
select tests.login(:'owner');
select app.upsert_place('apple_mapkit', 'kyoja2', 'Myeongdong Kyoja', 37.5625, 126.9856, null, '南韓首爾特別市明洞명동10길', 'KR');
select app.upsert_place('apple_mapkit', 'kyoja2', 'Myeongdong Kyoja', 37.5625, 126.9856, null, null, 'KR', null, '서울특별시 중구 명동10길 29');
select app.upsert_place('apple_mapkit', 'kyoja2', 'Myeongdong Kyoja', 37.5625, 126.9856, null, null, 'KR', null, '다른 주소');
reset role;
select tests.ok((select address = '南韓首爾特別市明洞명동10길' and address_local = '서울특별시 중구 명동10길 29'
                   from app.places where provider_place_id = 'kyoja2'), 'local address filled once, not overwritten');

-- 資安：替代 key 不能由用戶端預先建立；被植入的遠方替代列不會回給其他人。
reset role;
set role authenticated;
select tests.login(:'owner');
select tests.throws($$select app.upsert_place('apple_mapkit', 'poi-x~abc', '假店', 37.5, 127.0)$$, 'PT422', '用戶端不能使用保留字元 ~');
select (app.upsert_place('apple_mapkit', 'poi-guard', '搶註名稱', 35.0, 129.0)).id as far_id \gset
reset role;
-- 模擬修正前已被植入、座標在遠方的替代列。
insert into app.places(provider, provider_place_id, name, latitude, longitude)
values ('apple_mapkit', 'poi-guard~' || left(md5(format('%s|%s|%s', '真店', round(37.5::numeric, 4), round(127.0::numeric, 4))), 12), '植入替代列', 10.0, 10.0);
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.upsert_place('apple_mapkit', 'poi-guard', '真店', 37.5, 127.0) as real_place \gset
select tests.ok((:'real_place'::app.places).name = '真店' and app.distance_km((:'real_place'::app.places).latitude, (:'real_place'::app.places).longitude, 37.5, 127.0) < 1,
  '遠方植入的替代列不沿用，取得座標正確的列');
