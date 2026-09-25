-- Per-day time zone and transport mode for multi-country trips.

\set owner  '00000000-0000-0000-0000-00000000000a'
\set viewer '00000000-0000-0000-0000-00000000000c'

set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('Seoul → Tokyo', '2026-10-01', '2026-10-03', 'Asia/Seoul') \gset
select id as d3 from app.trip_days where trip_id = :'trip_id' and display_order = 2 \gset
select (app.upsert_place('apple_mapkit', 'x', 'X', 35.68, 139.76)).id as px \gset
select id as pid from app.create_proposal(:'d3', 0, format('{"place_id": %s, "raw_label": "X"}', to_json(:'px'::text))::jsonb) \gset

select tests.throws(format($$select app.update_day(%L, 'Mars/Olympus')$$, :'d3'), 'PT422', 'unknown time zone rejected');
select app.update_day(:'d3', 'Asia/Tokyo', 'walking');
select tests.ok((select time_zone = 'Asia/Tokyo' and transport_mode = 'walking' and route_revision = 1
                   from app.trip_days where id = :'d3'), 'day 3 moves to Tokyo time and walking');
select tests.ok((select count(*) from app.trip_days where trip_id = :'trip_id' and time_zone = 'Asia/Seoul') = 2, 'other days unchanged');
select tests.ok((select status = 'stale' from app.change_proposals where id = :'pid'), 'open proposal for that day goes stale');

select app.update_day(:'d3', 'Asia/Tokyo');
select tests.ok((select route_revision = 1 from app.trip_days where id = :'d3'), 'no-op change does not bump revision');

select app.create_invite(:'trip_id', 'viewer') as token \gset
select tests.login(:'viewer');
select app.accept_invite(:'token');
select tests.throws(format($$select app.update_day(%L, 'Asia/Seoul')$$, :'d3'), 'PT403', 'viewer cannot change day settings');
