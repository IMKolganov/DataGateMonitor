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

Port: `localhost:55435` (user/pass/db: `datagate` / `datagate` / `timescale_poc`).

## Cleanup

```bash
docker compose down -v
```
