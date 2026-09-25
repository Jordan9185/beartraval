#!/usr/bin/env bash
# Runs the database tests against a throwaway local Postgres (16+).
#
#   supabase/tests/run.sh
#
# Applies a minimal Supabase shim, then every migration, then each *.test.sql in
# its own fresh database, then a two-session concurrency check. Exits non-zero
# on the first failure. Needs initdb/pg_ctl/psql; set PG_BIN to override lookup.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPABASE_DIR="$(dirname "$TESTS_DIR")"

# Postgres refuses to run as root; re-run as the postgres user.
if [[ "$(id -u)" == "0" ]]; then
  exec runuser -u postgres -- "$0" "$@"
fi

PG_BIN="${PG_BIN:-$(pg_config --bindir 2>/dev/null || ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
PORT="${PGTEST_PORT:-54329}"
export PGHOST="$WORK" PGPORT="$PORT" PGUSER="$(id -un)"

cleanup() {
  "$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

"$PG_BIN/initdb" -D "$WORK/data" -A trust -U "$PGUSER" >/dev/null
"$PG_BIN/pg_ctl" -D "$WORK/data" -l "$WORK/pg.log" \
  -o "-k $WORK -p $PORT -c listen_addresses=''" -w start >/dev/null

PSQL=("$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1)

"$PG_BIN/createdb" bt_template
"${PSQL[@]}" -d bt_template -f "$TESTS_DIR/support/supabase_shim.sql"
for m in "$SUPABASE_DIR"/migrations/*.sql; do
  "${PSQL[@]}" -d bt_template -f "$m"
done
"${PSQL[@]}" -d bt_template -f "$TESTS_DIR/support/helpers.sql"

failed=0
for t in "$TESTS_DIR"/*.test.sql; do
  name="$(basename "$t" .test.sql)"
  "$PG_BIN/createdb" -T bt_template "t_$name"
  if out="$("${PSQL[@]}" -d "t_$name" -f "$t" 2>&1)"; then
    echo "PASS $name ($(grep -c 'ok - ' <<<"$out") assertions)"
  else
    echo "FAIL $name"
    echo "$out" | grep -v '^psql:.*NOTICE:  ok - ' | tail -20
    failed=1
  fi
done

# Concurrency checks. Session A takes a lock, then holds it until session B is
# blocked on that lock (seen in pg_stat_activity), so the order never depends on
# timing. A prints "waiter blocked" once B was waiting; without it the check fails.
HOLD_UNTIL_WAITER=$(cat <<'SQL'
reset role;
do $$
begin
  for i in 1..400 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity
                where datname = current_database() and pid <> pg_backend_pid() and wait_event_type = 'Lock') then
      raise notice 'waiter blocked';
      return;
    end if;
    perform pg_sleep(0.05);
  end loop;
  raise exception 'no other session waited for the lock';
end;
$$;
SQL
)

# Polls until session A (in database $1) is holding its lock and waiting in the loop above (20 s at most).
await_holder() {
  local i
  for ((i = 0; i < 400; i++)); do
    if [[ "$("${PSQL[@]}" -d "$1" -At -c "select count(*) from pg_stat_activity where datname = '$1' and wait_event = 'PgSleep'")" != "0" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "timed out waiting for session A in $1" >&2
  return 1
}

# Two editors commit to the same day at the same time. The first holds the day
# lock; the second must wait, then get STALE_REVISION (AC-13).
"$PG_BIN/createdb" -T bt_template t_concurrency
"${PSQL[@]}" -d t_concurrency <<'SQL' >/dev/null
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select id from app.create_trip('Race', '2026-10-01', '2026-10-01', 'Asia/Seoul');
SQL
DAY_ID="$("${PSQL[@]}" -d t_concurrency -At -c "select id from app.trip_days limit 1")"

"${PSQL[@]}" -d t_concurrency >"$WORK/a.out" 2>&1 <<SQL &
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
begin;
select app.commit_itinerary('$DAY_ID', 0, '[{"raw_label":"from A"}]');
$HOLD_UNTIL_WAITER
commit;
SQL
A_PID=$!
await_holder t_concurrency || true
set +e
"${PSQL[@]}" -d t_concurrency >"$WORK/b.out" 2>&1 <<SQL
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.commit_itinerary('$DAY_ID', 0, '[{"raw_label":"from B"}]');
SQL
B_STATUS=$?
wait "$A_PID"
A_STATUS=$?
set -e
LABELS="$("${PSQL[@]}" -d t_concurrency -At -c "select string_agg(raw_label, ',') from app.stops where deleted_at is null")"

if [[ $A_STATUS -eq 0 && $B_STATUS -ne 0 ]] && grep -q 'waiter blocked' "$WORK/a.out" && grep -q STALE_REVISION "$WORK/b.out" \
   && [[ "$LABELS" == "from A" ]]; then
  echo "PASS concurrency (second concurrent commit waited, then got STALE_REVISION; no silent overwrite)"
else
  echo "FAIL concurrency (a status=$A_STATUS, b status=$B_STATUS, stops=$LABELS)"
  cat "$WORK/a.out" "$WORK/b.out"
  failed=1
fi

# Two editors confirm proposals made against the same revision at the same time.
# The second waits for the day lock, then gets "stale" and nothing is written.
"$PG_BIN/createdb" -T bt_template t_proposal_race
"${PSQL[@]}" -d t_proposal_race <<'SQL' >/dev/null
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select id from app.create_trip('Race', '2026-10-01', '2026-10-01', 'Asia/Seoul');
select app.upsert_place('apple_mapkit', 'race', 'Race', 37.5, 127.0);
SQL
RACE_DAY="$("${PSQL[@]}" -d t_proposal_race -At -c "select id from app.trip_days limit 1")"
RACE_PLACE="$("${PSQL[@]}" -d t_proposal_race -At -c "select id from app.places where provider_place_id = 'race'")"
propose() {
  "${PSQL[@]}" -d t_proposal_race -At <<SQL
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select id from app.create_proposal('$RACE_DAY', 0, '{"place_id": "$RACE_PLACE", "raw_label": "$1"}');
SQL
}
P_A="$(propose "from A" | tail -1)"
P_B="$(propose "from B" | tail -1)"

"${PSQL[@]}" -d t_proposal_race -At >"$WORK/pa.out" 2>&1 <<SQL &
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
begin;
select app.confirm_proposal('$P_A') ->> 'status';
$HOLD_UNTIL_WAITER
commit;
SQL
PA_PID=$!
await_holder t_proposal_race || true
set +e
"${PSQL[@]}" -d t_proposal_race -At >"$WORK/pb.out" 2>&1 <<SQL
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.confirm_proposal('$P_B') ->> 'status';
SQL
wait "$PA_PID"
set -e
RACE_LABELS="$("${PSQL[@]}" -d t_proposal_race -At -c "select string_agg(raw_label, ',') from app.stops where deleted_at is null")"

if grep -qx confirmed "$WORK/pa.out" && grep -q 'waiter blocked' "$WORK/pa.out" && grep -qx stale "$WORK/pb.out" \
   && [[ "$RACE_LABELS" == "from A" ]]; then
  echo "PASS proposal race (second concurrent confirm waited, then got stale; no silent overwrite)"
else
  echo "FAIL proposal race (stops=$RACE_LABELS)"
  cat "$WORK/pa.out" "$WORK/pb.out"
  failed=1
fi

# Two members save the same place at the same time. The second insert waits on
# the first one's unique-index entry, then gets the first entry back as a
# duplicate instead of a unique_violation error.
"$PG_BIN/createdb" -T bt_template t_save_race
"${PSQL[@]}" -d t_save_race <<'SQL' >/dev/null
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select id from app.create_trip('Race', '2026-10-01', '2026-10-01', 'Asia/Seoul');
select app.upsert_place('apple_mapkit', 'race', 'Race', 37.5, 127.0);
SQL
SAVE_TRIP="$("${PSQL[@]}" -d t_save_race -At -c "select id from app.trips limit 1")"
SAVE_PLACE="$("${PSQL[@]}" -d t_save_race -At -c "select id from app.places where provider_place_id = 'race'")"

"${PSQL[@]}" -d t_save_race -At >"$WORK/sa.out" 2>&1 <<SQL &
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
begin;
select app.save_place('$SAVE_TRIP', 'from A', 'eat', '$SAVE_PLACE') ->> 'duplicate';
$HOLD_UNTIL_WAITER
commit;
SQL
SA_PID=$!
await_holder t_save_race || true
set +e
"${PSQL[@]}" -d t_save_race -At >"$WORK/sb.out" 2>&1 <<SQL
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.save_place('$SAVE_TRIP', 'from B', 'eat', '$SAVE_PLACE') ->> 'duplicate';
SQL
SB_STATUS=$?
wait "$SA_PID"
set -e
SAVED_LABELS="$("${PSQL[@]}" -d t_save_race -At -c "select string_agg(raw_label, ',') from app.saved_places")"

if [[ $SB_STATUS -eq 0 ]] && grep -qx false "$WORK/sa.out" && grep -q 'waiter blocked' "$WORK/sa.out" \
   && grep -qx true "$WORK/sb.out" && [[ "$SAVED_LABELS" == "from A" ]]; then
  echo "PASS save race (second concurrent save of the same place returned the first entry as a duplicate)"
else
  echo "FAIL save race (b status=$SB_STATUS, saved=$SAVED_LABELS)"
  cat "$WORK/sa.out" "$WORK/sb.out"
  failed=1
fi

exit $failed
