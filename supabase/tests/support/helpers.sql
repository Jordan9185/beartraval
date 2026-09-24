-- Assertion helpers for SQL tests. A failed assertion raises, and psql runs with
-- ON_ERROR_STOP, so the test file stops with a non-zero exit code.

create schema tests;
grant usage on schema tests to authenticated, anon;

-- Acts as the given user for subsequent statements (pair with SET ROLE authenticated).
create function tests.login(p_user uuid) returns void
language sql
as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
$$;

create function tests.logout() returns void
language sql
as $$
  select set_config('request.jwt.claims', '', false);
$$;

create function tests.ok(p_cond boolean, p_msg text) returns void
language plpgsql
as $$
begin
  if p_cond is distinct from true then
    raise exception 'FAIL: %', p_msg;
  end if;
  raise notice 'ok - %', p_msg;
end;
$$;

-- Runs p_sql and asserts it fails with SQLSTATE p_code.
create function tests.throws(p_sql text, p_code text, p_msg text) returns void
language plpgsql
as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_code then
      raise notice 'ok - % (% %)', p_msg, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % - expected %, got % %', p_msg, p_code, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % - expected %, but statement succeeded', p_msg, p_code;
end;
$$;

grant execute on all functions in schema tests to authenticated, anon;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com'),
  ('00000000-0000-0000-0000-00000000000b', 'editor@example.com'),
  ('00000000-0000-0000-0000-00000000000c', 'viewer@example.com'),
  ('00000000-0000-0000-0000-00000000000d', 'outsider@example.com'),
  ('00000000-0000-0000-0000-00000000000e', 'amy@example.com');

insert into app.places (provider, provider_place_id, name, name_local, latitude, longitude, country_code) values
  ('apple', 'seoul-myeongdong-shoes', 'XXX Shoes Myeongdong', 'XXX 슈즈 명동점', 37.5636, 126.9850, 'KR'),
  ('apple', 'seoul-seongsu-shoes', 'XXX Shoes Seongsu', 'XXX 슈즈 성수점', 37.5446, 127.0557, 'KR'),
  ('apple', 'seoul-hotel', 'Hotel Seoul', null, 37.5600, 126.9800, 'KR');
