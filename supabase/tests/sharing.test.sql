-- Sharing: profiles visible only to co-members, invite preview shows no
-- itinerary content, save_place retries are idempotent.

\set owner    '00000000-0000-0000-0000-00000000000a'
\set editor   '00000000-0000-0000-0000-00000000000b'
\set outsider '00000000-0000-0000-0000-00000000000d'

set role authenticated;
select tests.login(:'owner');
select tests.ok((select display_name = 'owner' from app.profiles where user_id = :'owner'), 'default profile from email');
select app.set_display_name('Jordan');
select id as trip_id from app.create_trip('Seoul', '2026-10-01', '2026-10-03', 'Asia/Seoul') \gset
select app.commit_itinerary((select id from app.trip_days where trip_id = :'trip_id' limit 1), 0, '[{"raw_label": "secret stop"}]');
select app.create_invite(:'trip_id', 'editor') as token \gset

-- Outsider cannot see the owner's profile before joining.
select tests.login(:'outsider');
select tests.ok((select count(*) from app.profiles where user_id = :'owner') = 0, 'non-member cannot read profile');
select tests.throws(format($$select app.invite_preview(%L)$$, :'token'), '42501', 'clients cannot call invite_preview');

-- The Edge Function (service role) sees only name, dates, inviter, role.
reset role;
set role service_role;
select app.invite_preview(:'token') as preview \gset
select (app.invite_preview('nope')) ->> 'status' as bad_status \gset
reset role;
select tests.ok((:'preview'::jsonb ->> 'status') = 'valid' and (:'preview'::jsonb ->> 'trip_name') = 'Seoul'
                and (:'preview'::jsonb ->> 'inviter') = 'Jordan' and (:'preview'::jsonb ->> 'role') = 'editor', 'preview fields');
select tests.ok(position('secret stop' in :'preview') = 0, 'preview has no itinerary content');
select tests.ok(:'bad_status' = 'invalid', 'unknown token is invalid');

set role authenticated;
select tests.login(:'editor');
select app.accept_invite(:'token');
select tests.ok((select display_name = 'Jordan' from app.profiles where user_id = :'owner'), 'co-member reads profile');

-- Only the owner lists invites.
select tests.ok((select count(*) from app.invites where trip_id = :'trip_id') = 0, 'editor cannot list invites');
select tests.login(:'owner');
select tests.ok((select count(*) from app.invites where trip_id = :'trip_id') = 1, 'owner lists invites');

-- Offline retry: same client op id returns the first result, no duplicate.
select tests.login(:'editor');
select (app.save_place(:'trip_id', 'Offline cafe', 'cafe', null, null, '11111111-1111-1111-1111-111111111111')) ->> 'id' as first_id \gset
select tests.ok((app.save_place(:'trip_id', 'Offline cafe', 'cafe', null, null, '11111111-1111-1111-1111-111111111111')) ->> 'id' = :'first_id',
                'retried op returns the same entry');
select tests.ok((select count(*) from app.saved_places where trip_id = :'trip_id') = 1, 'no duplicate from retry');
