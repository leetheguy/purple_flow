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
