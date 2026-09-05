#!/usr/bin/env bash
set -uo pipefail

export PATH="/usr/lib/postgresql/15/bin:$PATH"

PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | head -1)"
PGDATA="/var/lib/postgresql/data"
REDIS_DIR="/var/lib/redis"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

echo "$PANEL_PORT${PANEL_PORT:+}" >/dev/null

# ---------------------------------------------------------------------------
# 1. PostgreSQL
# ---------------------------------------------------------------------------
log "Starting PostgreSQL..."
mkdir -p "$PGDATA" /var/run/postgresql
chown -R postgres:postgres "$PGDATA" /var/run/postgresql
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  log "Initializing PostgreSQL cluster..."
  su postgres -c "initdb -D $PGDATA -U postgres --auth-local=trust --auth-host=trust" >/dev/null 2>&1
  echo "host    all             all             0.0.0.0/0            trust" >> "$PGDATA/pg_hba.conf"
  echo "listen_addresses='*'" >> "$PGDATA/postgresql.conf"
fi
su postgres -c "$PGBIN/pg_ctl -D $PGDATA -l /tmp/pg.log start" >/dev/null 2>&1
for i in $(seq 1 30); do
  su postgres -c "$PGBIN/pg_isready -h 127.0.0.1" >/dev/null 2>&1 && break
  sleep 1
done
log "PostgreSQL ready"

# ---------------------------------------------------------------------------
# 2. Redis
# ---------------------------------------------------------------------------
log "Starting Redis..."
mkdir -p "$REDIS_DIR"
redis-server --daemonize yes --bind 0.0.0.0 --port 6379 >/dev/null 2>&1
for i in $(seq 1 15); do
  redis-cli ping >/dev/null 2>&1 && break
  sleep 1
done
log "Redis ready"

# ---------------------------------------------------------------------------
# 3. Panel database + env
# ---------------------------------------------------------------------------
DB_USER="${PGUSER:-airlink}"
DB_PASS="${PGPASSWORD:-airlink}"
DB_NAME="${PGNAME:-airlink}"

log "Creating database/user if needed..."
su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" | grep -q 1 \
  || su postgres -c "psql -c \"CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS' SUPERUSER\""
su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"" | grep -q 1 \
  || su postgres -c "createdb -O $DB_USER $DB_NAME"

# ---------------------------------------------------------------------------
# 4. Panel
# ---------------------------------------------------------------------------
cd /app/panel

if [ ! -f /app/panel/.env ]; then
  log "Writing panel .env..."
  cat > /app/panel/.env <<ENVEOF
URL="http://${PANEL_URL:-127.0.0.1}:${PANEL_PORT:-3000}"
PORT="${PANEL_PORT:-3000}"
NAME="${PANEL_NAME:-Airlink}"
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"
REDIS_URL="redis://127.0.0.1:6379"
NODE_ENV="production"
SESSION_SECRET="${SESSION_SECRET:-change_me}"
PGHOST="127.0.0.1"
PGPORT="5432"
PGUSER="${DB_USER}"
PGPASSWORD="${DB_PASS}"
ENVEOF
fi

if [ ! -d /app/panel/dist ] || [ "$(ls /app/panel/dist 2>/dev/null | wc -l)" = "0" ]; then
  log "Panel not built - building..."
  pnpm install --no-frozen-lockfile >/dev/null 2>&1
  pnpm exec prisma generate >/dev/null 2>&1
  pnpm exec prisma db push >/dev/null 2>&1
  pnpm run build >/dev/null 2>&1
else
  log "Panel already built - running migrations..."
  pnpm exec prisma db push >/dev/null 2>&1 || true
fi

log "Starting panel on :${PANEL_PORT:-3000}..."
pnpm run start > /app/panel/panel.log 2>&1 &
PANEL_PID=$!

# ---------------------------------------------------------------------------
# 5. Daemon (node)
# ---------------------------------------------------------------------------
cd /app/daemon

DAEMON_KEY="${DAEMON_KEY:-}"
if [ -n "$DAEMON_KEY" ]; then
  cat > /app/daemon/.env <<ENVEOF
REMOTE=${PANEL_URL:-127.0.0.1}
KEY=${DAEMON_KEY}
PORT=${DAEMON_PORT:-3002}
DEBUG=false
VERSION=3.0.0
STATS_INTERVAL=10000
CONTAINER_RUNTIME=docker
REQUIRE_HMAC=true
ALLOWED_IPS=
BEHIND_PROXY=false
ENVEOF
  log "Starting daemon on :${DAEMON_PORT:-3002}..."
  bun run start > /app/daemon/daemon.log 2>&1 &
  DAEMON_PID=$!
else
  log "DAEMON_KEY not set - daemon not started. Set DAEMON_KEY to enable the node."
fi

trap 'kill $PANEL_PID $DAEMON_PID 2>/dev/null' TERM INT

log "All services started. Panel=$PANEL_PID Daemon=${DAEMON_PID:-none}"
tail -f /app/panel/panel.log /app/daemon/daemon.log 2>/dev/null &
wait
