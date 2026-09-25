#!/usr/bin/env bash
# Robust dev-server launcher for Purple Flow.
#
# Use this instead of a bare `mix phx.server` — it waits for Postgres to
# actually accept connections before booting, and it restarts the server if
# it ever crashes or wedges (e.g. a beam node alive but the endpoint dead).
#
# Usage:
#   nohup bin/start.sh > /root/purple_flow/phx_server.log 2>&1 &
#
# To stop: bin/stop.sh (kills anything holding the pidfile/port).

set -u
cd "$(dirname "$0")/.."

PGHOST="${POSTGRES_HOST:-localhost}"
PGPORT="${POSTGRES_PORT:-5432}"
PIDFILE=/root/purple_flow/tmp/phx_server.pid
mkdir -p /root/purple_flow/tmp

wait_for_postgres() {
  echo "[start.sh] waiting for postgres at ${PGHOST}:${PGPORT}..."
  for i in $(seq 1 60); do
    if (echo > "/dev/tcp/${PGHOST}/${PGPORT}") >/dev/null 2>&1; then
      echo "[start.sh] postgres is accepting TCP connections (attempt ${i})"
      # TCP accept doesn't mean Postgres finished recovery/auth setup yet;
      # give it a short additional grace period on top of the port check.
      sleep 2
      return 0
    fi
    sleep 1
  done
  echo "[start.sh] postgres never became reachable after 60s, giving up" >&2
  return 1
}

stop_stale() {
  if [ -f "$PIDFILE" ]; then
    old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
      echo "[start.sh] stopping stale server (pid ${old_pid})"
      kill "$old_pid" 2>/dev/null
      sleep 2
      kill -9 "$old_pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
  fi
}

stop_stale

PORT="${PORT:-4000}"

echo "[start.sh] starting supervised mix phx.server loop"
while true; do
  if ! wait_for_postgres; then
    echo "[start.sh] postgres unreachable, retrying in 5s..."
    sleep 5
    continue
  fi

  mix phx.server &
  server_pid=$!
  echo "$server_pid" > "$PIDFILE"
  echo "[start.sh] mix phx.server started, pid ${server_pid}"

  # Give it time to boot, then poll: restart if the process dies, if it's
  # alive but the endpoint never comes up within BOOT_TIMEOUT, or if it's
  # alive but stops responding (the "wedged" failure mode — a live beam.smp
  # with no listener on $PORT).
  booted=false
  elapsed=0
  boot_timeout=60
  while kill -0 "$server_pid" 2>/dev/null; do
    if curl -s -m 3 -o /dev/null "http://localhost:${PORT}/"; then
      booted=true
    elif [ "$booted" = true ] || [ "$elapsed" -ge "$boot_timeout" ]; then
      echo "[start.sh] server not responding on port ${PORT} (booted=${booted}, elapsed=${elapsed}s), killing pid ${server_pid}"
      kill "$server_pid" 2>/dev/null
      sleep 2
      kill -9 "$server_pid" 2>/dev/null
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  wait "$server_pid" 2>/dev/null
  echo "[start.sh] mix phx.server is down, restarting in 3s..."
  rm -f "$PIDFILE"
  sleep 3
done
