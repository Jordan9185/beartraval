-- One parse per import at a time (review H4). The app's request times out
-- before a long parse finishes; a retry used to start a second, billed parse.
-- begin_parse claims the import for parsing; a claim older than 8 minutes is
-- treated as abandoned (the Edge Function stops well before that).

create function app.begin_parse(p_import_id uuid) returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
  update app.import_sessions
     set parse_status = 'parsing', parse_result = null, parse_error = null, parse_progress = null,
         updated_at = now()
   where id = p_import_id
     and trip_id is null
     and (parse_status <> 'parsing' or updated_at < now() - interval '8 minutes');
  return found;
end;
$$;

revoke execute on function app.begin_parse(uuid) from public, anon, authenticated;
grant execute on function app.begin_parse(uuid) to service_role;
