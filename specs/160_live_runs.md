# 160 — Live runs

Status: draft
Created: 2026-09-27

With items flowing through queues ([120](120_flow.md)), the run page shows each step as a small machine: what's waiting, what's running, what came out. And a run that's gone wrong can be stopped.

## Each step on the run page

Every step's row shows:

| Shown | Meaning |
|---|---|
| **queue** | items waiting in its queue (or in its batch, for a Batch step). Only while the run is going |
| **running / concurrency** | executions running now, out of its `concurrency`. Only while the run is going |
| **ok / total** | executions that succeeded, out of all its executions this run. Overflowed items are counted apart, as `3 overflowed` |

The step's dot:

- **green**: every execution succeeded
- **yellow**: some succeeded and some didn't (failed, timed out, killed, or overflowed)
- **red**: none succeeded, or this step's failure ended the run (`on_fail = "end_run"`, [130](130_failures.md))
- **blue, pulsing**: it has something queued or running
- **gray**: didn't run

A step that ran more than once expands into one row per execution, as before; one that ran once expands straight to its input and output.

The page updates from the run's `run_progress` messages, which come at most every 250 milliseconds. The counters come straight from the message; the rows are reloaded from the database at the same pace, never faster.

The run's own status badge also knows `killed` (gray) alongside `running`, `complete`, `failed`, and `interrupted`. A killed run says so where a failed run shows its error.

## Kill

A running run has a **Kill** button on its run page and on its row in the workflow's runs list. It asks to confirm, then calls `PurpleFlow.kill/1` ([130](130_failures.md)). A run that already finished has no button.

The workflow's runs list is where to find what's running now: running runs show their status live, with the Kill button, and the list updates as runs start and finish.

## Tests

- a step's row shows ok / total and the right dot color for all-ok, some-failed, and none-ok
- counters come from `run_progress` while the run is going
- the Kill button on the run page and the runs list kills the run, and isn't there once it's finished
