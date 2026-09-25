#!/usr/bin/env bash
# Stops a Purple Flow server started with bin/start.sh.
set -u
cd "$(dirname "$0")/.."

PIDFILE=/root/purple_flow/tmp/phx_server.pid

if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    echo "[stop.sh] stopping start.sh supervisor and server (pid ${pid})"
    # start.sh itself may also be running as the parent of this pid; kill both
    # the recorded server pid and any start.sh process for this project.
    kill "$pid" 2>/dev/null
  fi
  rm -f "$PIDFILE"
fi

pkill -f "bin/start.sh" 2>/dev/null
pkill -f "mix phx.server" 2>/dev/null

echo "[stop.sh] done"
