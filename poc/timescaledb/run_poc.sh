#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Starting TimescaleDB PoC container..."
docker compose up -d
echo "==> Waiting for healthy..."
for i in $(seq 1 60); do
  if docker exec datagate-timescale-poc pg_isready -U datagate -d timescale_poc >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec datagate-timescale-poc pg_isready -U datagate -d timescale_poc

echo "==> Schema..."
docker exec -i datagate-timescale-poc psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1 < "$ROOT/01_schema.sql"

echo "==> Load..."
chmod +x "$ROOT/02_load.sh"
"$ROOT/02_load.sh"

echo "==> Columnstore / compression..."
docker exec -i datagate-timescale-poc psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1 < "$ROOT/03_columnstore.sql"

echo "==> Benchmarks..."
docker exec -i datagate-timescale-poc psql -U datagate -d timescale_poc -v ON_ERROR_STOP=1 < "$ROOT/04_benchmarks.sql"

echo "==> PoC finished."
