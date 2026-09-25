-- Itinerary commits: revision checks (AC-13), stop replacement, unresolved stops,
-- and the change feed used to converge after reconnecting.

\set owner  '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'

set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('Seoul', '2026-10-01', '2026-10-02', 'Asia/Seoul') \gset
select id as day_id from app.trip_days where trip_id = :'trip_id' and display_order = 0 \gset
select app.create_invite(:'trip_id', 'editor') as token \gset
select tests.login(:'editor');
select app.accept_invite(:'token');

reset role;
select id as shoes_myeongdong from app.places where provider_place_id = 'seoul-myeongdong-shoes' \gset
select id as hotel from app.places where provider_place_id = 'seoul-hotel' \gset
set role authenticated;

-- Both editors load route_revision 0. The owner commits first.
select tests.login(:'owner');
select tests.ok(app.commit_itinerary(:'day_id', 0, format($$[
  {"place_id": %s, "raw_label": "Hotel", "fixed": true, "start_time": "09:00"},
  {"raw_label": "XXX Shoes (branch unknown)"},
  {"place_id": %s, "raw_label": "XXX Shoes Myeongdong", "dwell_minutes": 30}
]$$, to_json(:'hotel'::text), to_json(:'shoes_myeongdong'::text))::jsonb) = 1, 'first commit -> revision 1');

select tests.ok((select count(*) from app.stops where day_id = :'day_id' and deleted_at is null) = 3, 'three stops');
select tests.ok((select resolution_status = 'pending_text' and place_id is null
                   from app.stops where day_id = :'day_id' and sort_order = 1),
                'stop without place stays pending_text');
select tests.ok((select fixed from app.stops where day_id = :'day_id' and sort_order = 0), 'fixed flag stored');

-- The editor still holds revision 0: the commit is refused and writes nothing.
select tests.login(:'editor');
select tests.throws(format($$select app.commit_itinerary(%L, 0, '[{"raw_label":"Cafe"}]')$$, :'day_id'),
                    'PT409', 'stale revision rejected');
select tests.ok((select count(*) from app.stops where day_id = :'day_id' and deleted_at is null) = 3,
                'stale commit wrote nothing');
select tests.ok((select route_revision from app.trip_days where id = :'day_id') = 1, 'revision unchanged');

-- After refetching, the editor retries against revision 1: drop the unknown branch,
-- keep the others (by id), append a cafe.
select id as hotel_stop from app.stops where day_id = :'day_id' and sort_order = 0 \gset
select id as shoes_stop from app.stops where day_id = :'day_id' and sort_order = 2 \gset
select tests.ok(app.commit_itinerary(:'day_id', 1, format($$[
  {"id": %s, "place_id": %s, "raw_label": "Hotel", "fixed": true, "start_time": "09:00"},
  {"id": %s, "place_id": %s, "raw_label": "XXX Shoes Myeongdong", "dwell_minutes": 30},
  {"raw_label": "Cafe Onion"}
]$$, to_json(:'hotel_stop'::text), to_json(:'hotel'::text),
     to_json(:'shoes_stop'::text), to_json(:'shoes_myeongdong'::text))::jsonb) = 2, 'retry -> revision 2');

select tests.ok((select array_agg(raw_label order by sort_order) from app.stops
                  where day_id = :'day_id' and deleted_at is null)
                = array['Hotel', 'XXX Shoes Myeongdong', 'Cafe Onion'], 'new order applied');
select tests.ok((select count(*) from app.stops where day_id = :'day_id' and deleted_at is not null) = 1,
                'removed stop is soft-deleted');
select tests.ok((select added_by from app.stops where id = :'hotel_stop') = :'owner'::uuid,
                'kept stop keeps original author');

-- Validation.
select tests.throws(format($$select app.commit_itinerary(%L, 2, '[{"place_id":"%s","raw_label":"x"}]')$$,
                           :'day_id', gen_random_uuid()),
                    'PT422', 'unknown place rejected');
select tests.throws(format($$select app.commit_itinerary(%L, 2, '[{"id":"%s","raw_label":"x"}]')$$,
                           :'day_id', gen_random_uuid()),
                    'PT422', 'stop id from elsewhere rejected');
select tests.throws(format($$select app.commit_itinerary(%L, 2, '{}')$$, :'day_id'),
                    'PT422', 'non-array payload rejected');
select tests.throws(format($$select app.commit_itinerary(%L, 2, '[{"raw_label":"  "}]')$$, :'day_id'),
                    '23514', 'blank label rejected');
select tests.throws($$select app.commit_itinerary(gen_random_uuid(), 0, '[]')$$, 'PT404', 'unknown day');

-- Change feed: a client that last saw revision R gets exactly the later events.
select tests.ok((select array_agg(kind order by revision) from app.get_trip_changes(:'trip_id', 0))
                = array['member.changed', 'day.itinerary_changed', 'day.itinerary_changed'],
                'feed lists all changes in order');
select revision as trip_rev from app.trips where id = :'trip_id' \gset
select tests.ok((select count(*) from app.get_trip_changes(:'trip_id', :trip_rev)) = 0,
                'nothing newer than current revision');
select tests.ok((select count(*) from app.get_trip_changes(:'trip_id', :trip_rev - 1)) = 1,
                'catch-up returns only missed events');

reset role;

-- NULL revision or stops are rejected, not treated as "skip the check" or "delete everything".
select tests.login(:'owner');
select id as null_day from app.trip_days where trip_id = :'trip_id' order by display_order limit 1 \gset
select tests.throws(format($$select app.commit_itinerary(%L, null, '[]')$$, :'null_day'), 'PT422', 'null revision rejected');
select tests.throws(format($$select app.commit_itinerary(%L, 0, null)$$, :'null_day'), 'PT422', 'null stops rejected');

