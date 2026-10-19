#!/usr/bin/env bash
# Parallel poll-INSERT during heavy ExternalId merge; measure latency + WAL.
set -euo pipefail
CTR=datagate-timescale-poc
EXT='115178355732195369151'
LAT_HOST=/tmp/ts_insert_lat_ms.txt
: > "$LAT_HOST"

psql_ts() {
  docker exec -i "$CTR" psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1 "$@"
}

echo "== baseline =="
psql_ts <<'SQL'
SELECT pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS size,
       pg_current_wal_lsn() AS wal;
SQL

WAL_BEFORE=$(psql_ts -tAc "SELECT pg_current_wal_lsn();")
echo "WAL_BEFORE=$WAL_BEFORE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
docker exec "$CTR" bash -c 'rm -f /tmp/insert_lat_ms.txt /tmp/insert_done.flag /tmp/insert_err.txt'
docker cp "$SCRIPT_DIR/insert_load.py" "$CTR":/tmp/insert_load.py
docker exec -d "$CTR" python3 /tmp/insert_load.py

sleep 3
echo "== heavy merge =="
MERGE_T0=$(date +%s%N)
psql_ts <<SQL
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
SELECT now() AS merge_start, pg_current_wal_lsn() AS wal_merge_start;
\timing on
UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
   SET "ExternalId" = '${EXT}__m', "LastUpdate" = now()
 WHERE "ExternalId" = '${EXT}';
SELECT now() AS merge_end, pg_current_wal_lsn() AS wal_merge_end;
SELECT pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS size_after_merge;
SELECT count(*) AS merged_rows FROM xgb_dashopnvpn."VpnServerClientTraffics" WHERE "ExternalId" = '${EXT}__m';
SQL
MERGE_T1=$(date +%s%N)
echo "merge_wall_ms=$(( (MERGE_T1 - MERGE_T0) / 1000000 ))"

echo "== wait for inserts =="
for _ in $(seq 1 90); do
  if docker exec "$CTR" test -f /tmp/insert_done.flag; then break; fi
  sleep 1
done

WAL_AFTER=$(psql_ts -tAc "SELECT pg_current_wal_lsn();")
echo "WAL_AFTER=$WAL_AFTER"
psql_ts -c "SELECT pg_size_pretty(pg_wal_lsn_diff('${WAL_AFTER}'::pg_lsn, '${WAL_BEFORE}'::pg_lsn)) AS wal_grown;"

docker cp "$CTR":/tmp/insert_lat_ms.txt "$LAT_HOST" 2>/dev/null || true
echo "== insert latency ms =="
python3 - <<'PY'
from pathlib import Path
p = Path("/tmp/ts_insert_lat_ms.txt")
vals = [float(x) for x in p.read_text().split() if x.strip()]
if not vals:
    print("no samples")
else:
    vals.sort()
    def pct(p):
        return vals[min(len(vals)-1, int(len(vals)*p))]
    print(f"count={len(vals)} avg={sum(vals)/len(vals):.2f} p50={pct(0.5):.2f} p95={pct(0.95):.2f} max={vals[-1]:.2f}")
PY

if docker exec "$CTR" test -f /tmp/insert_err.txt; then
  echo "== insert errors (first 20 lines) =="
  docker exec "$CTR" head -20 /tmp/insert_err.txt || true
fi

echo "== blocking locks / long tx (if any) =="
psql_ts <<'SQL'
SELECT pid, state, wait_event_type, wait_event,
       now()-xact_start AS xact_age, left(query,120) AS query
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid()
ORDER BY xact_start NULLS LAST;
SQL

echo "== revert merge =="
psql_ts <<SQL
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
\timing on
UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
   SET "ExternalId" = '${EXT}', "LastUpdate" = now()
 WHERE "ExternalId" = '${EXT}__m';
SELECT pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS size_after_revert;
SELECT count(*) AS restored_rows FROM xgb_dashopnvpn."VpnServerClientTraffics" WHERE "ExternalId" = '${EXT}';
SQL

echo "== cleanup poll rows =="
psql_ts <<'SQL'
DELETE FROM xgb_dashopnvpn."VpnServerClientTraffics" WHERE "ExternalId" = 'poc-poll-load';
SQL

echo "== recompress cycle =="
psql_ts <<'SQL'
\timing on
DO $$
DECLARE c regclass; n int := 0;
BEGIN
  FOR c IN
    SELECT format('%I.%I', chunk_schema, chunk_name)::regclass
    FROM timescaledb_information.chunks
    WHERE hypertable_schema='xgb_dashopnvpn' AND hypertable_name='VpnServerClientTraffics'
      AND is_compressed
  LOOP
    PERFORM decompress_chunk(c);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'decompressed=%', n;
END $$;
VACUUM (ANALYZE) xgb_dashopnvpn."VpnServerClientTraffics";
DO $$
DECLARE c regclass; n int := 0;
BEGIN
  FOR c IN
    SELECT show_chunks('xgb_dashopnvpn."VpnServerClientTraffics"', older_than => TIMESTAMPTZ '2026-10-05 00:00:00+00')
  LOOP
    EXECUTE format('CALL convert_to_columnstore(%L::regclass)', c);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'recompressed=%', n;
END $$;
SELECT pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS size_after_recompress;
SELECT count(*) AS rows FROM xgb_dashopnvpn."VpnServerClientTraffics";
SQL

echo "DONE"
