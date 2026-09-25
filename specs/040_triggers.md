# 040 — Triggers

Status: draft

Every trigger ends up calling the same function:

```elixir
PurpleFlow.run(workflow_name, input) :: {:ok, run_id} | {:error, reason}
```

It generates a UUIDv7, starts a `PurpleFlow.Run` under `RunSupervisor`, and returns right away without waiting for the run to finish.

## Webhook

```toml
[trigger.webhook]
path = "sync-records"
respond = "result"   # default; or "immediately"
```

- One catch-all route, `/hooks/*path` (GET and POST), looks the path up in `PurpleFlow.Workflows`.
- Input: `%{"body" => ..., "query" => ..., "headers" => ...}`. The first step usually wants `input["body"]`.
- The caller's `authorization`, `proxy-authorization`, and `cookie` headers are dropped, so they're never saved.
- **`respond = "result"` (default):** the reply waits for the run. `200` with the run's output as JSON, or `500 {"error", "run_id"}` if it failed.
- **`respond = "immediately"`:** replies right away with `202 {"run_id": "..."}`. Use it for workflows that can take longer than ~100 seconds, since Cloudflare gives up on requests after that.
- The run ID is always in the `x-run-id` response header. An unknown path gets a 404.

## Cron

```toml
[trigger.cron]
schedule = "0 * * * *"
```

- Registered as a Quantum job on load and reload.
- Input: `%{"scheduled_at" => iso8601}`.
- Overlapping runs are allowed.

## Manual

- `PurpleFlow.run/2` from IEx or a test.
- A "Run" button in the UI with a JSON input box ([060](060_ui.md)).

## Another workflow

This isn't a trigger. It's a node: `PurpleFlow.Nodes.Workflow` ([020](020_nodes.md)).

## Tests

- **Webhook:** hit the route and assert that a run started with the right input.
- **Cron:** assert that loading a workflow registers the right Quantum job. Don't test Quantum itself.
- **Manual:** call `PurpleFlow.run/2`.
