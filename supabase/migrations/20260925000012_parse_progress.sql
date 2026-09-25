-- Parse progress for the import screen. The parser streams the model output and
-- reports what it has found so far; the app polls this while it waits.
--
-- parse_progress: { "stage": "reading" | "writing", "days": int, "stops": int,
--                   "last_place": text | null }

alter table app.import_sessions add column parse_progress jsonb;

create function app.record_parse_progress(p_import_id uuid, p_progress jsonb) returns void
language sql security definer
set search_path = ''
as $$
  update app.import_sessions
     set parse_progress = p_progress
   where id = p_import_id and trip_id is null and parse_status = 'parsing';
$$;

revoke execute on function app.record_parse_progress(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.record_parse_progress(uuid, jsonb) to service_role;
