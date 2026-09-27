---
name: purpleflow-workflows
description: Create, edit, check, run, and debug PurpleFlow workflows (TOML workflow files, node files, Code node .exs scripts, triggers, credentials). Use whenever you're asked to build or change a workflow, add a step or node, wire up a webhook or cron trigger, or figure out why a run failed.
---

# PurpleFlow workflows

PurpleFlow is a barebones n8n on Elixir. A workflow is a folder of plain files in `workflows/`. A trigger starts a **run**. Every **step** has a queue; items flow through the steps one at a time, and each step runs its **node** once per item: one item in, one output out. Every execution is saved and shows up in the UI.

The full design is in `specs/`. This sheet covers what you need day to day.

## The files

```
workflows/
  sync_records/
    workflow.toml     # triggers + the list of steps
    fetch.toml        # one node file per node
    is_big.toml
    is_big.exs        # Code nodes point at an .exs script
```

The folder name doesn't matter; `[workflow] name` does. Node files can be shared: `node = "../shared/slack.toml"`. Every `node` and `file` path must stay inside the workflows folder: no absolute paths, no `..` that climbs out of it, and only relative symlinks. A path that leaves it fails to load.

### Where the files live, and how to edit them

The workflows folder is its own git repo, separate from the app. Nobody commits for you; commit when a change works, if you're managing its history.

- **On a Docker install**, edit it through the files service (dufs), which the app serves at `/fs/`, with `Authorization: Bearer <PURPLEFLOW_AGENT_TOKEN>` (the user gives you the token; the same one checks your changes, below). You never need the app's checkout or the admin login. People see the same files at `/files` in the UI.

  ```sh
  F() { curl -s -H "Authorization: Bearer $AGENT_TOKEN" "http://localhost:4000/fs$1" "${@:2}"; }
  F /?json                                   # list workflow folders
  F /sync_records/workflow.toml              # read a file
  F /sync_records/fetch.toml -T fetch.toml   # write one (PUT; makes folders as needed)
  F /sync_records/old.toml -X DELETE         # delete one
  ```

  WebDAV works too (`MKCOL`, `MOVE` with a `Destination` header), so tools like rclone can mount `http://localhost:4000/fs/` with the token as a bearer token.
- **In a dev checkout** (`mix phx.server`), it's just `workflows/` in the repo; edit the files directly.

### workflow.toml

```toml
[workflow]
name = "sync_records"          # unique

[trigger.webhook]              # optional
path = "sync-records"          # POST/GET /hooks/sync-records
respond = "result"             # default: reply with the run's output. "immediately" = reply 202 + run_id.
                               # "stream" = server-sent events: each last-step item as it's made, then `end`
auth = "SYNC_HOOK_TOKEN"       # optional: callers must send `Authorization: Bearer <credential value>`, else 401
auth_header = "x-telegram-bot-api-secret-token"  # optional, needs auth: read the bare token from this header instead

[trigger.cron]                 # optional
schedule = "0 * * * *"

[[steps]]
name = "fetch"                 # unique in this workflow
node = "fetch.toml"            # relative to this file

[[steps]]
name = "save_big"
node = "save.toml"
after = ["is_big"]             # what feeds this step. No `after` = gets the trigger input
when = "big"                   # only takes items on this route. Needs exactly one `after`
concurrency = 5                # most running at once, across the run. Default 1000; 1 = one at a time, in order
delay = 100                    # ms between starts, across the run. Default 0
timeout = 30                   # seconds per execution. Default 0 = no limit
max_queue = 50                 # most items waiting in this step's queue. Default: no limit
on_full = "wait"               # with max_queue: "wait" (default) holds back the steps feeding it; "overflow" sends extras down the `overflow` route
on_fail = "continue"           # default: a failed item stops there. "end_run" = one failure ends the run
```

`run = "each"/"all"` and `concurrency = "sequential"/"concurrent"` are gone; they fail to load with a message saying what to use.

### Node file

```toml
module = "PurpleFlow.Nodes.Http"

[config]
url = "https://api.example.com/items?since={{ input.since }}"
headers = { authorization = "Bearer {{ creds.API_TOKEN }}" }
```

## How data moves

See `specs/120_flow.md` for the whole story.

