-- Minimal stand-in for the pieces of a Supabase project the migrations rely on,
-- so they can be tested on plain Postgres. Never apply this to a real project.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;

create table auth.users (
  id    uuid primary key,
  email text
);

-- Same resolution order as Supabase's auth.uid().
create function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
