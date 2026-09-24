-- AI assistant (WP10): conversation kept with the trip and deleted with it
-- (D11). Answers are written by the ask-trip Edge Function (service role);
-- proposals it suggests go through create_proposal like any other.

create table app.ai_messages (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references app.trips (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  question    text not null check (length(question) <= 2000),
  answer      jsonb,
  status      text not null,
  model       text,
  created_at  timestamptz not null default now()
);

create index ai_messages_trip_user_idx on app.ai_messages (trip_id, user_id, created_at);

alter table app.ai_messages enable row level security;

create policy ai_messages_own_read on app.ai_messages
  for select to authenticated using (user_id = auth.uid() and app.trip_role_of(trip_id) is not null);

grant select on app.ai_messages to authenticated;
revoke insert, update, delete, truncate on app.ai_messages from authenticated, anon;
grant insert on app.ai_messages to service_role;

-- Proposals remember whether the AI suggested them (plan §3.1).
drop function app.create_proposal(uuid, bigint, jsonb, jsonb);

create function app.create_proposal(
  p_day_id uuid,
  p_expected_route_revision bigint,
  p_change jsonb,
  p_route_match jsonb default null,
  p_created_by_ai boolean default false
) returns app.change_proposals
language plpgsql security definer
set search_path = ''
as $$
declare
  uid uuid := app.current_user_id();
  d app.trip_days;
  p app.change_proposals;
  place uuid;
begin
  select * into d from app.trip_days where id = p_day_id;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(d.trip_id, array['owner', 'editor']::app.trip_role[]);

  if d.route_revision <> p_expected_route_revision then
    raise exception 'STALE_REVISION'
      using errcode = 'PT409', detail = pg_catalog.format('current route_revision is %s', d.route_revision);
  end if;

  place := nullif(p_change ->> 'place_id', '')::uuid;
  if place is null or not exists (select 1 from app.places where id = place) then
    raise exception 'PLACE_UNRESOLVED' using errcode = 'PT422';
  end if;
  if length(btrim(coalesce(p_change ->> 'raw_label', ''))) = 0 then
    raise exception 'INVALID_STOPS' using errcode = 'PT422';
  end if;

  insert into app.change_proposals (trip_id, day_id, change, route_match, expected_route_revision, created_by, created_by_ai)
  values (d.trip_id, d.id, p_change, p_route_match, p_expected_route_revision, uid, coalesce(p_created_by_ai, false))
  returning * into p;
  return p;
end;
$$;

revoke execute on function app.create_proposal(uuid, bigint, jsonb, jsonb, boolean) from public, anon;
grant execute on function app.create_proposal(uuid, bigint, jsonb, jsonb, boolean) to authenticated;
