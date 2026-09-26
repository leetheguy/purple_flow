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
auth = "SYNC_HOOK_TOKEN"   # optional; the name of a credential, see 080
auth_header = "x-telegram-bot-api-secret-token"   # optional; default "authorization"
```

- One catch-all route, `/hooks/*path` (GET and POST), looks the path up in `PurpleFlow.Workflows`.
- Input: `%{"body" => ..., "query" => ..., "headers" => ...}`. The first step usually wants `input["body"]`.
- The caller's `authorization`, `proxy-authorization`, and `cookie` headers are dropped, so they're never saved.
- **`respond = "result"` (default):** the reply waits for the run. `200` with the run's output as JSON, or `500 {"error", "run_id"}` if it failed.
- **`respond = "immediately"`:** replies right away with `202 {"run_id": "..."}`. Use it for workflows that can take longer than ~100 seconds, since Cloudflare gives up on requests after that.
- The run ID is always in the `x-run-id` response header. An unknown path gets a 404.

### Auth

- **No `auth`, or `auth = ""` (default):** the webhook is open. Anyone who knows the path can trigger it.
- **`auth = "NAME"`:** the caller must send `Authorization: Bearer <value>`, where `<value>` is the credential `NAME`'s value (set at `/credentials`, see [080](080_credentials.md)). The comparison is constant-time.
- **`auth_header`:** for callers that send their secret in a header of their own (Telegram sends `X-Telegram-Bot-Api-Secret-Token`), name that header here, case-insensitively. Its whole value must equal the credential's value, with no `Bearer ` prefix. Without `auth_header`, the default is `Authorization: Bearer <value>`. `auth_header` without `auth` fails the workflow's checks at load time.
- A missing or wrong token gets `401` with no body, and no run is started or recorded.
- At load time, `auth` naming a credential that isn't set fails the workflow's checks, the same as an unset `{{ creds.NAME }}`. If the credential is later archived or cleared, requests get `401`: a webhook with `auth` never falls back to open.
- The token's header is dropped from the run's input, like `authorization` always is, so the token is never saved.

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
- **Webhook auth:** with `auth` set, the right token starts a run; a missing or wrong token gets `401` and records no run; an archived credential gets `401`; without `auth`, no token is needed; `auth` naming an unset credential fails at load time; with `auth_header`, the token is read from that header (any case, no `Bearer ` prefix) and that header never appears in the run's input; `auth_header` without `auth` fails at load time.
- **Cron:** assert that loading a workflow registers the right Quantum job. Don't test Quantum itself.
- **Manual:** call `PurpleFlow.run/2`.
