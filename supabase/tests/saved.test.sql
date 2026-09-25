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
select tests.throws(format($$select app.resolve_saved(%L, %L)$$, :'pending_id', :'onion'), 'PT409', 'resolving to an already saved place rejected');
select app.resolve_saved(:'pending_id', :'gj');
select tests.ok((select place_id = :'gj' from app.saved_places where id = :'pending_id'), 'manual fill resolves place');

-- Viewer can read but not write.
select tests.login(:'viewer');
select tests.ok((select count(*) from app.saved_places where trip_id = :'trip_id') = 2, 'viewer reads saved');
select tests.throws(format($$select app.save_place(%L, 'x')$$, :'trip_id'), 'PT403', 'viewer cannot save');
select tests.throws(format($$select app.set_saved_interest(%L, true)$$, :'saved_id'), 'PT403', 'viewer cannot mark interest');

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