- **One item, one execution.** A node always gets exactly one item as its input.
- **A list splits.** A node that returns a list hands on each element as its own item. 10 items that each return 5 results make 50 executions of the next step. An empty list hands on nothing.
- **Anything else is one item**, including `{"rows": [...]}`. Wrapping a list in an object is how a group travels as one. The Batch node does it for you.
- **Every step has a queue**, and items don't wait for the rest of their step: each moves on as soon as it's done. So items reach the next step in the order they finish, not the order they started. `concurrency = 1` keeps queue order.
- **Failures are per item.** A failed execution stops that item and saves an `error`/`timed_out` record; the run carries on and ends `complete`. Steps with `when = "failed"` get `{"error": "...", "input": <item>}`. `on_fail = "end_run"` on the step makes one failure end the run as `failed` (running executions finish; nothing new starts).
- **Branches:** a node returns `{:ok, output, "route"}`, and steps with `when = "route"` get those items. A step without `when` gets every item except `failed`/`overflow` ones.
- **Branches meeting again:** a step with several `after` steps gets items from all of them, one execution per item.
- **The run's output** comes from the last steps (nothing after them): a step that ran once gives its output; more than once, all its items as a list, in start order. Several last steps: `%{"step" => output}`.
- **Streaming:** a node can hand items on while still running (`PurpleFlow.Node.emit/2`); the HTTP node does with `stream = "sse" | "ndjson" | "lines"`, the SSH node with `stream = "lines" | "ndjson"`. See `specs/150_streaming.md` and `specs/170_ssh.md`.
- There's no item cap and no default timeout. A stuck run is stopped with Kill on its page, or `PurpleFlow.kill(run_id)`.

## Design guidelines

It's a power tool; it does what the workflow says. When you design one, think about:

- **Queues.** A slow step after a fast one builds a queue. Pace it with `concurrency` and `delay` (both across the whole run: `delay = 100` is at most 10 starts a second). Cap it with `max_queue`, then choose: `on_full = "wait"` slows the steps feeding it; `"overflow"` sends extras to a `when = "overflow"` step.
- **Grouping.** Put a Batch step before bulk inserts, summaries, and APIs that take many records per call.
- **Fan-out.** Nothing caps how many items a step makes. 1,000 × 1,000 is a million executions.
- **Failures.** Decide per step: carry on (default), handle on a `failed` route, or `end_run`.
- **Timeouts.** None by default. Set one on steps that can hang.
- **Order.** Items finish in any order; use `concurrency = 1` where order matters.
- **Recursion.** A workflow may run itself through the Workflow node. Make sure it stops.

## Templates (in any `[config]` string)

| Placeholder | Means |
|---|---|
| `{{ input.user.id }}` | from this node's input (`input.items.0` for list positions) |
| `{{ steps.fetch.output.total }}` | from the item an **ancestor** step produced on the way to this item (if `fetch` returned a list, the element that led here). Only ancestors, never sibling branches |
| `{{ creds.API_TOKEN }}` | a credential |

If a string is only one placeholder, the raw value is used (numbers, lists, and maps stay as they are). A missing path fails the step.

## Credentials: never in TOML, never yours to set

- Reference a credential by name: `{{ creds.NAME }}`. That's the only interaction a workflow file has with one.
- You can't create a credential, see its value, or set it — there's no file to edit and no command for it. A human sets values at `/credentials`, directly, outside of anything you do.
- If a workflow uses a `creds.NAME` that isn't set, it fails to load with a clear message. Tell whoever you're working with the name it needs, so they can set it at `/credentials` — that's the whole handoff.
- Values are redacted as `[redacted]` in every saved record automatically.

## Built-in nodes

| module | config | output |
|---|---|---|
| `PurpleFlow.Nodes.Http` | `url`, `method` (GET), `headers`, `query`, `body` (maps are sent as JSON), `stream` (`"sse"`, `"ndjson"`, `"lines"`) | response body. Non-2xx is an error. No retries. With `stream`: one item per event/line as it arrives (SSE: `{"event", "data", "id"}`), and returns `[]` |
| `PurpleFlow.Nodes.Ssh` | `host`, `port` (22), `user`, `password` or `private_key`, `host_key` (optional `SHA256:...` fingerprint), `command`, `stdin`, `connect_timeout` (seconds, 30; 0 = no limit), `stream` (`"lines"`, `"ndjson"`) | `{"stdout", "stderr", "exit_status"}`. Non-zero exit is an error. With `stream`: one item per stdout line as it arrives, and returns `[]` |
| `PurpleFlow.Nodes.Postgres` | `database_url`, `query`, `params` | list of row maps, so the next step runs per row |
| `PurpleFlow.Nodes.Code` | `file` (an `.exs` next to the node file) | whatever the script returns |
| `PurpleFlow.Nodes.Batch` | `size`, `wait` (ms, optional) | `{"items": [...]}`, one per batch. The last partial batch goes when nothing more can reach it |
| `PurpleFlow.Nodes.Workflow` | `workflow` (name) | that workflow's output. Waits for it |

**SSH:** keys and passwords come from credentials (`private_key = "{{ creds.DEPLOY_SSH_KEY }}"`). Set `host_key` to the server's fingerprint so a different server is refused; without it any key is accepted. `command` takes templates like anything else, so one step can run any command the workflow builds; it runs in the server's shell, templates and all.

**Postgres:** values always go in `params` as `$1`, `$2`, …, never pasted into `query`. Params arrive as text or numbers, so cast in SQL when needed: `$1::text::timestamptz`.

