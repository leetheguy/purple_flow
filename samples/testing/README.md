# Testing workflows

Pressure tests for PurpleFlow, and the same tests built for n8n so the two
can be compared. The results are written up in
[docs/n8n_case_study.md](../../docs/n8n_case_study.md). Between them, these
tests found five PurpleFlow bugs; each is in that write-up.

| Folder | What it is |
|---|---|
| `stress/` | One run, many Code executions at once (default 10,000, each sleeping 1 s). Tests concurrency and memory. |
| `diamonds/` | 100 "diamonds" in a row: each branches into a step that always fails and one that counts, then merges. Tests failure handling and graph size. |
| `n8n/` | The same two tests as n8n workflows (n8n 2.40.7), plus a diamonds variant with n8n's "continue on error" turned on. |
| `harness/` | Scripts that run each test and report time, memory, and outcome. |

Every execution is saved, so a 10,000-item stress run adds about 10,000
`step_runs` rows (about 2 MB). Run these on a test install, not the one your
real workflows live on.

## PurpleFlow

Copy `stress/` and `diamonds/` into your workflows folder. Then either call
their webhooks:

```sh
curl -X POST localhost:4000/hooks/stress -H 'content-type: application/json' \
  -d '{"count": 10000, "sleep_ms": 1000}'     # replies at once with the run ID
curl -X POST localhost:4000/hooks/diamonds -H 'content-type: application/json' -d '{}'
```

or, from a checkout with the app's environment, run the harness scripts,
which also sample memory and count the results:

```sh
COUNT=10000 SLEEP_MS=1000 mix run samples/testing/harness/pf_stress.exs
mix run samples/testing/harness/pf_diamonds.exs
```

How many scripts can run at once depends on two limits in
`docker-compose.yml`: the runner's `mem_limit` (about 30 KB per script
running at once, so 512 MB holds a bit over 10,000) and `nofile` (one open
file per script running at once, in the app and in the runner).

## n8n

Needs Docker, and `sudo` for reading n8n's SQLite database.

```sh
cd samples/testing/harness
./n8n_setup.sh                                  # imports and publishes the four workflows
./n8n_run.sh 512m stress '{"count": 100, "sleep_ms": 1000}'
./n8n_run.sh 2g stress '{"count": 100, "sleep_ms": 1000}' --max-old-space-size=1536
./n8n_run.sh 2g diamonds '{}' --max-old-space-size=1536
./n8n_run.sh 2g diamonds-continue '{}' --max-old-space-size=1536
```

The fourth argument becomes `NODE_OPTIONS`. `--max-old-space-size` is the
heap setting n8n's docs recommend for containers; without it, Node.js picks
about half the container's memory.

n8n runs work in parallel by calling itself: the `stress` workflow's HTTP
Request node posts each item to the `stress worker` workflow's webhook, and
every call is its own execution. That's the usual way to get concurrent
nodes in n8n.
