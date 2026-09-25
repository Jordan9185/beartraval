-- Import pipeline: raw text kept, edits reset the draft, owner-only access,
-- parse results only via service role, and commit_import creates everything
-- atomically.

\set owner    '00000000-0000-0000-0000-00000000000a'
\set outsider '00000000-0000-0000-0000-00000000000d'

set role authenticated;
select tests.login(:'owner');

select tests.throws($$select app.create_import('Seoul', '2026-10-01', '2026-10-02', 'Asia/Seoul', '   ')$$,
                    'PT422', 'empty text rejected');
select tests.throws($$select app.create_import('Seoul', '2026-10-02', '2026-10-01', 'Asia/Seoul', 'x')$$,
                    'PT422', 'reversed dates rejected');

select id as import_id from app.create_import('Seoul', '2026-10-01', '2026-10-02', 'Asia/Seoul',
  'Day 1 광장시장, XXX Shoes') \gset
select tests.ok((select parse_status = 'pending' and raw_text like 'Day 1%' from app.import_sessions where id = :'import_id'),
                'import stored with raw text');

-- Clients cannot write parse results.
select tests.throws(format($$select app.record_parse_result(%L, 'parsed', '{}', null, 'x')$$, :'import_id'),
                    '42501', 'client cannot record parse result');
select tests.throws(format($$update app.import_sessions set parse_status = 'parsed' where id = %L$$, :'import_id'),
                    '42501', 'direct update denied');

select tests.throws(format($$select app.record_parse_progress(%L, '{"stage":"writing"}')$$, :'import_id'),
                    '42501', 'client cannot record parse progress');

reset role;
set role service_role;
-- Progress is only kept while parsing.
select app.record_parse_progress(:'import_id', '{"stage":"writing","stops":1}');
reset role;
select tests.ok((select parse_progress is null from app.import_sessions where id = :'import_id'), 'progress ignored unless parsing');
set role service_role;
select app.record_parse_result(:'import_id', 'parsing', null, null, null);
select app.record_parse_progress(:'import_id', '{"stage":"writing","days":1,"stops":2,"last_place":"광장시장"}');
reset role;
select tests.ok((select parse_progress ->> 'last_place' = '광장시장' from app.import_sessions where id = :'import_id'),
                'progress recorded while parsing');
set role service_role;
select app.record_parse_result(:'import_id', 'failed', null, 'invalid_output', 'claude-opus-5');
reset role;
set role authenticated;
select tests.login(:'owner');
select tests.ok((select parse_status = 'failed' and raw_text like 'Day 1%' from app.import_sessions where id = :'import_id'),
                'failed parse keeps raw text');

select app.update_import_text(:'import_id', 'Day 1 광장시장 10:00, XXX Shoes 성수');
select tests.ok((select parse_status = 'pending' and parse_error is null and raw_text like '%성수'
                   from app.import_sessions where id = :'import_id'),
                'editing text resets draft and keeps new text');

-- Other users cannot see or use the import.
select tests.login(:'outsider');
select tests.ok((select count(*) from app.import_sessions where id = :'import_id') = 0, 'outsider cannot read import');
select tests.throws(format($$select app.commit_import(%L, '[]')$$, :'import_id'), 'PT404', 'outsider cannot commit');

-- Commit: one resolved stop, one pending text stop, second day empty.
select tests.login(:'owner');
select (app.upsert_place('apple_mapkit', 'gwangjang', 'Gwangjang Market', 37.57, 126.9996)).id as market \gset
select tests.throws(format($$select app.commit_import(%L, '[{"date": "2026-10-05", "stops": [{"raw_label": "x"}]}]')$$, :'import_id'),
                    'PT422', 'date outside trip rejected');
select tests.ok((select count(*) from app.trips where name = 'Seoul') = 0, 'failed commit created no trip');

select id as trip_id from app.commit_import(:'import_id', format($$[
  {"date": "2026-10-01", "stops": [
    {"place_id": %s, "raw_label": "광장시장", "start_time": "10:00"},
    {"raw_label": "XXX Shoes 성수 (분점 미정)"}
  ]},
  {"date": "2026-10-02", "stops": []}
]$$, to_json(:'market'::text))::jsonb) \gset

select tests.ok((select count(*) from app.trip_days where trip_id = :'trip_id') = 2, 'trip days created');
select tests.ok((select count(*) from app.stops where trip_id = :'trip_id') = 2, 'stops created');
select tests.ok((select resolution_status = 'pending_text' from app.stops where trip_id = :'trip_id' and sort_order = 1),
                'unselected branch stays pending text');
select tests.ok((select route_revision from app.trip_days where trip_id = :'trip_id' and local_date = '2026-10-01') = 1,
                'day with stops at revision 1');
select tests.ok((select trip_id = :'trip_id' from app.import_sessions where id = :'import_id'), 'import linked to trip');
select tests.throws(format($$select app.commit_import(%L, '[]')$$, :'import_id'), 'PT409', 'second commit rejected');
select tests.throws(format($$select app.update_import_text(%L, 'x')$$, :'import_id'), 'PT404', 'committed import cannot be edited');
