-- Change proposals: confirm inserts at the proposed position, any day change
-- stales open proposals, stale confirm writes nothing, viewers cannot act.

\set owner  '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set viewer '00000000-0000-0000-0000-00000000000c'

set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('Seoul', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select id as day_id from app.trip_days where trip_id = :'trip_id' \gset
select app.create_invite(:'trip_id', 'editor') as etoken \gset
select app.create_invite(:'trip_id', 'viewer') as vtoken \gset
select tests.login(:'editor');
select app.accept_invite(:'etoken');
select tests.login(:'viewer');
select app.accept_invite(:'vtoken');

select tests.login(:'owner');
select (app.upsert_place('apple_mapkit', 'a', 'A', 37.56, 126.98)).id as pa \gset
select (app.upsert_place('apple_mapkit', 'b', 'B', 37.57, 126.99)).id as pb \gset
select (app.upsert_place('apple_mapkit', 'c', 'C', 37.58, 127.00)).id as pc \gset
select app.commit_itinerary(:'day_id', 0, format('[{"place_id": %s, "raw_label": "A"}, {"raw_label": "pending"}, {"place_id": %s, "raw_label": "B"}]',
       to_json(:'pa'::text), to_json(:'pb'::text))::jsonb);
select id as stop_b from app.stops where day_id = :'day_id' and raw_label = 'B' \gset

-- Validation and permissions.
select tests.throws(format($$select app.create_proposal(%L, 1, '{"raw_label": "no place"}')$$, :'day_id'),
                    'PT422', 'proposal without confirmed place rejected');
select tests.throws(format($$select app.create_proposal(%L, 0, '{"place_id": %s, "raw_label": "C"}')$$, :'day_id', to_json(:'pc'::text)),
                    'PT409', 'proposal on stale revision rejected');
select tests.login(:'viewer');
select tests.throws(format($$select app.create_proposal(%L, 1, '{"place_id": %s, "raw_label": "C"}')$$, :'day_id', to_json(:'pc'::text)),
                    'PT403', 'viewer cannot propose');

-- Owner and editor both propose against revision 1.
select tests.login(:'owner');
select id as p1 from app.create_proposal(:'day_id', 1,
  format('{"place_id": %s, "raw_label": "C", "before_stop_id": %s, "dwell_minutes": 45}', to_json(:'pc'::text), to_json(:'stop_b'::text))::jsonb,
  '{"added_travel_minutes": 7, "added_dwell_minutes": 45}') \gset
select tests.login(:'editor');
select id as p2 from app.create_proposal(:'day_id', 1,
  format('{"place_id": %s, "raw_label": "C again"}', to_json(:'pc'::text))::jsonb) \gset
select tests.ok((select count(*) from app.stops where day_id = :'day_id' and deleted_at is null) = 3,
                'proposing writes no stop');

select tests.login(:'viewer');
select tests.throws(format($$select app.confirm_proposal(%L)$$, :'p1'), 'PT403', 'viewer cannot confirm');

-- Owner confirms first: C is inserted before B, day moves to revision 2.
select tests.login(:'owner');
select tests.ok((app.confirm_proposal(:'p1')) ->> 'status' = 'confirmed', 'first confirm succeeds');
select tests.ok((select string_agg(raw_label, ',' order by sort_order) from app.stops where day_id = :'day_id' and deleted_at is null)
                = 'A,pending,C,B', 'inserted before the chosen stop');
select tests.ok((select route_revision from app.trip_days where id = :'day_id') = 2, 'revision bumped');
select tests.ok((select status = 'confirmed' and result_route_revision = 2 from app.change_proposals where id = :'p1'),
                'proposal marked confirmed');
select tests.ok((select status = 'stale' from app.change_proposals where id = :'p2'), 'other open proposal marked stale');

-- Editor's confirm of the stale proposal writes nothing.
select tests.login(:'editor');
select tests.ok((app.confirm_proposal(:'p2')) = '{"status": "stale", "route_revision": 2}'::jsonb, 'stale confirm reports current revision');
select tests.ok((select count(*) from app.stops where day_id = :'day_id' and deleted_at is null) = 4, 'stale confirm wrote nothing');

-- Editor recomputes and proposes again at revision 2, then confirms (appended at the end).
select id as p3 from app.create_proposal(:'day_id', 2, format('{"place_id": %s, "raw_label": "C again"}', to_json(:'pc'::text))::jsonb) \gset
select tests.ok((app.confirm_proposal(:'p3')) ->> 'status' = 'confirmed', 're-proposed confirm succeeds');
select tests.ok((select raw_label from app.stops where day_id = :'day_id' and deleted_at is null order by sort_order desc limit 1) = 'C again',
                'no anchor appends at the end');

-- Editing the day through commit_itinerary also stales open proposals.
select id as p4 from app.create_proposal(:'day_id', 3, format('{"place_id": %s, "raw_label": "late"}', to_json(:'pa'::text))::jsonb) \gset
select app.commit_itinerary(:'day_id', 3, '[{"raw_label": "only this"}]');
select tests.ok((select status = 'stale' from app.change_proposals where id = :'p4'), 'commit_itinerary stales proposals');

-- Closed proposals cannot be confirmed again; reject works on open/stale ones.
select tests.throws(format($$select app.confirm_proposal(%L)$$, :'p3'), 'PT409', 'confirmed proposal cannot be confirmed again');
select app.reject_proposal(:'p4');
select tests.ok((select status = 'rejected' from app.change_proposals where id = :'p4'), 'stale proposal can be dismissed');

-- AI-suggested proposals are marked and still need confirmation.
select tests.login(:'owner');
select id as pai from app.create_proposal(:'day_id', (select route_revision from app.trip_days where id = :'day_id'),
  format('{"place_id": %s, "raw_label": "AI 建議"}', to_json(:'pa'::text))::jsonb, null, true) \gset
select tests.ok((select created_by_ai and status = 'proposed' from app.change_proposals where id = :'pai'), 'AI proposal recorded, not applied');
select tests.ok((select count(*) from app.stops where raw_label = 'AI 建議') = 0, 'AI proposal wrote no stop');
