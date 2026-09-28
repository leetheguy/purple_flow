# 040 — Triggers

Status: implemented
Created: 2026-09-25

Every trigger ends up calling the same function:

```elixir
PurpleFlow.run(workflow_name, input) :: {:ok, run_id} | {:error, reason}
```

It generates a UUIDv7, starts a `PurpleFlow.Run` under `RunSupervisor`, and returns right away without waiting for the run to finish.

## Webhook

```toml
[trigger.webhook]
path = "sync-records"
```

- One catch-all route, `/hooks/*path` (GET and POST), looks the path up in `PurpleFlow.Workflows`.
- Input: `%{"body" => ..., "query" => ..., "headers" => ...}`. The first step usually wants `input["body"]`.
- The caller's `authorization`, `proxy-authorization`, and `cookie` headers are dropped, so they're never saved.
- Reply: `202 {"run_id": "..."}`. An unknown path gets a 404.

Replying with the run's result instead is a "later" item ([000](000_overview.md)).

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

## Log

- 2026-09-25 — **Webhook reply**: webhooks reply with the run's output by default, and replying with only the run ID is no longer a "later" item. `[trigger.webhook]` takes `respond`:
  - **`respond = "result"` (default):** the reply waits for the run. `200` with the run's output as JSON, or `500 {"error", "run_id"}` if it failed.
  - **`respond = "immediately"`:** replies right away with `202 {"run_id": "..."}`. Use it for workflows that can take longer than ~100 seconds, since Cloudflare gives up on requests after that.
  - The run ID is always in the `x-run-id` response header. An unknown path gets a 404.
- 2026-09-26 — **Webhook auth**: `[trigger.webhook]` takes `auth = "NAME"` (the name of a credential, see [080](080_credentials.md)) and `auth_header` (default `"authorization"`).
  - **No `auth`, or `auth = ""` (default):** the webhook is open. Anyone who knows the path can trigger it.
  - **`auth = "NAME"`:** the caller must send `Authorization: Bearer <value>`, where `<value>` is the credential `NAME`'s value. The comparison is constant-time.
  - **`auth_header`:** for callers that send their secret in a header of their own (Telegram sends `X-Telegram-Bot-Api-Secret-Token`), name that header here, case-insensitively. Its whole value must equal the credential's value, with no `Bearer ` prefix. `auth_header` without `auth` fails the workflow's checks at load time.
  - A missing or wrong token gets `401` with no body, and no run is started or recorded.
  - At load time, `auth` naming a credential that isn't set fails the workflow's checks, the same as an unset `{{ creds.NAME }}`. If the credential is later archived or cleared, requests get `401`: a webhook with `auth` never falls back to open.
  - The token's header is dropped from the run's input, like `authorization` always is, so the token is never saved.
  - Tests: with `auth` set, the right token starts a run; a missing or wrong token gets `401` and records no run; an archived credential gets `401`; without `auth`, no token is needed; `auth` naming an unset credential fails at load time; with `auth_header`, the token is read from that header (any case, no `Bearer ` prefix) and that header never appears in the run's input; `auth_header` without `auth` fails at load time.
- 2026-09-26 — **Manual input**: the UI's Run box takes just the body. The run's input is `%{"body" => <the JSON typed>, "query" => %{}, "headers" => %{}}`, the same shape as a webhook's, so a workflow reads `input["body"]` whichever way it was started. An empty box is `{}`. `PurpleFlow.run/2` itself still takes the input exactly as given.
- 2026-09-27 — [150](150_streaming.md): **Webhook reply**: `respond = "stream"` replies with a server-sent event stream: every item a last step produces, as it's produced, then an `end` event with the run's status. With `respond = "result"`, a run where some items failed still ends `complete` ([130](130_failures.md)), so the reply is `200` with whatever output it made; `500` is for runs that end `failed` (`on_fail = "end_run"`) or are killed.
- 2026-09-27 — **Cron**: the workflow files are the truth for cron jobs, and Quantum holds a copy. Every reload and every watch tick (once a second) compares the Scheduler's `workflow:*` jobs with the loaded workflows: it adds what's missing, replaces what changed, and removes what's gone. Before, a job was registered only when its schedule changed, so a Scheduler that restarted (or restarted a part of itself) lost its jobs silently until the next schedule change or boot. Found in an audit against n8n's history, where "the schedule trigger silently stopped firing" was a long-running problem.
- 2026-09-27 — Open, from the same audit, for later:
  - **Files sent to a webhook.** A multipart request carrying a file gets `500 {"error": "input isn't JSON"}`, because the upload can't be part of a run's JSON input. Taking files means deciding how binary data travels through a run (n8n keeps it apart from the JSON items). Workarounds for now: send a URL to fetch, or the file as base64 inside JSON.
  - **Missed cron firings.** A firing that falls while the app is down is skipped, not made up at the next boot. Catching up could be an option on `[trigger.cron]`.
- 2026-09-28 — [180](180_noop_wait_respond.md): **Webhook reply**: with `respond = "result"`, a Respond step (`PurpleFlow.Nodes.Respond`) can answer before the run ends, with its own status, headers, and body; the run carries on without the caller. The first Respond step to run answers; a run that ends before any does answers with its output, as before. With `"immediately"` and `"stream"`, Respond steps answer no one.
- 2026-09-28 — [190](190_run_files.md): **Files sent to a webhook** (open above) are taken. A multipart upload is saved with the run and the input holds a reference to it (`{"file", "name", "type", "size"}`); the file is deleted when the run ends. `[trigger.webhook]` takes `max_upload` (bytes, default 100 MB, `0` = no limit); a bigger request gets `413`.
