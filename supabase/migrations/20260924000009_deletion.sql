-- Deletion (WP11, plan §3.1 刪除策略):
--   * Deleting a trip removes everything in it, including pasted import text
--     and AI conversations (D11).
--   * Deleting an account removes personal data; shared records the person
--     created stay for companions with the actor anonymised (null).
--   * Soft-deleted stops and dismissed Saved are purged after 30 days.

-- Actor columns on shared records become nullable and clear on account deletion.
do $$
declare
  r record;
begin
  for r in
    select c.conname, c.conrelid::regclass as tbl, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
     where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and c.connamespace = 'app'::regnamespace
       and (c.conrelid::regclass::text, a.attname) in (
         ('app.change_proposals', 'created_by'), ('app.change_proposals', 'decided_by'),
         ('app.invites', 'created_by'), ('app.merchant_candidates', 'added_by'),
         ('app.purchase_events', 'actor_id'), ('app.saved_places', 'added_by'),
         ('app.shopping_items', 'added_by'), ('app.source_references', 'created_by'),
         ('app.stops', 'added_by'))
  loop
    execute format('alter table %s alter column %I drop not null', r.tbl, r.col);
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
    execute format('alter table %s add constraint %I foreign key (%I) references auth.users (id) on delete set null',
                   r.tbl, r.conname, r.col);
  end loop;
end;
$$;

-- Purging a tombstoned stop must not be blocked by the proposal that created it.
alter table app.change_proposals drop constraint change_proposals_result_stop_id_fkey;
alter table app.change_proposals add constraint change_proposals_result_stop_id_fkey
  foreign key (result_stop_id) references app.stops (id) on delete set null;

-- Owner deletes a whole trip.
create function app.delete_trip(p_trip_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform app.require_role(p_trip_id, array['owner']::app.trip_role[]);
  -- import_sessions keep a nullable link; delete the pasted text explicitly.
  delete from app.import_sessions where trip_id = p_trip_id;
  delete from app.trips where id = p_trip_id;
end;
$$;

-- Runs before auth.admin.deleteUser (delete-account Edge Function, service role).
-- Owned trips go to the longest-standing editor (or viewer); trips with no
-- other member are deleted. Change events lose the actor id.
create function app.prepare_account_deletion(p_user_id uuid) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  t record;
  heir uuid;
  transferred int := 0;
  deleted int := 0;
begin
  for t in select id from app.trips where owner_id = p_user_id loop
    select user_id into heir from app.trip_members
     where trip_id = t.id and user_id <> p_user_id and status = 'active'
     order by (role = 'editor') desc, joined_at
     limit 1;
    if heir is null then
      delete from app.import_sessions where trip_id = t.id;
      delete from app.trips where id = t.id;
      deleted := deleted + 1;
    else
      update app.trip_members set role = 'owner' where trip_id = t.id and user_id = heir;
      update app.trips set owner_id = heir, updated_at = now() where id = t.id;
      perform app.bump_trip(t.id, 'member.changed', heir);
      transferred := transferred + 1;
    end if;
  end loop;
  update app.trip_events set actor_id = null where actor_id = p_user_id;
  delete from app.import_sessions where created_by = p_user_id;
  return jsonb_build_object('transferred', transferred, 'deleted', deleted);
end;
$$;

-- Tombstones older than 30 days (plan §3.1). Scheduled daily when pg_cron exists.
create function app.purge_tombstones() returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  stops_purged int;
  saved_purged int;
begin
  delete from app.stops where deleted_at < now() - interval '30 days';
  get diagnostics stops_purged = row_count;
  delete from app.saved_places where status = 'dismissed' and updated_at < now() - interval '30 days';
  get diagnostics saved_purged = row_count;
  return jsonb_build_object('stops', stops_purged, 'saved', saved_purged);
end;
$$;

revoke execute on function app.delete_trip(uuid), app.prepare_account_deletion(uuid), app.purge_tombstones()
from public, anon, authenticated;
grant execute on function app.delete_trip(uuid) to authenticated;
grant execute on function app.prepare_account_deletion(uuid), app.purge_tombstones() to service_role;

do $$
begin
  -- pg_cron must be preloaded (it is on Supabase); plain test databases skip scheduling.
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and current_setting('shared_preload_libraries', true) like '%pg_cron%' then
    create extension if not exists pg_cron;
    perform cron.schedule('beartravel-purge-tombstones', '17 3 * * *', 'select app.purge_tombstones()');
  end if;
end;
$$;
