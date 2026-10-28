\timing on

ANALYZE xgb_dashopnvpn."VpnServerClientTraffics";

SELECT 'before_compression' AS phase,
       pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS hypertable;

DROP INDEX IF EXISTS xgb_dashopnvpn."IX_ClientTraffic_At_Covering_Hot14";
CREATE INDEX "IX_ClientTraffic_At_Covering_Hot14"
    ON xgb_dashopnvpn."VpnServerClientTraffics" ("MeasuredAt", "SessionId")
    INCLUDE ("ExternalId", "VpnServerId", "BytesReceived", "BytesSent")
    WHERE "MeasuredAt" >= TIMESTAMPTZ '2026-10-05 00:00:00+00';

ALTER TABLE xgb_dashopnvpn."VpnServerClientTraffics" SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = '"MeasuredAt" DESC',
    timescaledb.segmentby = '"ExternalId"'
);

DO $$
DECLARE
  c regclass;
  n int := 0;
  t0 timestamptz := clock_timestamp();
BEGIN
  FOR c IN
    SELECT show_chunks('xgb_dashopnvpn."VpnServerClientTraffics"', older_than => TIMESTAMPTZ '2026-10-05 00:00:00+00')
  LOOP
    EXECUTE format('CALL convert_to_columnstore(%L::regclass)', c);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'compressed_chunks=% elapsed_s=%', n, round(extract(epoch FROM clock_timestamp() - t0));
END $$;

ANALYZE xgb_dashopnvpn."VpnServerClientTraffics";

SELECT 'after_compression' AS phase,
       pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS hypertable;

SELECT
    count(*) FILTER (WHERE is_compressed) AS compressed_chunks,
    count(*) FILTER (WHERE NOT is_compressed) AS uncompressed_chunks
FROM timescaledb_information.chunks
WHERE hypertable_schema = 'xgb_dashopnvpn'
  AND hypertable_name = 'VpnServerClientTraffics';

SELECT
    round(100.0 * (1 - sum(after_compression_total_bytes)::numeric
                       / NULLIF(sum(before_compression_total_bytes), 0)), 1) AS overall_chunk_saved_pct,
    pg_size_pretty(sum(before_compression_total_bytes)) AS before_sum,
    pg_size_pretty(sum(after_compression_total_bytes)) AS after_sum
FROM chunk_compression_stats('xgb_dashopnvpn."VpnServerClientTraffics"')
WHERE before_compression_total_bytes IS NOT NULL;
