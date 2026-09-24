-- Deletion: trip delete removes pasted text and AI history; account deletion
-- keeps shared records for companions with the actor cleared; tombstone purge.

\set owner  '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set amy    '00000000-0000-0000-0000-00000000000e'

set role authenticated;
select tests.login(:'owner');
select id as shared_trip from app.create_trip('Shared', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select id as solo_trip from app.create_trip('Solo', '2026-10-01', '2026-10-01', 'Asia/Seoul') \gset
select app.create_invite(:'shared_trip', 'editor') as token \gset
select app.save_place(:'shared_trip', 'Owner cafe', 'cafe');
select id as import_id from app.create_import('Imported', '2026-10-01', '2026-10-01', 'Asia/Seoul', 'secret pasted text') \gset
select id as imported_trip from app.commit_import(:'import_id', '[]') \gset
select tests.login(:'editor');
select app.accept_invite(:'token');

-- Only the owner deletes a trip.
select tests.throws(format($$select app.delete_trip(%L)$$, :'shared_trip'), 'PT403', 'editor cannot delete trip');
select tests.login(:'owner');
select app.delete_trip(:'imported_trip');
reset role;
select tests.ok((select count(*) from app.import_sessions where id = :'import_id') = 0, 'trip deletion removes pasted text');
insert into app.ai_messages (trip_id, user_id, question, status) values (:'solo_trip', :'owner', 'q', 'failed');

-- Account deletion: shared trip goes to the editor, solo trip is deleted.
set role service_role;
select app.prepare_account_deletion(:'owner') as prep \gset
reset role;
select tests.ok((:'prep'::jsonb ->> 'transferred')::int = 1 and (:'prep'::jsonb ->> 'deleted')::int = 1, 'one transferred, one deleted');
delete from auth.users where id = :'owner';
select tests.ok((select owner_id = :'editor' from app.trips where id = :'shared_trip'), 'editor now owns the shared trip');
select tests.ok((select role = 'owner' from app.trip_members where trip_id = :'shared_trip' and user_id = :'editor'), 'editor promoted');
select tests.ok((select count(*) from app.trips where id = :'solo_trip') = 0, 'solo trip deleted');
select tests.ok((select count(*) from app.ai_messages where trip_id = :'solo_trip') = 0, 'AI history deleted with trip');
select tests.ok((select added_by is null from app.saved_places where trip_id = :'shared_trip'), 'shared record kept, actor anonymised');
select tests.ok((select count(*) from app.profiles where user_id = :'owner') = 0, 'profile removed');
select tests.ok((select count(*) from app.trip_events where actor_id = :'owner') = 0, 'events anonymised');

-- Tombstones older than 30 days are purged.
select id as day_id from app.trip_days where trip_id = :'shared_trip' \gset
set role authenticated;
select tests.login(:'editor');
select app.commit_itinerary(:'day_id', 0, '[{"raw_label": "old"}]');
select app.commit_itinerary(:'day_id', 1, '[]');
reset role;
update app.stops set deleted_at = now() - interval '31 days' where day_id = :'day_id';
set role service_role;
select app.purge_tombstones() as purged \gset
reset role;
select tests.ok((:'purged'::jsonb ->> 'stops')::int = 1, 'old tombstone purged');
