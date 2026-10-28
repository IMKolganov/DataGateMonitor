# TimescaleDB PoC for DataGate traffic

Isolated experiment (separate Docker volume/port). Does not modify production or `datagate-dump-pg` data.

See [RESULTS.md](./RESULTS.md) for measured outcomes.

## Prerequisites

- Running `datagate-dump-pg` with restored `datagate_db_prod` (source of truth for COPY).
- ~15–20 GB free disk for the PoC volume.

## Run

```bash
cd poc/timescaledb
docker compose up -d
./run_poc.sh
```

Optional follow-ups:

```bash
./05_merge_under_load.sh    # merge + parallel INSERT + recompress
./06_restore_verify.sh      # pg_dump → clean container restore
```

Ports: PoC `localhost:55435`, restore verify `localhost:55436`  
(user/pass/db: `datagate` / `datagate` / `timescale_poc` or `timescale_poc_restored`).

## Cleanup

```bash
docker compose down -v
docker compose -f docker-compose.restore.yml down -v
```
