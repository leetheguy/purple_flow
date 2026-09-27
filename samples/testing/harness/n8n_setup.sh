#!/bin/bash
# Imports and publishes the n8n side of the tests into a fresh data folder.
#   N8N_DATA=/tmp/n8n-tests ./n8n_setup.sh
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
N8N_DATA=${N8N_DATA:-/tmp/n8n-tests}
IMAGE=${N8N_IMAGE:-n8nio/n8n:2.40.7}
mkdir -p "$N8N_DATA" && chmod 777 "$N8N_DATA"
docker run --rm -v "$HERE/n8n":/w -v "$N8N_DATA":/home/node/.n8n --entrypoint sh "$IMAGE" -c '
  for f in worker main diamonds diamonds_continue; do n8n import:workflow --input=/w/$f.json; done
  for id in stressWorker0001 stressMain000001 diamonds00000001 diamondsCont0001; do n8n publish:workflow --id=$id; done
  n8n list:workflow'
