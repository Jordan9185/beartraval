-- Permission matrix (plan §3.3) and invite rules, exercised by calling the API
-- directly as each user, bypassing any UI. Covers AC-12.

\set owner    '00000000-0000-0000-0000-00000000000a'
\set editor   '00000000-0000-0000-0000-00000000000b'
\set viewer   '00000000-0000-0000-0000-00000000000c'
\set outsider '00000000-0000-0000-0000-00000000000d'
\set amy      '00000000-0000-0000-0000-00000000000e'

-- Unauthenticated callers are rejected.
set role authenticated;
select tests.logout();
select tests.throws($$select app.create_trip('x', '2026-10-01', '2026-10-02', 'Asia/Seoul')$$,
                    'PT401', 'no JWT cannot create a trip');

-- Owner creates a trip; days are generated.
select tests.login(:'owner');
select id as trip_id from app.create_trip('Seoul', '2026-10-01', '2026-10-03', 'Asia/Seoul') \gset
select tests.ok((select count(*) from app.trip_days where trip_id = :'trip_id') = 3, 'three days created');
select tests.ok(app.trip_role_of(:'trip_id') = 'owner', 'creator is owner');
select id as day_id from app.trip_days where trip_id = :'trip_id' and display_order = 0 \gset

select tests.throws($$select app.create_trip('x', '2026-10-02', '2026-10-01', 'Asia/Seoul')$$,
                    'PT422', 'end before start rejected');
select tests.throws($$select app.create_trip('x', '2026-10-01', '2026-10-02', 'Mars/Base')$$,
                    'PT422', 'unknown time zone rejected');

-- Owner issues invites.
select app.create_invite(:'trip_id', 'editor') as editor_token \gset
select app.create_invite(:'trip_id', 'viewer') as viewer_token \gset
select app.create_invite(:'trip_id', 'editor') as amy_token \gset
select tests.throws(format($$select app.create_invite(%L, 'owner')$$, :'trip_id'),
                    'PT422', 'owner role cannot be invited');

-- Outsider: sees nothing, can do nothing.
select tests.login(:'outsider');
select tests.ok((select count(*) from app.trips) = 0, 'outsider cannot read trip');
select tests.ok((select count(*) from app.trip_days) = 0, 'outsider cannot read days');
select tests.throws(format($$select app.commit_itinerary(%L, 0, '[]')$$, :'day_id'),
                    'PT403', 'outsider cannot commit itinerary');
select tests.throws(format($$select * from app.get_trip_changes(%L, 0)$$, :'trip_id'),
                    'PT403', 'outsider cannot read change feed');

-- Invite tokens: a bogus token and a guessed trip id grant nothing.
select tests.throws($$select app.accept_invite('not-a-real-token')$$, 'PT404', 'bogus token rejected');
select tests.throws(format($$select app.accept_invite(%L)$$, :'trip_id'), 'PT404', 'trip id is not a token');

-- Members join.
select tests.login(:'editor');
select tests.ok(app.accept_invite(:'editor_token') = :'trip_id'::uuid, 'editor joins');
select tests.login(:'viewer');
select tests.ok(app.accept_invite(:'viewer_token') = :'trip_id'::uuid, 'viewer joins');
select tests.ok(app.trip_role_of(:'trip_id') = 'viewer', 'viewer has viewer role');

-- Viewer: reads, but every write is refused by the server.
select tests.ok((select count(*) from app.trips where id = :'trip_id') = 1, 'viewer reads trip');
select tests.ok((select count(*) from app.trip_members where trip_id = :'trip_id') = 3, 'viewer reads members');
select tests.throws(format($$select app.commit_itinerary(%L, 0, '[{"raw_label":"Cafe"}]')$$, :'day_id'),
                    'PT403', 'viewer cannot commit itinerary');
select tests.throws(format($$select app.create_invite(%L, 'viewer')$$, :'trip_id'),
                    'PT403', 'viewer cannot invite');
select tests.throws(format($$insert into app.stops (trip_id, day_id, raw_label, resolution_status, sort_order, added_by)
                             values (%L, %L, 'x', 'pending_text', 0, %L)$$, :'trip_id', :'day_id', :'viewer'),
                    '42501', 'viewer cannot insert stops directly');
select tests.throws(format($$update app.trips set name = 'hacked' where id = %L$$, :'trip_id'),
                    '42501', 'viewer cannot update trip directly');
select tests.throws($$select app.bump_trip(gen_random_uuid(), 'x', null)$$,
                    '42501', 'internal helpers are not callable');

-- Editor: edits the itinerary, cannot manage members.
select tests.login(:'editor');
select tests.ok(app.commit_itinerary(:'day_id', 0, '[{"raw_label":"Breakfast"}]') = 1, 'editor commits itinerary');
select tests.throws(format($$select app.create_invite(%L, 'viewer')$$, :'trip_id'),
                    'PT403', 'editor cannot invite (D5)');
select tests.throws(format($$select app.remove_member(%L, %L)$$, :'trip_id', :'viewer'),
                    'PT403', 'editor cannot remove members');
select tests.throws(format($$delete from app.trips where id = %L$$, :'trip_id'),
                    '42501', 'editor cannot delete trip directly');

-- Invites: expiry, revocation, max uses.
select tests.login(:'owner');
select app.create_invite(:'trip_id', 'viewer', interval '-1 second') as expired_token \gset
select app.create_invite(:'trip_id', 'viewer', interval '1 day', 1) as single_use_token \gset
select app.create_invite(:'trip_id', 'viewer') as revoked_token \gset
select id as revoked_invite_id from app.invites
 where token_hash = encode(sha256(convert_to(:'revoked_token', 'UTF8')), 'hex') \gset
select app.revoke_invite(:'revoked_invite_id');
select tests.ok((select count(*) from app.invites where token_hash = :'revoked_token') = 0,
                'plaintext token is not stored');

select tests.login(:'outsider');
select tests.throws(format($$select app.accept_invite(%L)$$, :'expired_token'), 'PT410', 'expired invite rejected');
select tests.throws(format($$select app.accept_invite(%L)$$, :'revoked_token'), 'PT410', 'revoked invite rejected');
select app.accept_invite(:'single_use_token');
select tests.login(:'amy');
select tests.throws(format($$select app.accept_invite(%L)$$, :'single_use_token'), 'PT410', 'used-up invite rejected');
select app.accept_invite(:'amy_token');

-- Owner manages roles and membership.
select tests.login(:'owner');
select app.set_member_role(:'trip_id', :'amy', 'viewer');
select tests.throws(format($$select app.set_member_role(%L, %L, 'viewer')$$, :'trip_id', :'owner'),
                    'PT422', 'owner cannot demote self');
select app.remove_member(:'trip_id', :'viewer');

select tests.login(:'amy');
select tests.throws(format($$select app.commit_itinerary(%L, 1, '[]')$$, :'day_id'),
                    'PT403', 'demoted member cannot commit');

select tests.login(:'viewer');
select tests.ok((select count(*) from app.trips) = 0, 'removed member loses access');
select tests.throws(format($$select * from app.get_trip_changes(%L, 0)$$, :'trip_id'),
                    'PT403', 'removed member cannot read change feed');

reset role;
