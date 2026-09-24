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

# Two editors commit to the same day at the same time. The first holds the day
# lock for a moment; the second must wait, then get STALE_REVISION (AC-13).
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
select pg_sleep(1.5);
commit;
SQL
A_PID=$!
sleep 0.5
set +e
"${PSQL[@]}" -d t_concurrency >"$WORK/b.out" 2>&1 <<SQL
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.commit_itinerary('$DAY_ID', 0, '[{"raw_label":"from B"}]');
SQL
B_STATUS=$?
set -e
wait "$A_PID"
LABELS="$("${PSQL[@]}" -d t_concurrency -At -c "select string_agg(raw_label, ',') from app.stops where deleted_at is null")"

if [[ $B_STATUS -ne 0 ]] && grep -q STALE_REVISION "$WORK/b.out" && [[ "$LABELS" == "from A" ]]; then
  echo "PASS concurrency (second concurrent commit got STALE_REVISION; no silent overwrite)"
else
  echo "FAIL concurrency (b status=$B_STATUS, stops=$LABELS)"
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
select pg_sleep(1.5);
commit;
SQL
PA_PID=$!
sleep 0.5
"${PSQL[@]}" -d t_proposal_race -At >"$WORK/pb.out" 2>&1 <<SQL
set role authenticated;
select tests.login('00000000-0000-0000-0000-00000000000a');
select app.confirm_proposal('$P_B') ->> 'status';
SQL
wait "$PA_PID"
RACE_LABELS="$("${PSQL[@]}" -d t_proposal_race -At -c "select string_agg(raw_label, ',') from app.stops where deleted_at is null")"

if grep -qx confirmed "$WORK/pa.out" && grep -qx stale "$WORK/pb.out" && [[ "$RACE_LABELS" == "from A" ]]; then
  echo "PASS proposal race (second concurrent confirm got stale; no silent overwrite)"
else
  echo "FAIL proposal race (stops=$RACE_LABELS)"
  cat "$WORK/pa.out" "$WORK/pb.out"
  failed=1
fi

exit $failed
