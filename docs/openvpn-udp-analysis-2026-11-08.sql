-- Reproduce with:
-- docker exec -i datagate-audit-20261108 psql -X -U postgres -d datagate \
--   -v ON_ERROR_STOP=1 -P pager=off < docs/openvpn-udp-analysis-2026-11-08.sql
-- Output contains aggregates and public server addresses, no client identities/IPs.
\set ON_ERROR_STOP on
\set window_start '2026-11-07 12:30:36+00'
\set alert '2026-11-08 12:12:16.81221+00'
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL TIME ZONE 'Asia/Nicosia';

-- Restore integrity and disabled background jobs in the local snapshot.
SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
SELECT hypertable_schema, hypertable_name, num_chunks
FROM timescaledb_information.hypertables;
SELECT job_id, scheduled FROM timescaledb_information.jobs ORDER BY job_id;

-- Recorded sessions, not raw connection attempts. UNDEF is separated.
SELECT s."Id", s."ServerName", s."CreateDate", s."IsOnline",
       s."IsAvailableByExternalProbe", s."DcoIsEnabled", c.*
FROM xgb_dashopnvpn."VpnServers" s
LEFT JOIN LATERAL (
    SELECT count(*) AS client_records,
           count(*) FILTER (WHERE "CommonName" <> 'UNDEF') AS named_sessions,
           count(*) FILTER (WHERE "CommonName" = 'UNDEF') AS undef,
           count(DISTINCT nullif("ExternalId", '')) AS users,
           min("ConnectedSince") AS first_connection,
           max("ConnectedSince") AS last_new_connection,
           round(sum("BytesReceived" + "BytesSent")
                 FILTER (WHERE "CommonName" <> 'UNDEF') / 1e9, 3) AS named_gb,
           count(*) FILTER (WHERE "IsConnected") AS connected,
           count(*) FILTER (WHERE "RemoteIp" NOT LIKE '%127.0.0.1%'
                              AND "RemoteIp" NOT LIKE '%::1%') AS nonloopback
    FROM xgb_dashopnvpn."VpnServerClients" WHERE "VpnServerId" = s."Id"
) c ON true
WHERE s."Id" IN (104, 105, 166, 167, 168) ORDER BY s."Id";

-- Full timeline includes the common overnight loss AND recovery of all targets.
SELECT "CreateDate", "Type", "Message"
FROM xgb_dashopnvpn."Notifications"
WHERE "Type" LIKE 'availability.%' AND "CreateDate" >= '2026-11-07 10:00+00'
ORDER BY "CreateDate";

-- Same exposure window. Existing sessions at the start are included.
SELECT "VpnServerId", count(*) AS named_sessions_overlapping_window,
       count(DISTINCT nullif("ExternalId", '')) AS users,
       count(DISTINCT regexp_replace("CommonName", '^([^-]+)-[0-9]+-', '\1-')) AS devices,
       count(DISTINCT nullif(regexp_replace(coalesce("ProxyRealIp", ''), ':[0-9]+$', ''), '')) AS public_ip_count,
       round(sum(extract(epoch FROM
           least(coalesce("DisconnectedAt", :'alert'::timestamptz), :'alert'::timestamptz)
           - greatest("ConnectedSince", :'window_start'::timestamptz))) / 3600, 2) AS session_hours
FROM xgb_dashopnvpn."VpnServerClients"
WHERE "VpnServerId" IN (104, 105, 167, 168) AND "CommonName" <> 'UNDEF'
  AND "ConnectedSince" < :'alert'::timestamptz
  AND coalesce("DisconnectedAt", :'alert'::timestamptz) > :'window_start'::timestamptz
GROUP BY "VpnServerId" ORDER BY "VpnServerId";

-- Traffic is cumulative: take maxima per session and subtract its start baseline.
WITH per_session AS (
    SELECT t."VpnServerId", t."SessionId",
           max(t."BytesReceived") + max(t."BytesSent") AS bytes,
           max(t."BytesReceived") FILTER (WHERE t."MeasuredAt" <= :'window_start'::timestamptz)
             + max(t."BytesSent") FILTER (WHERE t."MeasuredAt" <= :'window_start'::timestamptz) AS baseline
    FROM xgb_dashopnvpn."VpnServerClientTraffics" t
    JOIN xgb_dashopnvpn."VpnServerClients" c
      ON c."VpnServerId" = t."VpnServerId" AND c."SessionId" = t."SessionId"
    WHERE t."VpnServerId" IN (167, 168) AND c."CommonName" <> 'UNDEF'
      AND t."MeasuredAt" <= :'alert'::timestamptz
    GROUP BY 1, 2
)
SELECT "VpnServerId", round(sum(bytes - coalesce(baseline, 0)) / 1e9, 3) AS matched_window_gb
FROM per_session GROUP BY 1 ORDER BY 1;

