-- Sharing (WP7): member display names, invite preview for the web page, and
-- idempotent client operations for the offline queue (D6).

-- Display names shown to co-members (members list, "誰新增", invite preview).
create table app.profiles (
  user_id       uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null check (length(btrim(display_name)) between 1 and 60),
  updated_at    timestamptz not null default now()
);

alter table app.profiles enable row level security;

-- Visible to yourself and to people you share an active trip with.
create policy profiles_comember_read on app.profiles
  for select to authenticated using (
    user_id = auth.uid() or exists (
      select 1 from app.trip_members me
        join app.trip_members them on them.trip_id = me.trip_id
       where me.user_id = auth.uid() and me.status = 'active'
         and them.user_id = profiles.user_id and them.status = 'active'));

grant select on app.profiles to authenticated;
revoke insert, update, delete, truncate on app.profiles from authenticated, anon;

-- New accounts get the local part of their email as a default name.
create function app.create_default_profile() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into app.profiles (user_id, display_name)
  values (new.id, left(coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), '旅伴'), 60))
  on conflict do nothing;
  return new;
end;
$$;

create trigger auth_users_default_profile
  after insert on auth.users
  for each row execute function app.create_default_profile();

insert into app.profiles (user_id, display_name)
select id, left(coalesce(nullif(split_part(coalesce(email, ''), '@', 1), ''), '旅伴'), 60) from auth.users
on conflict do nothing;

create function app.set_display_name(p_name text) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
begin
  if length(btrim(coalesce(p_name, ''))) not between 1 and 60 then
    raise exception 'INVALID_NAME' using errcode = 'PT422';
  end if;
  insert into app.profiles (user_id, display_name) values (uid, btrim(p_name))
  on conflict (user_id) do update set display_name = excluded.display_name, updated_at = now();
end;
$$;

-- What the invite web page may show (D4): trip name, dates, inviter, role.
-- Never itinerary content. Only the invite Edge Function (service role) calls it.
create function app.invite_preview(p_token text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  inv app.invites;
  t app.trips;
begin
  select * into inv from app.invites where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;
  select * into t from app.trips where id = inv.trip_id;
  return jsonb_build_object(
    'status', case
      when inv.revoked_at is not null then 'revoked'
      when inv.expires_at <= now() or (inv.max_uses is not null and inv.use_count >= inv.max_uses) then 'expired'
      else 'valid' end,
    'trip_name', t.name,
    'start_date', t.start_date,
    'end_date', t.end_date,
    'role', inv.role,
    'inviter', (select display_name from app.profiles where user_id = inv.created_by));
end;
$$;

-- Owner-facing invite list (tokens are never stored or returned again).
create policy invites_owner_read_all on app.invites
  for select to authenticated using (app.trip_role_of(trip_id) = 'owner');

-- Offline queue: a client-generated id makes save_place safe to retry.
alter table app.saved_places add column client_op_id uuid unique;

drop function app.save_place(uuid, text, app.saved_category, uuid, jsonb);

create function app.save_place(
  p_trip_id uuid,
  p_raw_label text,
  p_category app.saved_category default 'place',
  p_place_id uuid default null,
  p_source jsonb default null,
  p_client_op_id uuid default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  s app.saved_places;
  src uuid;
  canonical text := nullif(btrim(p_source ->> 'canonical_url'), '');
  duplicate boolean := false;
begin
  perform app.require_role(p_trip_id, array['owner', 'editor']::app.trip_role[]);

  -- A retried offline operation returns what the first attempt created.
  if p_client_op_id is not null then
    select * into s from app.saved_places where client_op_id = p_client_op_id and trip_id = p_trip_id;
    if found then
      return to_jsonb(s) || jsonb_build_object('duplicate', true);
    end if;
  end if;

  if length(btrim(coalesce(p_raw_label, ''))) = 0 then
    raise exception 'INVALID_SAVED' using errcode = 'PT422';
  end if;
  if p_place_id is not null and not exists (select 1 from app.places where id = p_place_id) then
    raise exception 'PLACE_NOT_FOUND' using errcode = 'PT422';
  end if;

  if canonical is not null then
    select sp.* into s from app.saved_places sp
      join app.source_references r on r.id = sp.source_id
     where r.trip_id = p_trip_id and r.canonical_url = canonical and sp.status <> 'dismissed'
     limit 1;
    duplicate := found;
  end if;
  if not duplicate and p_place_id is not null then
    select * into s from app.saved_places
     where trip_id = p_trip_id and place_id = p_place_id and status <> 'dismissed';
    duplicate := found;
  end if;

  if not duplicate then
    if p_source is not null then
      insert into app.source_references (trip_id, type, url, canonical_url, summary, created_by)
      values (p_trip_id, coalesce(p_source ->> 'type', 'share')::app.source_type, p_source ->> 'url', canonical,
              left(p_source ->> 'summary', 2000), uid)
      on conflict (trip_id, canonical_url) where canonical_url is not null do update set canonical_url = excluded.canonical_url
      returning id into src;
    end if;

    insert into app.saved_places (trip_id, place_id, raw_label, category, source_id, added_by, status, client_op_id)
    values (p_trip_id, p_place_id, btrim(p_raw_label), p_category, src, uid,
            case when p_place_id is not null and exists (
                   select 1 from app.stops where trip_id = p_trip_id and place_id = p_place_id and deleted_at is null)
                 then 'added_to_itinerary' else 'saved' end::app.saved_status,
            p_client_op_id)
    returning * into s;
    perform app.bump_trip(p_trip_id, 'saved.changed', s.id);
  end if;

  insert into app.saved_interests (saved_id, user_id) values (s.id, uid) on conflict do nothing;

  return to_jsonb(s) || jsonb_build_object('duplicate', duplicate);
end;
$$;

revoke execute on function
  app.create_default_profile(),
  app.set_display_name(text),
  app.invite_preview(text),
  app.save_place(uuid, text, app.saved_category, uuid, jsonb, uuid)
from public, anon, authenticated;

grant execute on function
  app.set_display_name(text),
  app.save_place(uuid, text, app.saved_category, uuid, jsonb, uuid)
to authenticated;

grant execute on function app.invite_preview(text) to service_role;

-- Realtime: saved changes are already in trip_events; make sure the publication
-- exists locally and in the hosted project.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                     and schemaname = 'app' and tablename = 'trip_events') then
    alter publication supabase_realtime add table app.trip_events;
  end if;
end;
$$;
