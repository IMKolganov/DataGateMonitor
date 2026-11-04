\timing on
SET work_mem = '128MB';

-- 1) Hot day aggregate (should hit uncompressed + hot index)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT count(*), coalesce(sum("BytesReceived"),0), coalesce(sum("BytesSent"),0)
FROM xgb_dashopnvpn."VpnServerClientTraffics"
WHERE "MeasuredAt" >= TIMESTAMPTZ '2026-10-18 00:00:00+00'
  AND "MeasuredAt" <  TIMESTAMPTZ '2026-10-19 00:00:00+00';

-- 2) Cold month aggregate (mostly compressed)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT count(*), coalesce(sum("BytesReceived"),0), coalesce(sum("BytesSent"),0)
FROM xgb_dashopnvpn."VpnServerClientTraffics"
WHERE "MeasuredAt" >= TIMESTAMPTZ '2026-03-01 00:00:00+00'
  AND "MeasuredAt" <  TIMESTAMPTZ '2026-04-01 00:00:00+00';

-- 3) ExternalId range (user overview style)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT count(*)
FROM xgb_dashopnvpn."VpnServerClientTraffics"
WHERE "ExternalId" = (
        SELECT "ExternalId" FROM xgb_dashopnvpn."VpnServerClientTraffics"
        WHERE "ExternalId" <> '' LIMIT 1
      )
  AND "MeasuredAt" >= TIMESTAMPTZ '2026-09-01 00:00:00+00'
  AND "MeasuredAt" <  TIMESTAMPTZ '2026-10-01 00:00:00+00';

-- 4) INSERT into hot chunk (simulates poll)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
INSERT INTO xgb_dashopnvpn."VpnServerClientTraffics"
  ("VpnServerId","ExternalId","SessionId","BytesReceived","BytesSent","MeasuredAt","UserId")
VALUES
  (1, 'poc-bench', '00000000-0000-0000-0000-00000000b001'::uuid,
   100, 50, timestamptz '2026-10-19 03:00:00+00', NULL);

-- 5) UNIQUE upsert-style lookup
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT 1
FROM xgb_dashopnvpn."VpnServerClientTraffics"
WHERE "VpnServerId"=1
  AND "MeasuredAt"=timestamptz '2026-10-19 03:00:00+00'
  AND "SessionId"='00000000-0000-0000-0000-00000000b001'::uuid;

-- 6) Simulate UserMerge ExternalId rewrite on a mid-sized id (p50-ish), timed
DO $$
DECLARE
  ext text;
  n int;
  t0 timestamptz;
  t1 timestamptz;
BEGIN
  SELECT "ExternalId" INTO ext
  FROM (
    SELECT "ExternalId", count(*) c
    FROM xgb_dashopnvpn."VpnServerClientTraffics"
    GROUP BY 1
    HAVING count(*) BETWEEN 50000 AND 200000
    ORDER BY count(*)
    LIMIT 1
  ) s;

  IF ext IS NULL THEN
    SELECT "ExternalId" INTO ext
    FROM xgb_dashopnvpn."VpnServerClientTraffics"
    WHERE "ExternalId" <> ''
    GROUP BY 1
    ORDER BY count(*) DESC
    LIMIT 1 OFFSET 5;
  END IF;

  RAISE NOTICE 'merge_sim ExternalId=%', ext;
  t0 := clock_timestamp();
  UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
     SET "ExternalId" = ext || '__merged_poc',
         "LastUpdate" = now()
   WHERE "ExternalId" = ext;
  GET DIAGNOSTICS n = ROW_COUNT;
  t1 := clock_timestamp();
  RAISE NOTICE 'merge_sim updated=% elapsed_ms=%', n, round(1000*extract(epoch FROM (t1-t0)));

  -- rollback rewrite so data stays comparable
  UPDATE xgb_dashopnvpn."VpnServerClientTraffics"
     SET "ExternalId" = ext,
         "LastUpdate" = now()
   WHERE "ExternalId" = ext || '__merged_poc';
END $$;

-- 7) Final sizes
SELECT pg_size_pretty(hypertable_size('xgb_dashopnvpn."VpnServerClientTraffics"')) AS hypertable_size;
SELECT count(*) AS rows FROM xgb_dashopnvpn."VpnServerClientTraffics";
