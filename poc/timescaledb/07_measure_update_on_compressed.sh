#!/usr/bin/env bash
# Point 3: UPDATE-on-compressed vs full decompress_chunk, with fair recompress
# (only chunks older than HOT_CUTOFF → columnstore; VACUUM outside TX).
set -euo pipefail

PSQL=(docker exec -i datagate-timescale-poc psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1 -At)
PSQL_FULL=(docker exec -i datagate-timescale-poc psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1)

OLD_ID="${1:-111216730339576536199}"
NEW_ID="__measure_rewrite_tmp__"
HOT_CUTOFF="2026-10-05 00:00:00+00"

size_mb() {
  "${PSQL[@]}" -c "SELECT hypertable_size('\"xgb_dashopnvpn\".\"VpnServerClientTraffics\"')/1024/1024;"
}

recompress_cold() {
  "${PSQL_FULL[@]}" <<SQL
SET search_path TO xgb_dashopnvpn, public;
DO \$\$
DECLARE c regclass;
BEGIN
  FOR c IN
    SELECT show_chunks('xgb_dashopnvpn."VpnServerClientTraffics"', older_than => TIMESTAMPTZ '${HOT_CUTOFF}')
  LOOP
    BEGIN
      CALL convert_to_columnstore(c);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'convert skipped %: %', c, SQLERRM;
    END;
  END LOOP;
END \$\$;
VACUUM (ANALYZE) xgb_dashopnvpn."VpnServerClientTraffics";
SQL
}

echo "=== baseline ==="
BASE=$(size_mb)
ROWS=$("${PSQL[@]}" -c "SELECT count(*) FROM xgb_dashopnvpn.\"VpnServerClientTraffics\" WHERE \"ExternalId\"='${OLD_ID}';")
echo "traffic_mb=$BASE  rows=$ROWS  old=$OLD_ID"

echo
echo "=== PATH A: UPDATE on compressed (GUC=0) → cold columnstore → VACUUM ==="
T0=$(date +%s.%N)
"${PSQL_FULL[@]}" <<SQL
SET search_path TO xgb_dashopnvpn, public;
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
SET "ExternalId" = '${NEW_ID}', "LastUpdate" = now()
WHERE "ExternalId" = '${OLD_ID}';
SQL
echo "size_after_update_mb=$(size_mb)"
recompress_cold
echo "size_after_recompress_vacuum_mb=$(size_mb)"
T1=$(date +%s.%N)
echo "path_a_wall_s=$(python3 -c "print(round($T1-$T0,1))")"

echo "revert A…"
"${PSQL_FULL[@]}" <<SQL
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
SET "ExternalId" = '${OLD_ID}', "LastUpdate" = now()
WHERE "ExternalId" = '${NEW_ID}';
SQL
recompress_cold
echo "size_after_revert_mb=$(size_mb)"

echo
echo "=== PATH B: decompress all cold chunks → UPDATE → VACUUM → cold columnstore ==="
T0=$(date +%s.%N)
"${PSQL_FULL[@]}" <<SQL
SET search_path TO xgb_dashopnvpn, public;
SELECT decompress_chunk(c)
FROM show_chunks('xgb_dashopnvpn."VpnServerClientTraffics"', older_than => TIMESTAMPTZ '${HOT_CUTOFF}') c;
SQL
echo "size_after_full_decompress_mb=$(size_mb)"

"${PSQL_FULL[@]}" <<SQL
UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
SET "ExternalId" = '${NEW_ID}', "LastUpdate" = now()
WHERE "ExternalId" = '${OLD_ID}';
SQL
echo "size_after_update_mb=$(size_mb)"
recompress_cold
echo "size_after_recompress_vacuum_mb=$(size_mb)"
T1=$(date +%s.%N)
echo "path_b_wall_s=$(python3 -c "print(round($T1-$T0,1))")"

echo "revert B…"
"${PSQL_FULL[@]}" <<SQL
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
SET "ExternalId" = '${OLD_ID}', "LastUpdate" = now()
WHERE "ExternalId" = '${NEW_ID}';
SQL
recompress_cold
echo "final_size_mb=$(size_mb)  (baseline was $BASE)"
echo "DONE"