**Code scripts** get `input` and `steps` (`steps["fetch"]["output"]`). Return `{:ok, value}`, `{:ok, value, "route"}`, `{:error, "why"}`, or just a plain value. Maps use **string keys**: `input["amount"]`, not `input.amount`. Scripts run in an isolated runner with no network, no credentials, and no environment variables: fetch with an HTTP step and hand the result to the script through `input`/`steps`. What a script returns must be JSON-shaped.

```elixir
# is_big.exs
if input["amount"] > 1000, do: {:ok, input, "big"}, else: {:ok, input, "small"}
```

Outputs must be JSON-shaped: maps, lists, strings, numbers, booleans, nil.

## Gotchas

- **Webhook input is wrapped**: `%{"body" => ..., "query" => ..., "headers" => ...}`. Most webhook workflows start with a tiny Code step that returns `input["body"]` (see `samples/hello/numbers.exs`).
- Webhook calls wait for the result by default. For runs that can take longer than ~100s (Cloudflare's limit), use `respond = "immediately"` or `respond = "stream"`.
- A list output from an HTTP or Postgres node makes the next step run per item. That's usually what you want. If not, wrap it in an object in a Code step, or gather items with a Batch step.
- A run with failed items still ends `complete`. Look at the steps' ok / total on its page, or the `step_runs` statuses.
- **Edits load on their own**, about two seconds after the last save. There's no reload step. If an edit breaks a workflow, **its previous version keeps running**, so a webhook that still answers doesn't prove your change loaded. Check (below).
- The UI's Run button makes a real run. HTTP and Postgres steps really call out. Its box takes just the **body**: the run's input is `{"body": <what you typed>, "query": {}, "headers": {}}`, the same shape as a webhook's, so one workflow works from both.

## Check that a change loaded

Save, then ask the app. `GET /api/workflows` needs `Authorization: Bearer <PURPLEFLOW_AGENT_TOKEN>` (the user gives you the token; without one configured, the route is a 404):

```sh
curl -s -H "Authorization: Bearer $AGENT_TOKEN" localhost:4000/api/workflows
```

```json
{"reloaded_at": "...",
 "workflows": [{"name": "sync_records", "folder": "sync_records", "webhook": "sync-records", "cron": null,
                "loaded_at": "...", "problems": [], "running_older_version": false}],
 "not_loaded": [{"folder": "draft", "problems": ["step \"fetch\": can't read draft/fetch.toml"]}]}
```

Poll it until `reloaded_at` is later than your last save (about two seconds). Then your workflow should be in `workflows` with `problems: []` and `running_older_version: false`. If it's `running_older_version: true`, the problems say what's wrong with your edit, and the old version is what's answering. A brand-new workflow that fails shows up under `not_loaded`.

Loading catches bad TOML, missing files, paths that leave the workflows folder, unknown modules, unknown `after` names, loops, `when` misuse, unset credentials, references to non-ancestors, and Code script syntax errors. Without a token, the same problems show on the UI's home page.

## Run and inspect

- **Webhook:** `curl -X POST localhost:4000/hooks/<path> -H 'content-type: application/json' -d '<json>'`. The reply is the output. The run ID is in the `x-run-id` header.
- **UI:** `localhost:4000`, then the workflow's Run box, then the run page. Each step shows ok / total executions and, while running, its queue and running / concurrency. Click a step to see its input and output; a step that ran more than once expands into one row per execution. A running run has a Kill button.
- **Database** (dev db `purple_flow_dev`): `runs` has one row per run (`status`: `running`, `complete`, `failed`, `killed`, `interrupted`; `input`, `output`, `error`). `step_runs` has one row per node execution (`step`, `item` = the step's execution number, `from_item` = the execution before it that made its input, `status` = `ok`, `error`, `timed_out`, `killed`, or `overflow`, `route`, `input`, `output`, `error`). Rows are saved in batches every 250 ms.
- **A failed run's `error`** says which step and execution ended it (`on_fail = "end_run"`) and why.

## A new node type

Only when HTTP, SSH, Postgres, and Code really can't do it. Add a module under `lib/purple_flow/nodes/`:

```elixir
defmodule PurpleFlow.Nodes.Slack do
  @moduledoc "Posts a message to Slack. Config: `webhook_url`, `text`."
  @behaviour PurpleFlow.Node

  @impl true
  def execute(_input, config) do
    case Req.post(config["webhook_url"], json: %{text: config["text"]}, retry: false) do
      {:ok, %{status: 200}} -> {:ok, %{"sent" => true}}
      {:ok, %{status: status}} -> {:error, "Slack said #{status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
```

- Config arrives with templates already filled in.
- Optional: `execute/3` also gets `steps`, and `prepare/3` (`config, node_dir, root`) checks config when the workflow loads. To stream, call `PurpleFlow.Node.emit(item)` while running and return `{:ok, []}` at the end. A file named in config is resolved with `PurpleFlow.Workflow.Paths.resolve/3`, so it can't leave the workflows folder.
- Keep docs short and plain. Add a test that calls `execute/2` directly, then run `mix precommit`.
