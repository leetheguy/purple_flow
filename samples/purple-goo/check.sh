#!/bin/bash
# Purple Goo's precommit: loads the sample into a running PurpleFlow, runs
# the test suite and a streaming check, and cleans up however it ends.
#
#   samples/purple-goo/check.sh        (from the repo root, app running in Docker)
#
# It copies this folder into the workflows folder as zz_purple_goo, waits
# until every workflow in it loads with no problems, runs goo_tests, then
# streams one answer through goo's webhook. Exits 1 on any failure.
#
# Settings (environment, else the repo's .env):
#   PF_PORT         the app's port (PORT in .env, else 4000)
#   PF_TOKEN        PURPLEFLOW_AGENT_TOKEN, for /api/workflows
#   WORKFLOWS_PATH  the workflows folder (default ./workflows, as in compose)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
env_value() { grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2-; }
PORT=${PF_PORT:-$(env_value PORT)}; PORT=${PORT:-4000}
TOKEN=${PF_TOKEN:-$(env_value PURPLEFLOW_AGENT_TOKEN)}
WORKFLOWS=${WORKFLOWS_PATH:-$(env_value WORKFLOWS_PATH)}; WORKFLOWS=${WORKFLOWS:-./workflows}
BASE="http://localhost:$PORT"
COPY="$WORKFLOWS/zz_purple_goo"
FAKE="$BASE/hooks/goo-fake-llm/chat/completions"
NAMES="goo goo_map goo_chain goo_tests goo_fake_llm goo_test_data goo_test_open goo_test_close"

# The skill sheet's copy in goo's prompts must match its source (spec 020).
python3 - "$HERE" <<'PY' || exit 1
import sys
here = sys.argv[1]
source = open(f"{here}/skills/swarm-json/SKILL.md").read().split("---\n", 2)[2].strip("\n")
prompts = open(f"{here}/goo/prompts.exs").read()
copy = prompts.split('skill = ~S"""\n', 1)[1].split('\n"""', 1)[0]
if copy != source:
    print("FAIL  goo/prompts.exs's skill sheet differs from skills/swarm-json/SKILL.md; copy it over")
    sys.exit(1)
print("PASS  the skill sheet in goo/prompts.exs matches SKILL.md")
PY

trap 'rm -rf "$COPY"; echo "Removed $COPY"' EXIT
rm -rf "$COPY" && cp -r "$HERE" "$COPY" && rm -f "$COPY/check.sh"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%S)
echo "Copied the sample into $COPY; waiting for $BASE to load it…"

# Loaded = a reload after the copy, and every workflow present with no problems.
loaded() {
  curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/workflows" | python3 -c '
import json, sys
started, names = sys.argv[1], sys.argv[2].split()
d = json.load(sys.stdin)
if d["reloaded_at"][:19] < started: sys.exit(2)
ok = {w["name"]: w for w in d["workflows"]}
bad = [f"{n}: missing" for n in names if n not in ok]
bad += [f"{w["name"]}: {w["problems"]}" for w in ok.values() if w["name"] in names and w["problems"]]
bad += [f"{w["folder"]}: {w["problems"]}" for w in d["not_loaded"] if "zz_purple_goo" in w["folder"]]
print("\n".join(bad)); sys.exit(1 if bad else 0)' "$STARTED" "$NAMES"
}
for _ in $(seq 1 40); do problems=$(loaded); status=$?; [ $status -ne 2 ] && break; sleep 0.5; done
if [ $status -ne 0 ]; then echo "FAIL  the sample didn't load:"; echo "$problems"; exit 1; fi
echo "PASS  every workflow loaded"

failed=0
report=$(curl -s -m 300 -X POST "$BASE/hooks/goo-tests" -H 'content-type: application/json' \
  -d "{\"fake_url\": \"$FAKE\"}")
echo "$report" | python3 -c '
import json, sys
try: r = json.load(sys.stdin)
except Exception: print("FAIL  goo_tests gave no report"); sys.exit(1)
if "passed" not in r: print("FAIL  goo_tests:", r); sys.exit(1)
for f in r["failed"]: print("FAIL ", f["case"], "\n       got:", f["detail"])
print(("PASS " if not r["failed"] else "FAIL "), f"{r["passed"]}/{r["total"]} test cases")
sys.exit(1 if r["failed"] else 0)' || failed=1

# Only the top monad streams (spec 010 rule 7): check it in the real app.
stream=$(curl -s -N -m 60 -X POST "$BASE/hooks/goo/v1/chat/completions" -H 'content-type: application/json' \
  -d "{\"model\": \"m1\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}],
       \"metadata\": {\"_meta\": {\"provider_url\": \"$FAKE\"}, \"monads\": [{}]}}")
if echo "$stream" | grep -q '^data: {' && echo "$stream" | grep -q '^data: \[DONE\]'; then
  echo "PASS  the top monad streams an OpenAI answer"
else
  echo "FAIL  the top monad didn't stream"; echo "       got: ${stream:0:300}"; failed=1
fi

[ $failed -eq 0 ] && echo "Purple Goo check passed" || { echo "Purple Goo check FAILED"; exit 1; }
