#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DUMP="$ROOT/artifacts/timescale_poc.dump"
CTR=datagate-timescale-restore

cd "$ROOT"
docker compose -f docker-compose.restore.yml up -d

echo "==> wait healthy..."
for _ in $(seq 1 60); do
  if docker exec "$CTR" pg_isready -U datagate -d postgres >/dev/null 2>&1; then break; fi
  sleep 2
done

docker cp "$DUMP" "$CTR":/tmp/timescale_poc.dump

echo "==> create empty DB + extension + pre_restore..."
docker exec -i "$CTR" psql -U datagate -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DROP DATABASE IF EXISTS timescale_poc_restored;
CREATE DATABASE timescale_poc_restored OWNER datagate;
SQL

docker exec -i "$CTR" psql -U datagate -d timescale_poc_restored -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
SELECT timescaledb_pre_restore();
SQL

echo "==> pg_restore (no -j)..."
docker exec "$CTR" pg_restore -U datagate -d timescale_poc_restored --no-owner -Fc /tmp/timescale_poc.dump

echo "==> post_restore..."
docker exec -i "$CTR" psql -U datagate -d timescale_poc_restored -v ON_ERROR_STOP=1 <<'SQL'
SELECT timescaledb_post_restore();
ANALYZE xgb_dashopnvpn."VpnServerClientTraffics";
SELECT count(*) AS rows FROM xgb_dashopnvpn."VpnServerClientTraffics";
SELECT pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS hypertable_size;
SELECT
  count(*) FILTER (WHERE is_compressed) AS compressed_chunks,
  count(*) FILTER (WHERE NOT is_compressed) AS uncompressed_chunks
FROM timescaledb_information.chunks
WHERE hypertable_schema='xgb_dashopnvpn' AND hypertable_name='VpnServerClientTraffics';
SELECT extversion, current_setting('timescaledb.license') AS license
FROM pg_extension WHERE extname='timescaledb';
SQL

echo "RESTORE VERIFY DONE"
