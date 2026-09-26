-- Saved: friends' additions never touch stops, re-shares dedupe, interests are
-- a set, confirmed itinerary places leave the Saved "to add" list.

\set owner  '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set viewer '00000000-0000-0000-0000-00000000000c'
\set amy    '00000000-0000-0000-0000-00000000000e'

set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('Seoul', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select id as day_id from app.trip_days where trip_id = :'trip_id' \gset
select app.create_invite(:'trip_id', 'editor') as etoken \gset
select app.create_invite(:'trip_id', 'viewer') as vtoken \gset
select tests.login(:'amy');
select app.accept_invite(:'etoken');
select tests.login(:'viewer');
select app.accept_invite(:'vtoken');

select tests.login(:'owner');
select (app.upsert_place('apple_mapkit', 'onion', 'Onion Seongsu', 37.5447, 127.0584)).id as onion \gset
select (app.upsert_place('apple_mapkit', 'gj', 'Gwangjang', 37.57, 126.9996)).id as gj \gset

-- Amy (editor) adds a restaurant from a share: Saved gets it, stops stay empty (AC-07).
select tests.login(:'amy');
select (app.save_place(:'trip_id', 'Onion 성수', 'cafe', :'onion',
        '{"type": "share", "url": "https://www.threads.net/@a/post/1?igsh=x", "canonical_url": "https://www.threads.net/@a/post/1", "summary": "성수 카페"}')) as r1 \gset
select tests.ok((:'r1'::jsonb ->> 'duplicate')::boolean = false, 'first save is new');
select (:'r1'::jsonb ->> 'id') as saved_id \gset
select tests.ok((select count(*) from app.stops where trip_id = :'trip_id') = 0, 'saving never creates a stop');
select tests.ok((select count(*) from app.saved_interests where saved_id = :'saved_id') = 1, 'adder is interested');

-- Owner re-shares the same post: same entry, owner's interest added.
select tests.login(:'owner');
select tests.ok((app.save_place(:'trip_id', 'Onion', 'cafe', null,
                 '{"type": "share", "url": "https://www.threads.net/@a/post/1", "canonical_url": "https://www.threads.net/@a/post/1"}')) ->> 'id' = :'saved_id',
                'same canonical URL returns existing entry');
select tests.ok((select count(*) from app.saved_interests where saved_id = :'saved_id') = 2, 're-share adds interest');
-- Saving the same confirmed place without a URL also dedupes.
select tests.ok((app.save_place(:'trip_id', 'Onion again', 'cafe', :'onion')) ->> 'duplicate' = 'true', 'same place dedupes');
select tests.ok((select count(*) from app.saved_places where trip_id = :'trip_id') = 1, 'still one saved entry');

-- Interest toggles are per member.
select app.set_saved_interest(:'saved_id', false);
select tests.ok((select count(*) from app.saved_interests where saved_id = :'saved_id') = 1, 'owner removed own interest only');

-- Unconfirmed save (AC-04): no place, can be resolved later.
select ((app.save_place(:'trip_id', 'IG 貼文裡的店（名稱不明）', 'eat', null,
        '{"type": "share", "url": "https://www.instagram.com/p/abc/", "canonical_url": "https://www.instagram.com/p/abc/"}')) ->> 'id') as pending_id \gset
select tests.ok((select place_id is null and status = 'saved' from app.saved_places where id = :'pending_id'), 'unconfirmed saved kept without place');
select app.set_saved_address_hint(:'pending_id', '서울특별시 성동구 연무장길 1', 'https://example.com/store');
select tests.ok((select address_hint = '서울특별시 성동구 연무장길 1' and address_source_url = 'https://example.com/store'
                   from app.saved_places where id = :'pending_id'), 'recognised address remains with an unlocated saved entry');
select tests.throws(format($$select app.set_saved_address_hint(%L, '서울특별시 성동구 연무장길 1', 'http://example.com')$$, :'pending_id'),
                    'PT422', 'saved address source requires https');
select tests.throws(format($$select app.resolve_saved(%L, %L)$$, :'pending_id', :'onion'), 'PT409', 'resolving to an already saved place rejected');
select app.resolve_saved(:'pending_id', :'gj');
select tests.ok((select place_id = :'gj' from app.saved_places where id = :'pending_id'), 'manual fill resolves place');
select (app.upsert_place('apple_mapkit', 'third', 'Third place', 37.55, 127.01)).id as third \gset
select tests.throws(format($$select app.resolve_saved(%L, %L)$$, :'pending_id', :'third'), 'PT409', 'a confirmed saved place is not re-pointed');

-- Viewer can read but not write.
select tests.login(:'viewer');
select tests.ok((select count(*) from app.saved_places where trip_id = :'trip_id') = 2, 'viewer reads saved');
select tests.throws(format($$select app.save_place(%L, 'x')$$, :'trip_id'), 'PT403', 'viewer cannot save');
select tests.throws(format($$select app.set_saved_interest(%L, true)$$, :'saved_id'), 'PT403', 'viewer cannot mark interest');
select tests.throws(format($$select app.resolve_saved(%L, %L)$$, :'saved_id', :'third'), 'PT403', 'viewer cannot resolve');
select tests.throws(format($$select app.set_saved_address_hint(%L, '서울특별시 성동구 연무장길 1')$$, :'saved_id'),
                    'PT403', 'viewer cannot change recognised address');
select tests.throws(format($$select app.dismiss_saved(%L)$$, :'saved_id'), 'PT403', 'viewer cannot dismiss');

-- Adding the place to the itinerary moves the Saved entry out of the list.
select tests.login(:'owner');
select app.commit_itinerary(:'day_id', 0, format('[{"place_id": %s, "raw_label": "Onion"}]', to_json(:'onion'::text))::jsonb);
select tests.ok((select status = 'added_to_itinerary' from app.saved_places where id = :'saved_id'), 'itinerary stop marks saved as added');
select tests.ok((app.save_place(:'trip_id', 'Gwangjang dup', 'eat', :'gj')) ->> 'duplicate' = 'true', 'resolved entry dedupes by place');

select app.dismiss_saved(:'pending_id');
select tests.ok((select status = 'dismissed' from app.saved_places where id = :'pending_id'), 'dismissed');
select tests.ok((select count(*) from app.trip_events where trip_id = :'trip_id' and kind = 'saved.changed') >= 4, 'saved changes emit events');

-- Removing the stop puts the saved entry back on the "to add" list.
select app.commit_itinerary(:'day_id', 1, '[]'::jsonb);
select tests.ok((select status = 'saved' from app.saved_places where id = :'saved_id'), 'removed stop returns saved entry to the list');

-- Resolving to a place that is already a stop marks the entry as added.
select (app.upsert_place('apple_mapkit', 'bbq', 'BBQ Place', 37.56, 126.97)).id as bbq \gset
select app.commit_itinerary(:'day_id', 2, format('[{"place_id": %s, "raw_label": "BBQ"}]', to_json(:'bbq'::text))::jsonb);
select ((app.save_place(:'trip_id', '朋友說的烤肉店', 'eat')) ->> 'id') as bbq_saved \gset
select app.resolve_saved(:'bbq_saved', :'bbq');
select tests.ok((select status = 'added_to_itinerary' from app.saved_places where id = :'bbq_saved'),
                'resolving to a place on the itinerary marks the entry added');

-- A located re-share of a URL that was first saved without a place confirms that entry.
select ((app.save_place(:'trip_id', 'Threads 上的麵店', 'eat', null,
        '{"type": "share", "url": "https://www.threads.net/@b/post/2", "canonical_url": "https://www.threads.net/@b/post/2"}')) ->> 'id') as unlocated \gset
select (app.upsert_place('apple_mapkit', 'noodle', 'Noodle House', 37.565, 126.98)).id as noodle \gset
select app.save_place(:'trip_id', 'Noodle House', 'eat', :'noodle',
       '{"type": "share", "url": "https://www.threads.net/@b/post/2?igsh=y", "canonical_url": "https://www.threads.net/@b/post/2"}') as relocated \gset
select tests.ok((:'relocated'::jsonb ->> 'id') = :'unlocated' and (:'relocated'::jsonb ->> 'duplicate')::boolean
                and (select place_id = :'noodle' and status = 'saved' from app.saved_places where id = :'unlocated'),
                'located re-share confirms the place on the earlier entry');
select tests.ok((select count(*) from app.saved_places where trip_id = :'trip_id' and place_id = :'noodle') = 1, 'no second entry for the place');
