# Case study: PurpleFlow vs n8n under pressure

Two tests, run on both: many things at once, and a workflow full of
failures. Every number below comes from a test in the [test log](#test-log),
cited by its ID. The workflows and scripts are in
[`samples/testing/`](../samples/testing/), so anyone can run them again.

Run on 2026-09-27 against PurpleFlow at this commit and n8n 2.40.7 (the
latest release that day).

## Summary

| Axis | PurpleFlow | n8n | Tests |
|---|---|---|---|
| **Concurrency**: most executions at once that finished | **10,000** with a 512 MB runner | **100**, and only with 2 GB. Fewer than 100 at 512 MB and 1 GB; 1,000 failed at 4 GB | PF-S6, N-S1–N-S7 |
| **Memory**: per execution running at once | **~25–30 KB** | **~7 MB** | PF-S6, PF-P1, N-S5 |
| **Memory**: idle | **~90 MB** app + **~65 MB** runner | **400–760 MB** | PF-S6, N-S1–N-S7 |
| **Speed**: one-second jobs finished per second | **~3,100** (10,000 in 3.1–3.2 s) | **~12–16** (100 in 6.1–8.5 s) | PF-S6, PF-S7, N-S5, N-S6 |
| **Resilience**: 100 failures in one run | Run **completes**, output correct, in **0.5–0.6 s** | Run **stops** at the first failure; with "continue on error", **crashes** after 208 s | PF-D2, N-D1, N-D2 |
| **Graph size**: 100 branch-and-merge pairs | Loads and runs (after a fix this testing found) | Call stack overflow around the 18th | PF-D1, PF-D2, N-D2 |
| **Saved run data**: the 100-diamond run | **45 KB** (301 rows) | **74 MB** for a run that died at diamond 18 | PF-D2, N-D2 |
| **Startup**: at 512 MB, untuned | Starts | Ran out of heap while starting, once in two tries | N-S2 |

## How the tests were run

- **Machine:** one cloud VM, 4 CPUs, 15 GB RAM, Docker 29.3.1, open-file
  limit raised to 20,000 for the containers.
- **PurpleFlow:** the app and the Code runner in separate containers, like
  `docker-compose.yml`. The runner capped at 512 MB, 1 CPU, 256 processes
  (the compose values); the app uncapped, its memory measured. Postgres 16.
  Built from source and started with `mix run` in the dev environment
  (plain Elixir 1.20.2, OTP 29), not the release image: the VM couldn't
  build the image through its network proxy.
- **n8n:** the official `n8nio/n8n:2.40.7` image in one container, regular
  (non-queue) mode, its default SQLite database, CPU uncapped, memory capped
  as each test says. "Tuned" means `NODE_OPTIONS=--max-old-space-size` set
  to about 75% of the cap, as n8n's docs recommend for containers.
- **Memory** is Docker's reading for the container (sampled every 0.5 s),
  or the Erlang VM's own total where it says "VM".
- **Each test ran once** unless a repeat is listed. Treat small differences
  as noise; the gaps in this study are 10× to 1,000×.

### The stress test

`samples/testing/stress/`: one run makes N items, and every item runs a
job that waits one second and returns. A good engine finishes N of them in
about one second, however large N is.

- **PurpleFlow:** a Code step returns N items; the next step, a Code step
  with `concurrency = 10000`, runs `:timer.sleep(1000)` per item; a Batch
  step gathers them and a last Code step counts them.
- **n8n:** an n8n workflow runs work in parallel by calling itself. A Code
  node makes N items, and an HTTP Request node posts each one to a second
  workflow's webhook (Webhook → Wait 1 s → Set). The HTTP Request node sends
  all N calls at once, so each becomes its own execution, running at the
  same time. A Code node counts the replies.

### The diamonds test

`samples/testing/diamonds/`: 100 "diamonds" in a row. Each branches into a
step that always fails and a step that adds 1 to `survived`, and then
merges the two. A workflow that routes around failures ends with
`{"survived": 100}`.

- **PurpleFlow:** Code steps: the failing one returns `{:error, "boom"}`,
  and the merge step lists both branches in `after`. No settings needed: a
  failure stops only its own item.
- **n8n:** Stop and Error nodes fail, Set nodes count, Merge nodes (append)
  merge. Run twice: with defaults, and with every Stop and Error node set to
  **On Error → Continue (using error output)**, n8n's way to keep going past
  a failure.

## Concurrency

PurpleFlow ran **10,000** one-second jobs at once: all 10,000 were running
by the first second (10,168–10,271 processes in the VM), and every one
finished `ok` (PF-S6, PF-S7).

n8n couldn't run **100** at once in 512 MB, tuned or not: the kernel killed
it for running out of memory 2.3–2.7 s in, with 33–52 executions running
and the rest never started (N-S1, N-S3). At 1 GB it started all 100 and
was killed about 5 s later (N-S4). At 2 GB, 100 finished (N-S5, N-S6). At
4 GB, **1,000** did not: killed after 23.6 s with 82 finished (N-S7).

## Memory

**Per execution running at once.** PurpleFlow's runner went from ~65 MB
idle to ~354 MB with 10,000 scripts running, about **29 KB each**; the
app's VM grew about 24 KB per item (PF-S6). A probe of 2,000 sleeping
scripts in one VM measured 24 KB each, both ends included (PF-P1). n8n went
from ~685 MB to ~1.37 GB for 100 executions: about **7 MB each**, over
**200×** as much (N-S5).

**Idle.** PurpleFlow's app VM idled at ~90 MB and the runner at ~65 MB
(PF-S6). n8n idled at 401 MB in a 512 MB container, and 472–762 MB with the
heap tuned and more memory to use (N-S1, N-S3–N-S7). n8n's figure includes
its internal Code task runner.

## Speed

Both tests use one-second jobs, so the ideal is about one second for the
whole batch.

- PurpleFlow: **10,000 in 3.1–3.2 s**, the last job finishing 1.86 s after
  the first (PF-S6, PF-S7). About 3,100 jobs a second.
- n8n: **100 in 6.1–8.5 s**, the last finishing 4.0–5.5 s after the first
  (N-S5, N-S6). About 12–16 jobs a second, and the only size it finished.

## Resilience

PurpleFlow ran all 100 diamonds and replied `{"survived": 100}` in
0.49–0.62 s. The run ended `complete`; its page shows the 100 failures as
`error` rows next to 201 `ok` ones (PF-D2).

n8n, by default, stopped the whole execution at the first failing node,
diamond 1 of 100, and the webhook replied `500 {"message": "Error in
workflow"}` in 0.35 s (N-D1). With continue-on-error set on all 100
failing nodes, it ran for **208 s** and then died with **`RangeError:
Maximum call stack size exceeded`**, having reached about diamond 18, using
1.16 GB, with 74 MB of execution data saved for the one run (N-D2). The
process stayed up both times; the run never finished.

## Graph size

Branches that merge again double the number of paths through a workflow:
100 diamonds make 2^100 paths from start to end. Anything that walks
paths one by one never finishes.

- PurpleFlow had this bug at **load** time: its loop check walked every
  path, so the diamonds workflow never loaded (PF-D1). It now checks each
  step once, and a test loads 100 diamonds in well under a second.
- n8n appears to have it at **run** time. The stack overflow came around
  the 18th diamond (N-D2), which fits following item history back through
  both branches of every merge. That cause is a guess; n8n's code wasn't
  examined.

## Saved run data

Both save every run. PurpleFlow saved **45 KB** for the whole 100-diamond
run (301 rows) and **2 MB** for the 10,000-item stress run (PF-D2, PF-S6).
n8n saved **74 MB** for one diamonds run that got about 18 diamonds in
(N-D2).

## Startup

Untuned, in 512 MB, n8n once failed to start at all: Node.js gave it a heap
of about 258 MB, and n8n used it up while starting (`FATAL ERROR:
Ineffective mark-compacts near heap limit`) (N-S2). The other untuned start
worked (N-S1). Tuned, it started every time.

## What the tests found in PurpleFlow

PurpleFlow failed these tests before it passed them. Its first stress run
finished 791 of 10,000 (PF-S1). Five bugs, all fixed on this branch:

1. **Too few open files.** Docker gives containers 1,024 by default, and
   each Code step running at once holds a connection. Compose now sets
   65,536 for the app and the runner (PF-S1).
2. **A listen queue of 5.** The runner used the kernel's default backlog, so
   a burst of connections was mostly dropped and retried after 1, 3, 7...
   seconds: 100 one-second jobs took 31.5 s. Now 4,096: 0.44 s (PF-S2,
   PF-S3).
3. **The runner crashed when out of files**, dropping every waiting
   connection. It now waits and tries again (PF-S1).
4. **Cleanup that scanned every process per script.** Killing what a
   finished script left running meant a pass over all ~30,000 processes for
   each of 10,000 scripts, and the runner ran out of memory even at 1.5 GB.
   One sweep now covers every script finished in the last 100 ms (PF-S4,
   PF-S5, PF-S6).
5. **The exponential loop check** in the loader (PF-D1, PF-D2).

## Caveats

- **Different units of work.** Each n8n branch in the stress test is a
  whole workflow execution, with its own saved record; a PurpleFlow
  execution is one step. But calling another workflow is how n8n runs
  nodes in parallel, so it's the fair comparison for concurrency.
- **n8n has other options, not tested here.** A single Code node can run
  100 promises at once (concurrency inside one node, not concurrent nodes).
  Queue mode spreads executions over worker containers, with Redis and more
  machines.
- **Different node types.** PurpleFlow's tests used Code steps, which run
  in a separate container over a network connection. n8n's used built-in
  nodes (Wait, Set, Stop and Error, Merge) that don't need its Code runner.
  If anything, that favours n8n.
- **Databases.** PurpleFlow used Postgres; n8n used its default SQLite.
- **PurpleFlow in dev mode.** Started with `mix run`, not the release, so
  its idle memory includes the compiler and dev tools.
- **n8n phoned home.** It kept trying to reach n8n's servers through the
  VM's proxy and failing. That may have cost it a little memory.
- **One machine, mostly one run each.** Repeats (PF-S7, PF-D2, N-S6) agreed
  with the first runs.

## Test log

| ID | Test | Setup | Result |
|---|---|---|---|
| PF-S1 | stress, 10,000 × 1 s | PurpleFlow before the fixes; 1,024 open files | 791 ok, 9,209 failed ("too many open files", "lost the Code runner"); 217 s |
| PF-S2 | stress, 100 × 1 s | open files raised; listen backlog still 5 | 100 ok in 31.5 s; the kernel counted 5,572 dropped connections |
| PF-S3 | stress, 100 × 1 s | backlog 4,096 | 100 ok in 0.44 s, finishing within 71 ms of each other |
| PF-S4 | stress, 10,000 × 1 s | runner 512 MB, per-script cleanup scan | 2,269 ok; runner killed, out of memory; 10.5 s |
| PF-S5 | stress, 10,000 × 1 s | runner 1.5 GB, per-script cleanup scan | 6,338 ok; runner killed, out of memory at 1.47 GB |
| PF-S6 | stress, 10,000 × 1 s | all fixes; runner 512 MB | **10,000 ok in 3.2 s**; spread 1.86 s; app VM peak 334 MB (idle 90 MB); runner peak 354 MB (idle 65 MB); 2 MB of rows |
| PF-S7 | stress, 10,000 × 1 s | repeat of PF-S6 | 10,000 ok in 3.1 s; spread 1.86 s; app VM peak 339 MB |
| PF-P1 | 2,000 sleeping scripts | runner inside the app's VM | +47 MB total: 24 KB per script, both ends |
| PF-D1 | diamonds | before the loader fix | never loaded (the loop check walks 2^100 paths) |
| PF-D2 | diamonds | after the fix | `{"survived": 100}`, run `complete`, 100 `error` + 201 `ok` rows (45 KB); 0.62 s, repeat 0.49 s |
| N-S1 | stress, 100 × 1 s | 512 MB, untuned | idle 401 MB; killed, out of memory, at 2.7 s (436 MB resident); 52 running, 48 never started |
| N-S2 | (startup) | 512 MB, untuned | out of heap while starting (limit ~258 MB) |
| N-S3 | stress, 100 × 1 s | 512 MB, heap 384 MB | idle 472 MB; killed at 2.3 s; 33 running, 67 never started |
| N-S4 | stress, 100 × 1 s | 1 GB, heap 768 MB | idle 524 MB; killed at ~5 s (peak ≥874 MB); 100 running, none finished |
| N-S5 | stress, 100 × 1 s | 2 GB, heap 1,536 MB | idle 685 MB; **100 ok in 8.5 s**; spread 5.5 s; peak 1.37 GB |
| N-S6 | stress, 100 × 1 s | repeat of N-S5 | idle 762 MB; 100 ok in 6.1 s; spread 4.0 s; peak 1.36 GB |
| N-S7 | stress, 1,000 × 1 s | 4 GB, heap 3,072 MB | idle 675 MB; killed at 23.6 s (peak 3.73 GB); 82 ok, 918 running |
| N-D1 | diamonds | 2 GB, heap 1,536 MB, defaults | `500 Error in workflow` in 0.35 s; stopped at the first failing node |
| N-D2 | diamonds, continue on error | 2 GB, heap 1,536 MB | `500` after 208.6 s: `RangeError: Maximum call stack size exceeded` around diamond 18; 1.16 GB; 74 MB saved |

## Running it yourself

See [`samples/testing/README.md`](../samples/testing/README.md).
