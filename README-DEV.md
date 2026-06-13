<h1 align="left">
  <img src="frontend/public/favicon.svg" width="32" height="32" alt="" />
  DataGate Monitor — development
</h1>

Monorepo dev guide. Production quick start: [README.md](README.md).

## Prerequisites

- Docker & Docker Compose
- Git with submodules
- For frontend-only work: Node.js **≥24.14** (see `frontend/package.json`)

## First-time setup

```bash
git clone --recurse-submodules https://github.com/IMKolganov/DataGateMonitor.git
cd DataGateMonitor
git submodule update --init --recursive
```

## Full stack (Docker, local build)

```bash
docker compose -f docker-compose-local.yml --env-file .env.dev.x64 up -d --build
```

Rebuild without cache:

```bash
docker compose -f docker-compose-local.yml --env-file .env.dev.x64 build --no-cache
docker compose -f docker-compose-local.yml --env-file .env.dev.x64 up -d
```

| Service | URL |
|---------|-----|
| Dashboard | http://localhost:5582 |
| API | http://localhost:5581 |
| Frontend dev (optional) | http://localhost:5173 — see [frontend/README.md](frontend/README.md) |

Use `.env.dev.arm64` on Apple Silicon instead of `.env.dev.x64`.

## Build Docker images manually

```bash
./build.sh backend frontend openvpn xray telegrambot
```

Image prefix: `imkolganov/datagate-monitor-*` (override with `IMAGE_PREFIX`).

## Submodule development

Each service lives in its own repo (submodule). Typical flow:

1. Commit changes inside `backend/`, `frontend/`, etc.
2. Push the submodule branch
3. Bump submodule SHA in this monorepo and commit

## Backend only

See [backend/README.md](backend/README.md). SharedModels come from NuGet (`DataGateMonitor.SharedModels`) — never project-reference the SharedModels `.csproj`.

## Frontend only

```bash
cd frontend
npm ci
npm run dev
```

## Links

| Resource | Link |
|----------|------|
| <img src="https://raw.githubusercontent.com/IMKolganov/DataGateMonitorFrontend/main/public/favicon.svg" width="16" height="16" alt="" /> **DataGate** | [datagateapp.com](https://datagateapp.com/) |
| <img src="https://cdn.simpleicons.org/googleplay/414141" width="16" height="16" alt="" /> **Download** | [datagateapp.com/download](https://datagateapp.com/download) |
| <img src="https://cdn.simpleicons.org/grafana/F46800" width="16" height="16" alt="" /> **Dashboard** | [dash.datagateapp.com](https://dash.datagateapp.com/) |
| <img src="https://cdn.simpleicons.org/telegram/26A5E4" width="16" height="16" alt="" /> **Telegram channel** | [@datagateapp](https://t.me/datagateapp) |
