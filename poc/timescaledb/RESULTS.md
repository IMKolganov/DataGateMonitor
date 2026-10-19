# TimescaleDB PoC results (DataGate VpnServerClientTraffics)

**Branch:** `poc/timescaledb-traffic-compression`  
**Date:** 2026-10-19  
**Image:** `timescale/timescaledb:2.30.2-pg17` (license=`timescale` / Community)  
**Source:** `datagate-dump-pg` dump `datagate_db_prod` (23 631 963 rows)  
**Container:** `datagate-timescale-poc` on port `55435`

## Size — measured

| State | Traffic table size | Notes |
|---|---|---|
| Prod dump (stock PG, all B-trees) | **10 GB** | heap ~2.8 GB + indexes ~7.7 GB |
| Timescale after load, slim indexes only (PK+UX+External) | **7707 MB** | already −2.3 GB vs prod from fewer indexes |
| + hot14 covering | **7900 MB** | |
| **After columnstore (chunks &lt; 2026-10-05)** | **1542 MB** | **−85% vs 10 GB** |
| Compressed chunks only (before→after) | 6854 MB → **494 MB** | **92.8%** savings on those chunks |
| Chunks compressed / hot | **59 / 3** | 7-day chunk interval |

### Projected full database (calculation)

| Component | Size |
|---|---|
| All non-traffic tables (dump) | **3550 MB** (measured on dump) |
| Traffic on Timescale (clean, post-compress) | **1542 MB** (measured) |
| **Projected total** | **≈ 5.1 GB** |

**Verdict on space:** yes — lands in the **5–8 GB** target **if** history stays append-only / merges are rare and followed by recompress.

## Query performance — measured (same SQL)

| Query | Stock PG dump | Timescale after compress |
|---|---|---|
| Hot day 2026-10-18 sum | **41 ms** (covering Index Only) | **29 ms** |
| Cold month 2026-03 sum | **402 ms** (covering Index Only) | **15 ms** (ColumnarScan / VectorAgg) |
| ExternalId + Sep range | — | **0.7 ms** |
| INSERT one poll sample | — | **0.5 ms** |
| UNIQUE-style lookup | — | **0.01 ms** |

Cold analytics are **much faster** on columnstore for this workload.

## UserMerge UPDATE — measured

| Scenario | Rows | Result |
|---|---|---|
| Mid ExternalId rewrite | 51 745 | **389 ms**, OK under default decompress limit |
| Heavy ExternalId (2nd largest) | **1 213 396** | **FAIL** with default `max_tuples_decompressed_per_dml_transaction=100000` |
| Same heavy, limit=`0` | 1 213 396 | **~9 s** update + **~7 s** revert; table grew **1542→~2650 MB** (DML bloat) |
| Monthly batched UPDATE | ~796k user | Still hits **100k decompress limit** on busy months |

**Verdict on merge:** large Telegram↔Google merges **break or bloat** compressed history unless you raise the GUC, batch by smaller time windows, and **recompress** afterward. This is the main product risk.

## What we gained vs what it costs

**Gain**

- Traffic **10 GB → 1.5 GB** (−85%) without deleting rows or changing poll interval.
- Full DB path to **~5 GB**.
- Cold overview aggregates faster.

**Cost**

- New Docker image + Community license (self-hosted OK; not `-oss`).
- PK must be `(MeasuredAt, Id)` — EF/migration work.
- Backup/restore needs Timescale + `pre/post_restore`.
- UserMerge needs a designed strategy (batch + recompress, or append-only aliases).
- Stock logical replication to/from hypertable is not a simple cutover.

## How to re-run

```bash
cd poc/timescaledb
docker compose up -d
./run_poc.sh   # or step 01 → 02 → 03 → 04 manually
```

Tear down (destroys PoC volume):

```bash
cd poc/timescaledb && docker compose down -v
```

## GO criteria follow-up (measured 2026-10-19 evening)

### 1. Size returns after merge + recompress?

**Yes**, with the full cycle `decompress_chunk` → `VACUUM` → `convert_to_columnstore` (not bare `compress_chunk(..., recompress=>true)` alone).

| Step | Size |
|---|---|
| Clean baseline (+ hot covering) | **1517 MB** |
| After heavy merge (1.21M rows, limit=0) | **2198 MB** (+681 MB) |
| After revert | **2244 MB** |
| After decompress → VACUUM → columnstore | **1562 MB** |

Bare `recompress` previously left ~2.7 GB; the **full decompress/VACUUM/columnstore cycle restores ~1.5 GB**.

### 2. Merge under concurrent poll INSERT

Script: `05_merge_under_load.sh` + `insert_load.py` (250 inserts @ ~150 ms spacing during merge).

| Metric | Value |
|---|---|
| Merge rows | **1 213 396** |
| Merge wall time | **8.7 s** (UPDATE) / **8.9 s** wall |
| INSERT errors | **0** |
| INSERT latency | avg **13.5 ms**, p50 **10.9**, p95 **29.0**, max **86 ms** |
| Blocking / stuck poll tx | none observed after merge |
| WAL (merge UPDATE alone, LSN delta) | **1506 MB** |
| WAL (merge + inserts + revert window) | **1660 MB** |

**Implication:** a single large UserMerge writes ~**1.5 GB WAL**. On production with **1.6 GB free** this alone can fill the disk before table bloat is even considered.

### 3. Restore runbook

| Step | Result |
|---|---|
| `pg_dump -Fc` of PoC DB | **431 MB** file |
| Clean container `timescale/timescaledb:2.30.2-pg17` | `datagate-timescale-restore:55436` |
| `CREATE EXTENSION` → `timescaledb_pre_restore` → `pg_restore` (no `-j`) → `timescaledb_post_restore` | **OK** |
| Restored `count(*)` | **23 631 964** (matches source) |
| Restored `hypertable_size` | **1323 MB** (compressed; chunk layout intact 59/3) |

Scripts: `docker-compose.restore.yml`, `06_restore_verify.sh`.

### 4. Prod disk (ops gate, not code)

| Need | Why |
|---|---|
| Expand **before** migration | Merge WAL ~1.5 GB + temporary table growth ~0.7 GB; free 1.6 GB is insufficient |
| Target free space | Prefer **≥15–20 GB free** (migration copy + WAL + recompress headroom) |

## GO / NO-GO checklist

| Criterion | Status |
|---|---|
| Compression saves to ~1.5 GB traffic | **GO** (measured) |
| Size returns after merge via full recompress cycle | **GO** (measured → 1562 MB) |
| Poll INSERT survives concurrent heavy merge | **GO** (no errors; p95 ~29 ms) |
| Restore with pre/post_restore | **GO** (count + size verified) |
| Prod free disk 1.6 GB | **NO-GO until expanded** |
| UserMerge product design (GUC/batch/recompress or append-only) | **NO-GO until designed** |
| EF PK `(MeasuredAt, Id)` + Docker image change | **pending engineering** |

**Overall:** technical PoC is **GO for Timescale capability**; production cutover remains **NO-GO** until disk expansion and UserMerge strategy are decided.

## Recommendation

Timescale **wins on disk and cold reads** for DataGate traffic. Proceed only after: (1) disk expansion, (2) UserMerge plan that includes `max_tuples_decompressed_per_dml_transaction` + post-merge decompress/VACUUM/columnstore (or append-only aliases), (3) EF/PK/migration work. If merge complexity is unacceptable, prefer stock PG + BRIN/index trim (~9–10 GB) instead.
