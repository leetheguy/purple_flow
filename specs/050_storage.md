# 050 — Storage

Status: implemented
Created: 2026-09-25

Postgres through Ecto. There are two tables. Records are written as things happen, not at the end, so a crash never loses what already ran.

## `runs`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | the UUIDv7 run ID |
| `workflow` | text | |
| `trigger` | text | `webhook`, `cron`, `manual`, `workflow` |
| `status` | text | `running`, `complete`, `failed`, `interrupted` |
| `input` | jsonb | trigger input |
| `output` | jsonb | run output, when complete |
| `error` | jsonb | when failed |
| `started_at`, `finished_at` | utc_datetime_usec | |

The run process writes this row: it inserts it at start and updates it at the end.

## `step_runs`

One row per node execution. A step that ran over 10 items has 10 rows.

| Column | Type | Notes |
|---|---|---|
| `id` | bigserial | |
| `run_id` | uuid | |
| `step` | text | step name |
| `item` | integer | `nil` for single executions, item position for per-item |
| `from_item` | integer | which item of the previous step this one came from |
| `status` | text | `ok`, `error`, `timed_out` |
| `route` | text | if the node returned one |
| `input` | jsonb | |
| `output` | jsonb | |
| `error` | jsonb | |
| `started_at`, `finished_at` | utc_datetime_usec | |

Credential values are redacted before any row is written (see [010](010_workflows.md)).

Each node's task writes its own row when it finishes, errors, or times out.

Steps that didn't run have no rows.

## Functions

- `PurpleFlow.Runs.list(workflow, limit: 50)`: newest first
- `PurpleFlow.Runs.get(run_id)`: the run row plus all of its step rows

## Tests

Write rows and read them back. Check that JSON round-trips unchanged.

## Log
- 2026-09-27 — [120](120_flow.md), [130](130_failures.md): **`runs`**: `status` can also be `killed`. **`step_runs`**: `item` is always set, numbering the step's executions in the order they started (0, 1, 2, …); `from_item` is the execution of the step before that made its input. `status` can also be `killed` or `overflow` (an item that didn't fit a full queue, [120](120_flow.md)). A streamed execution's `output` is every item it produced. **Writes**: tasks no longer write their own rows. The run process saves them, many per insert, at most every 250 ms and before it finishes. **Functions**: `PurpleFlow.Runs.save_steps(rows)` replaces `save_step/1`.
- 2026-09-27 — Open, from an audit against n8n's history: the bundled Postgres's `POSTGRES_USER` is a superuser, and a Postgres node given the app's own `DATABASE_URL` can reach it. Credentials there stay encrypted (the key is only in the app's environment), but a superuser can run commands in the `db` container (`COPY ... TO PROGRAM`), which does have internet access. Accepted as the operator's choice, like the password: a non-superuser role for the app would be an option, not a requirement.
