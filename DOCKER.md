# Running Edge Scanner in Docker

One container runs everything: the scanner engine, the FastAPI API/dashboard on
port 7777, and the built React dashboard served at `/v2`. The dashboard is
built in a separate Node stage so the runtime image ships only Python.

## Quick start

```bash
cp .env.example .env      # fill in ALPACA_API_KEY / ALPACA_SECRET_KEY
docker compose up -d --build
```

Open **http://localhost:7777/v2**. The first start downloads ~a year of daily
bars and 20 days of 5-minute bars for the whole universe (10–20 min); later
starts reuse the cache in the `edgescanner-data` volume.

## Files added for Docker

| File | What it does |
|---|---|
| `Dockerfile` | Two stages: Node 24 builds `dashboard-v2` → `dist`, Python 3.11-slim runs the scanner (`start_scanner.sh --host 0.0.0.0`) |
| `docker-compose.yml` | Named volume for `data/`, port bound to `127.0.0.1` only, env from `.env` |
| `.dockerignore` | Keeps `.git`, `node_modules`, `data/`, `.env` etc. out of the image |

`.env` is **not** baked into the image — it is injected at runtime via
`env_file`, so keys never end up in image layers.

## Key details

- **Port binding**: the scanner's default `--host 127.0.0.1` binds loopback
  inside the container; the entrypoint adds `--host 0.0.0.0` so the port
  mapping can reach it. Compose maps it back to **localhost only** on the host
  (`127.0.0.1:7777:7777`), matching the project's local-first design: the API
  has no authentication.
- **Healthcheck**: `GET /api/v2/clock` (a cheap, dependency-free route) with a
  35-minute start period — the API doesn't come up until universe build,
  sector mapping, and bar warmup finish on the first boot.
- **Timezone**: `TZ=America/New_York` baked in (tzdata installed) — the market
  clock and session logic need it.
- **Passing options**: anything after the image name goes to
  `scripts/run_live.py` via `start_scanner.sh`, e.g.
  `docker compose run --rm edge-scanner --log-level INFO`, or set `command:`
  in compose.
- **Logs**: `docker logs -f edge-scanner` — alerts print there as they fire,
  plus the scan heartbeat.
  `docker compose run --rm edge-scanner --refresh-universe`.
- **Upgrades**: `git pull && docker compose up -d --build`. `data/` lives in
  the volume, so caches, setups, watchlists and alert archives are untouched.
- **Tests**: run on the host as usual (`python -m pytest`; CI tests on Python
  3.11) — `tests/` is excluded from the image via `.dockerignore`.
- **Schwab users**: `DATA_PROVIDER=schwab` in `.env` works, but the one-time
  login (`scripts/schwab_auth.py`) is an interactive paste-the-callback-URL
  flow. Run it with the data volume mounted so the token persists:
  `docker compose run --rm -it edge-scanner python scripts/schwab_auth.py`
  (the token lives under `data/`, expires every 7 days — rerun weekly).

## What was verified (host: Debian 13, no Docker daemon)

This machine has no Docker daemon (it is itself a container; no docker socket,
no sudo, user namespaces disabled), so the image could not be built here. Every
Dockerfile step was instead verified natively on the exact versions the image
uses:

- `uv venv --python 3.11` + `pip install -r requirements.txt` — clean install
- `python -m pytest` — **492 passed, 6 skipped**
- `npm ci && npm run build` (Node 26) — dashboard builds, `dist/` output confirmed
- `start_scanner.sh` chain: execs `scripts/run_live.py`, which fails cleanly
  ("Could not authenticate with Alpaca") without keys — expected, no hang

## Security notes

- The API is unauthenticated by design (local-first app). The compose port
  mapping keeps it host-localhost-only; **do not** change it to `7777:7777`
  unless the whole network is trusted.
- `.env` (keys) is injected at runtime, never baked into the image; the
  `.dockerignore` also excludes it from the build context.
- The container runs as the unprivileged `scanner` user (uid 1000).