-- Same device key = platform + ExternalId + installation identifier, removing node ID.
WITH c AS (
    SELECT *, regexp_replace("CommonName", '^([^-]+)-[0-9]+-', '\1-') AS device
    FROM xgb_dashopnvpn."VpnServerClients"
    WHERE "VpnServerId" IN (167, 168) AND "CommonName" <> 'UNDEF'
), shared AS (
    SELECT device FROM c GROUP BY device HAVING count(DISTINCT "VpnServerId") = 2
)
SELECT c."VpnServerId", count(*) AS sessions, count(DISTINCT c.device) AS shared_devices,
       round(sum("BytesReceived" + "BytesSent") / 1e9, 3) AS recorded_gb
FROM c JOIN shared USING (device) GROUP BY 1 ORDER BY 1;

-- After the UDP alert: new TCP sessions and continued traffic of old UDP sessions.
SELECT "VpnServerId", count(*) AS new_named_sessions_after_alert
FROM xgb_dashopnvpn."VpnServerClients"
WHERE "VpnServerId" IN (167, 168) AND "CommonName" <> 'UNDEF'
  AND "ConnectedSince" >= :'alert'::timestamptz
GROUP BY 1 ORDER BY 1;

WITH increments AS (
    SELECT t."VpnServerId", t."SessionId", c."Country",
           max(t."BytesReceived") - min(t."BytesReceived")
             + max(t."BytesSent") - min(t."BytesSent") AS delta
    FROM xgb_dashopnvpn."VpnServerClientTraffics" t
    JOIN xgb_dashopnvpn."VpnServerClients" c
      ON c."VpnServerId" = t."VpnServerId" AND c."SessionId" = t."SessionId"
    WHERE t."VpnServerId" IN (167, 168) AND c."CommonName" <> 'UNDEF'
      AND t."MeasuredAt" >= :'alert'::timestamptz
    GROUP BY 1, 2, 3
)
SELECT "VpnServerId", "Country", count(*) FILTER (WHERE delta > 0) AS sessions_with_traffic,
       round(sum(delta) / 1e6, 3) AS measured_mb_after_alert
FROM increments GROUP BY 1, 2 ORDER BY 1, 2;

-- All UDP UNDEF records have a named record for the same socket and start time.
WITH u AS (
    SELECT * FROM xgb_dashopnvpn."VpnServerClients"
    WHERE "VpnServerId" IN (167, 168) AND "CommonName" = 'UNDEF'
)
SELECT u."VpnServerId", count(*) AS undef,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM xgb_dashopnvpn."VpnServerClients" c
           WHERE c."VpnServerId" = u."VpnServerId" AND c."RemoteIp" = u."RemoteIp"
             AND c."ConnectedSince" = u."ConnectedSince" AND c."CommonName" <> 'UNDEF'
       )) AS same_connection_named
FROM u GROUP BY 1 ORDER BY 1;

-- No daemon restart at the UDP failure; compare the old working UDP control too.
SELECT DISTINCT ON (v."VpnServerId") v."VpnServerId", v."Version", v."UpSince", v."LastUpdate"
FROM xgb_dashopnvpn."VpnServerStatusLogs" v
WHERE v."VpnServerId" IN (104, 105, 166, 167, 168)
ORDER BY v."VpnServerId", v."LastUpdate" DESC;

-- Early UDP 166 had an issued profile but no recorded session or event.
SELECT s."Id",
       (SELECT count(*) FROM xgb_dashopnvpn."IssuedOvpnFiles" f WHERE f."VpnServerId" = s."Id") AS profiles,
       (SELECT min("IssuedAt") FROM xgb_dashopnvpn."IssuedOvpnFiles" f WHERE f."VpnServerId" = s."Id") AS first_profile,
       (SELECT count(*) FROM xgb_dashopnvpn."VpnServerEventLogs" e WHERE e."VpnServerId" = s."Id") AS events,
       (SELECT count(*) FROM xgb_dashopnvpn."VpnServerClients" c WHERE c."VpnServerId" = s."Id") AS sessions
FROM xgb_dashopnvpn."VpnServers" s WHERE s."Id" = 166;
COMMIT;
