#!/bin/bash
# Starts n8n fresh under a memory cap, calls one webhook, and reports the
# time, the reply, peak memory, whether the kernel killed it, and the
# executions it recorded. Run n8n_setup.sh first.
#
#   ./n8n_run.sh MEMORY WEBHOOK_PATH 'JSON_BODY' [NODE_OPTIONS]
#   ./n8n_run.sh 512m stress '{"count": 100, "sleep_ms": 1000}'
#   ./n8n_run.sh 2g stress '{"count": 100, "sleep_ms": 1000}' --max-old-space-size=1536
#   ./n8n_run.sh 2g diamonds '{}' --max-old-space-size=1536
#   ./n8n_run.sh 2g diamonds-continue '{}' --max-old-space-size=1536
N8N_DATA=${N8N_DATA:-/tmp/n8n-tests}
IMAGE=${N8N_IMAGE:-n8nio/n8n:2.40.7}
MEM=$1; HOOK=$2; BODY=$3; NODEOPTS=$4
DB="$N8N_DATA/database.sqlite"

sql() { sudo python3 -c "import sqlite3,sys; d=sqlite3.connect('$DB'); r=d.execute(sys.argv[1]).fetchall(); d.commit(); print(r)" "$1"; }

docker rm -f n8n >/dev/null 2>&1
sql "delete from execution_data" >/dev/null; sql "delete from execution_entity" >/dev/null
docker run -d --name n8n --network host --memory "$MEM" --memory-swap "$MEM" --ulimit nofile=20000:20000 \
  -v "$N8N_DATA":/home/node/.n8n -e N8N_LISTEN_ADDRESS=0.0.0.0 -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false -e N8N_SECURE_COOKIE=false ${NODEOPTS:+-e NODE_OPTIONS=$NODEOPTS} \
  "$IMAGE" >/dev/null
for i in $(seq 1 120); do docker logs n8n 2>&1 | grep -q "Finished building workflow dependency index" && break; sleep 1; done
sleep 10
echo "memory=$MEM hook=$HOOK body=$BODY node_options=${NODEOPTS:-none} idle=$(docker stats --no-stream --format '{{.MemUsage}}' n8n)"

STATS=$(mktemp)
(while true; do docker stats --no-stream --format '{{.MemUsage}}' n8n >> "$STATS" 2>/dev/null; sleep 0.5; done) & SAMPLER=$!
s=$(date +%s.%N)
OUT=$(curl -s -m 7200 -w ' [HTTP %{http_code}]' -X POST "localhost:5678/webhook/$HOOK" -H 'content-type: application/json' -d "$BODY")
WALL=$(echo "$(date +%s.%N) - $s" | bc)
sleep 2; kill $SAMPLER
echo "wall=${WALL}s reply=${OUT:0:200}"
echo "peak=$(grep -v '^0B' "$STATS" | awk '{print $1}' | sort -h | tail -1) $(docker inspect n8n --format 'OOMKilled={{.State.OOMKilled}} status={{.State.Status}}')"
echo "executions (workflow, status, count): $(sql "select workflowId, status, count(*) from execution_entity group by 1, 2")"
rm -f "$STATS"
