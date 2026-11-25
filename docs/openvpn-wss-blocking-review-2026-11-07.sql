-- Run against the independently restored local snapshot:
-- docker exec -i datagate-audit-20261107 psql -X -U postgres -d datagate \
--   -v ON_ERROR_STOP=1 -P pager=off < docs/openvpn-wss-blocking-review-2026-11-07.sql
-- No writes, customer identities, certificates, tokens or client IPs in the output.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL TIME ZONE 'UTC';

-- 1. Restore integrity. Expected: one hypertable, one dimension, 65 slices/chunks.
SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
SELECT hypertable_schema, hypertable_name, num_dimensions, num_chunks
FROM timescaledb_information.hypertables;
SELECT
    (SELECT count(*) FROM _timescaledb_catalog.dimension) AS dimensions,
    (SELECT count(*) FROM _timescaledb_catalog.dimension_slice) AS slices,
    (SELECT count(*) FROM _timescaledb_catalog.chunk) AS chunks;

-- 2. Manager availability and external-probe availability are different flags.
SELECT "Id", "ServerName", "IsOnline", "IsAvailableByExternalProbe",
       "ExternalProbeCheckedAtUtc", "ExternalProbeSummary"
FROM xgb_dashopnvpn."VpnServers"
WHERE "Id" IN (104, 105, 158, 160, 161, 162, 163, 164, 165)
ORDER BY "Id";

-- Notification timestamps are detection times, not exact onset times.
SELECT s."Id", min(n."CreateDate") AS first_unreachable_notification_utc
FROM xgb_dashopnvpn."VpnServers" s
JOIN xgb_dashopnvpn."Notifications" n
  ON n."Message" LIKE '%(' || s."ApiUrl" || ').%'
WHERE s."Id" IN (160, 161, 162, 163)
  AND n."Type" = 'availability.check.unreachable'
GROUP BY s."Id"
ORDER BY s."Id";

-- 3. UNDEF records and authenticated records of the same connection.
-- Match server, complete local address (including port), and exact start time.
-- This is stronger evidence than matching public mobile IPs within two hours.
WITH undef AS (
    SELECT * FROM xgb_dashopnvpn."VpnServerClients"
    WHERE "VpnServerId" IN (160, 161, 162, 163) AND "CommonName" = 'UNDEF'
), matched AS (
    SELECT u.*,
        EXISTS (
            SELECT 1 FROM xgb_dashopnvpn."VpnServerClients" c
            WHERE c."VpnServerId" = u."VpnServerId"
              AND c."RemoteIp" = u."RemoteIp"
              AND c."ConnectedSince" = u."ConnectedSince"
              AND c."CommonName" <> 'UNDEF'
        ) AS named_same_connection,
        EXISTS (
            SELECT 1 FROM xgb_dashopnvpn."VpnServerEventLogs" e
            WHERE e."VpnServerId" = u."VpnServerId"
              AND e."RealAddress" = u."RemoteIp"
              AND e."EventType" = 'ClientConnected'
              AND e."EventTimeUtc" BETWEEN u."ConnectedSince" - interval '10s'
                                       AND u."ConnectedSince" + interval '90s'
        ) AS authenticated_same_socket
    FROM undef u
)
SELECT "VpnServerId", count(*) AS undef_records,
       count(*) FILTER (WHERE named_same_connection) AS named_same_connection,
       count(*) FILTER (WHERE authenticated_same_socket) AS authenticated_same_socket
FROM matched GROUP BY "VpnServerId" ORDER BY "VpnServerId";

-- 4. Counter increases after BOTH locations had produced unreachable alerts.
-- Max minus min per session; do not sum cumulative traffic samples.
-- Country is the stored GeoIP classification, not proof of current client location.
WITH per_session AS (
    SELECT t."VpnServerId", t."SessionId", c."Country",
           max(t."BytesReceived") - min(t."BytesReceived")
             + max(t."BytesSent") - min(t."BytesSent") AS bytes_delta,
           min(t."MeasuredAt") AS first_sample,
           max(t."MeasuredAt") AS last_sample
    FROM xgb_dashopnvpn."VpnServerClientTraffics" t
    JOIN xgb_dashopnvpn."VpnServerClients" c
      ON c."VpnServerId" = t."VpnServerId" AND c."SessionId" = t."SessionId"
    WHERE t."VpnServerId" IN (160, 161, 162, 163)
      AND t."MeasuredAt" >= '2026-11-07 09:30:00+00'
    GROUP BY t."VpnServerId", t."SessionId", c."Country"
)
SELECT "VpnServerId", "Country",
       count(*) FILTER (WHERE bytes_delta > 0) AS sessions_with_traffic,
       round(sum(bytes_delta) / 1e6, 3) AS decimal_mb,
       min(first_sample) AS first_sample, max(last_sample) AS last_sample
FROM per_session GROUP BY "VpnServerId", "Country"
ORDER BY "VpnServerId", "Country";

-- 5. Loopback peers describe observed sessions, not all probes or listening sockets.
SELECT "VpnServerId", count(*) AS client_records,
       count(*) FILTER (WHERE "RemoteIp" NOT LIKE '%127.0.0.1%'
                          AND "RemoteIp" NOT LIKE '%::1%') AS non_loopback_records
FROM xgb_dashopnvpn."VpnServerClients"
WHERE "VpnServerId" IN (160, 161, 162, 163)
GROUP BY "VpnServerId" ORDER BY "VpnServerId";

COMMIT;
