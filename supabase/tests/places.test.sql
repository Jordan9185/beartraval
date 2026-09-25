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

-- Another user registering the same provider id gets the existing row back unchanged.
select tests.login(:'outsider');
select tests.ok((app.upsert_place('apple_mapkit', 'gwangjang', 'Renamed', 0, 0)).id = :'place_id',
                'same provider id returns existing place');
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
select app.upsert_place('apple_mapkit', 'kyoja', 'Myeongdong Kyoja', 0, 0, '명동교자 본점', null, 'KR', '別的名字');
reset role;
select tests.ok((select name = '明洞餃子' and name_local = '명동교자 본점' and name_zh = '明洞餃子' and latitude = 37.5625
                   from app.places where provider_place_id = 'kyoja'), 'missing local name filled, others kept');
