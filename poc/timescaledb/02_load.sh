#!/usr/bin/env bash
# Stream VpnServerClientTraffics from datagate-dump-pg into timescaledb-poc (no dump file on disk).
set -euo pipefail

DUMP_CTR="${DUMP_CTR:-datagate-dump-pg}"
TS_CTR="${TS_CTR:-datagate-timescale-poc}"

echo "==> Counting source rows..."
SRC_COUNT=$(docker exec "$DUMP_CTR" psql -U datagate -d datagate_db_prod -tAc \
  'SELECT count(*) FROM xgb_dashopnvpn."VpnServerClientTraffics"')
echo "Source rows: $SRC_COUNT"

echo "==> Streaming COPY dump-pg -> timescale-poc ..."
# Columns match 01_schema.sql (explicit list; Id preserved from source).
docker exec "$DUMP_CTR" psql -U datagate -d datagate_db_prod -v ON_ERROR_STOP=1 -c \
  "COPY (
     SELECT \"Id\",\"VpnServerId\",\"ExternalId\",\"SessionId\",
            \"BytesReceived\",\"BytesSent\",\"MeasuredAt\",
            \"CreateDate\",\"LastUpdate\",\"UserId\"
     FROM xgb_dashopnvpn.\"VpnServerClientTraffics\"
   ) TO STDOUT WITH (FORMAT binary)" \
| docker exec -i "$TS_CTR" psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1 -c \
  "COPY xgb_dashopnvpn.\"VpnServerClientTraffics\"
     (\"Id\",\"VpnServerId\",\"ExternalId\",\"SessionId\",
      \"BytesReceived\",\"BytesSent\",\"MeasuredAt\",
      \"CreateDate\",\"LastUpdate\",\"UserId\")
   FROM STDIN WITH (FORMAT binary)"

echo "==> Reset identity sequence past max(Id)..."
docker exec "$TS_CTR" psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1 -c \
  "SELECT setval(
     pg_get_serial_sequence('xgb_dashopnvpn.\"VpnServerClientTraffics\"', 'Id'),
     (SELECT COALESCE(MAX(\"Id\"), 1) FROM xgb_dashopnvpn.\"VpnServerClientTraffics\")
   );"

DST_COUNT=$(docker exec "$TS_CTR" psql -U datagate -d timescale_poc -tAc \
  'SELECT count(*) FROM xgb_dashopnvpn."VpnServerClientTraffics"')
echo "Dest rows: $DST_COUNT"
if [[ "$SRC_COUNT" != "$DST_COUNT" ]]; then
  echo "ERROR: row count mismatch ($SRC_COUNT vs $DST_COUNT)" >&2
  exit 1
fi
echo "Load OK."
