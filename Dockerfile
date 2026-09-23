# Edge Scanner — the live scanner, API and dashboard in one container.
#
#   docker build -t edge-scanner .
#   docker compose up -d --build      (set your Alpaca keys first — see DOCKER.md)
#
# The API has NO authentication: keep port 7777 bound to localhost / a trusted
# network only (the scanner itself warns about this in scripts/run_live.py).

# ── Stage 1: build the React dashboard → dashboard-v2/dist ──────────────────
# Node 24 matches the version the project's own CI builds with.
FROM node:24-slim AS dashboard
WORKDIR /build/dashboard-v2
# Install dependencies in their own layer so they only re-run when the
# lockfile changes.
COPY dashboard-v2/package.json dashboard-v2/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY dashboard-v2/ ./
# Vite 8 outputs everything the scanner serves at /v2 (base '/v2/' is set in
# vite.config.ts).
RUN npm run build

# ── Stage 2: runtime — scanner + FastAPI + built dashboard ──────────────────
FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    TZ=America/New_York
WORKDIR /app

# tzdata: the market clock / session logic uses America/New_York.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata \
 && rm -rf /var/lib/apt/lists/*

# Python dependencies in their own layer (the project ships a single
# requirements.txt covering runtime + tests).
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Application code. Everything the scanner writes at runtime goes to data/,
# which is a volume — the rest of /app can stay read-only-in-practice.
COPY scanner/ ./scanner/
COPY scripts/ ./scripts/
COPY start_scanner.sh ./
RUN chmod +x start_scanner.sh

# Built dashboard from stage 1, served at http://localhost:7777/v2
COPY --from=dashboard /build/dashboard-v2/dist ./dashboard-v2/dist

# Unprivileged user; data/ is the only path that needs to be writable.
RUN useradd --create-home --uid 1000 scanner \
 && mkdir -p /app/data \
 && chown -R scanner:scanner /app
USER scanner
VOLUME ["/app/data"]

EXPOSE 7777

# The API only starts after warmup. First start downloads ~a year of daily
# bars plus 20 days of 5-min bars (10–20 min); later starts use the data/
# cache. start-period covers the first boot without flapping to unhealthy.
HEALTHCHECK --interval=30s --timeout=10s --start-period=35m --retries=3 \
  CMD python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:7777/api/v2/clock', timeout=8)"

# start_scanner.sh cds to /app, picks data/universe_all.csv when present and
# passes any extra args through to scripts/run_live.py, e.g.:
#   docker run edge-scanner --log-level INFO
# --host 0.0.0.0 is required inside a container (default binds loopback only).
ENTRYPOINT ["./start_scanner.sh", "--host", "0.0.0.0"]