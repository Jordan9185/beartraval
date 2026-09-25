-- Deletion: trip delete removes pasted text and AI history; account deletion
-- keeps shared records for companions with the actor cleared; tombstone purge.

\set owner  '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set viewer '00000000-0000-0000-0000-00000000000c'
\set amy    '00000000-0000-0000-0000-00000000000e'

set role authenticated;
select tests.login(:'owner');
select id as shared_trip from app.create_trip('Shared', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select id as solo_trip from app.create_trip('Solo', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select app.create_invite(:'shared_trip', 'editor') as token \gset
select app.save_place(:'shared_trip', 'Owner cafe', 'cafe');
select id as import_id from app.create_import('Imported', '2026-10-01', '2026-10-01', 'Asia/Seoul', 'secret pasted text') \gset
select id as imported_trip from app.commit_import(:'import_id', '[]') \gset
select id as heir_trip from app.create_trip('Heir', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select app.create_invite(:'heir_trip', 'viewer') as heir_vtoken \gset
select app.create_invite(:'heir_trip', 'editor') as heir_etoken \gset
select tests.login(:'editor');
select app.accept_invite(:'token');
select tests.login(:'amy');
select app.accept_invite(:'heir_vtoken');
select tests.login(:'viewer');
select app.accept_invite(:'heir_etoken');
reset role;
-- Amy (viewer) joined long before the editor.
update app.trip_members set joined_at = now() - interval '1 day' where trip_id = :'heir_trip' and user_id = :'amy';
set role authenticated;

-- Only the owner deletes a trip.
select tests.login(:'editor');
select tests.throws(format($$select app.delete_trip(%L)$$, :'shared_trip'), 'PT403', 'editor cannot delete trip');
select tests.login(:'owner');
select app.delete_trip(:'imported_trip');
reset role;
select tests.ok((select count(*) from app.import_sessions where id = :'import_id') = 0, 'trip deletion removes pasted text');
insert into app.ai_messages (trip_id, user_id, question, status) values (:'solo_trip', :'owner', 'q', 'failed');

-- Account deletion: shared trips go to another member, the solo trip is deleted.
set role service_role;
select app.prepare_account_deletion(:'owner') as prep \gset
reset role;
select tests.ok((:'prep'::jsonb ->> 'transferred')::int = 2 and (:'prep'::jsonb ->> 'deleted')::int = 1, 'two transferred, one deleted');
select tests.ok((select owner_id = :'viewer' from app.trips where id = :'heir_trip'), 'an editor inherits before a longer-standing viewer');
-- The departing user leaves every trip now, so a failed auth deletion can't leave two owners.
select tests.ok((select count(*) from app.trip_members where user_id = :'owner') = 0, 'departing user is no longer a member');
select tests.ok((select count(*) from app.trip_members where trip_id = :'shared_trip' and role = 'owner' and status = 'active') = 1,
                'shared trip has exactly one owner');
set role authenticated;
select tests.login(:'owner');
select tests.throws(format($$select app.set_member_role(%L, %L, 'viewer')$$, :'shared_trip', :'editor'), 'PT403',
                    'departing user can no longer act as owner');
reset role;
set role service_role;
select app.prepare_account_deletion(:'owner') as prep_again \gset
reset role;
select tests.ok((:'prep_again'::jsonb ->> 'transferred')::int = 0 and (:'prep_again'::jsonb ->> 'deleted')::int = 0,
                'running it again changes nothing');
delete from auth.users where id = :'owner';
select tests.ok((select owner_id = :'editor' from app.trips where id = :'shared_trip'), 'editor now owns the shared trip');
select tests.ok((select role = 'owner' from app.trip_members where trip_id = :'shared_trip' and user_id = :'editor'), 'editor promoted');
select tests.ok((select count(*) from app.trips where id = :'solo_trip') = 0, 'solo trip deleted');
select tests.ok((select count(*) from app.ai_messages where trip_id = :'solo_trip') = 0, 'AI history deleted with trip');
select tests.ok((select added_by is null from app.saved_places where trip_id = :'shared_trip'), 'shared record kept, actor anonymised');
select tests.ok((select count(*) from app.profiles where user_id = :'owner') = 0, 'profile removed');
select tests.ok((select count(*) from app.trip_events where actor_id = :'owner') = 0, 'events anonymised');

-- A member who owns nothing just leaves; the trip stays.
set role service_role;
select app.prepare_account_deletion(:'amy') as prep_amy \gset
reset role;
select tests.ok((:'prep_amy'::jsonb ->> 'transferred')::int = 0 and (:'prep_amy'::jsonb ->> 'deleted')::int = 0
                and (select count(*) from app.trip_members where user_id = :'amy') = 0
                and (select count(*) from app.trips where id = :'heir_trip') = 1, 'member-only account leaves, trip stays');

-- Tombstones older than 30 days are purged.
select id as day_id from app.trip_days where trip_id = :'shared_trip' \gset
set role authenticated;
select tests.login(:'editor');
select app.commit_itinerary(:'day_id', 0, '[{"raw_label": "old"}]');
select app.commit_itinerary(:'day_id', 1, '[{"raw_label": "recent"}]');
select app.commit_itinerary(:'day_id', 2, '[]');
select app.dismiss_saved(id) from app.saved_places where trip_id = :'shared_trip';
select ((app.save_place(:'shared_trip', 'Recently dismissed', 'cafe')) ->> 'id') as recent_saved \gset
select app.dismiss_saved(:'recent_saved');
reset role;
update app.stops set deleted_at = now() - interval '31 days' where day_id = :'day_id' and raw_label = 'old';
update app.saved_places set updated_at = now() - interval '31 days' where trip_id = :'shared_trip' and raw_label = 'Owner cafe';
set role service_role;
select app.purge_tombstones() as purged \gset
reset role;
select tests.ok((:'purged'::jsonb ->> 'stops')::int = 1 and (:'purged'::jsonb ->> 'saved')::int = 1, 'old tombstones purged');
select tests.ok((select count(*) from app.stops where day_id = :'day_id' and raw_label = 'recent') = 1
                and (select count(*) from app.saved_places where id = :'recent_saved') = 1, 'recent tombstones kept');
