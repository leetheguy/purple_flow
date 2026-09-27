# 130 — Failures and stopping runs

Status: implemented
Created: 2026-09-27

A failed execution is one item that didn't make it. The rest of the run keeps going, like a phone network that loses one call and keeps carrying the others. The workflow decides what a failure means: carry on, handle it on a `failed` route, or end the whole run.

## What counts as a failure

An execution fails when its node returns `{:error, reason}`, raises, crashes, returns something that isn't JSON, a template in its config can't be filled, or it runs past its step's `timeout` ([120](120_flow.md)). Its record is saved with status `error` (or `timed_out`) and the message.

## `on_fail`

A step setting in `workflow.toml`:

- **`on_fail = "continue"` (default):** that item stops there. Everything else carries on.
- **`on_fail = "end_run"`:** the run ends. No new executions start anywhere, and items still in queues or batches are dropped. Executions already running are allowed to finish and are saved, but what they produce goes nowhere. The run is saved as `failed`, with the step, the execution's number, and the message as its error. Use it where one failure means the rest shouldn't happen, like an email blast that's started bouncing.

`end_run` means "stop starting", not "stop everything": with `concurrency = 20`, up to 19 other executions of that step may already be running, and they finish.

## The `failed` route

A failed execution sends one item down its step's `failed` route:

```json
{"error": "HTTP 503: try later", "input": <the item that failed>}
```

Steps with `after = ["that step"]` and `when = "failed"` get it, one execution per failure, like any route. It's how a workflow handles its own failures: log them, notify someone, try another API. A step with `when = "failed"` that fails itself doesn't route anywhere else; that failure is just recorded.

With `on_fail = "end_run"`, the run ends first, so nothing on the `failed` route runs.

## Run status

| Status | Meaning |
|---|---|
| `running` | still going |
| `complete` | ran out of work. Some items may have failed; the per-step counts say how many ([160](160_live_runs.md)) |
| `failed` | a step with `on_fail = "end_run"` failed, or the run process itself crashed |
| `killed` | someone pressed Kill |
| `interrupted` | the app stopped while it was running |

## Kill

`PurpleFlow.kill(run_id)`, or the Kill button on a running run ([160](160_live_runs.md)), stops a run now, as gracefully as it can:

1. nothing new starts, and queues and batches are dropped
2. every running execution is stopped, and saved with status `killed`
3. every row the run still holds is saved
4. the run is saved as `killed` and `run_finished` is broadcast

It's how you stop something that's hung, since `timeout` defaults to no limit. Killing a run doesn't kill workflows it started with the Workflow node; those are runs of their own, with their own Kill button.

## No resume

A run that was going when the app stopped is marked `interrupted` at the next boot, as before. It isn't resumed.

## Tests

- a failed item stops there and the others carry on; the run is `complete`
- `on_fail = "end_run"` fails the run, starts nothing new, and lets running executions finish
- the `failed` route gets the error and the input
- a crash, a raise, and a timeout each count as failures
- kill stops running executions, saves them as `killed`, and marks the run `killed`
