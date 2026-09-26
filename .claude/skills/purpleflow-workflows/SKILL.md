---
name: purpleflow-workflows
description: Create, edit, check, run, and debug PurpleFlow workflows (TOML workflow files, node files, Code node .exs scripts, triggers, credentials). Use whenever you're asked to build or change a workflow, add a step or node, wire up a webhook or cron trigger, or figure out why a run failed.
---

# PurpleFlow workflows

PurpleFlow is a barebones n8n on Elixir. A workflow is a folder of plain files in `workflows/`. A trigger starts a **run**. The run walks the **steps**, and each step runs a **node**: one input in, one output out. Every execution is saved and shows up in the UI.

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

The folder name doesn't matter; `[workflow] name` does. Node files can be shared: `node = "../shared/slack.toml"`.

### workflow.toml

```toml
[workflow]
name = "sync_records"          # unique

[trigger.webhook]              # optional
path = "sync-records"          # POST/GET /hooks/sync-records
respond = "result"             # default: reply with the run's output. "immediately" = reply 202 + run_id

[trigger.cron]                 # optional
schedule = "0 * * * *"

[[steps]]
name = "fetch"                 # unique in this workflow
node = "fetch.toml"            # relative to this file

[[steps]]
name = "save_big"
node = "save.toml"
after = ["is_big"]             # what feeds this step. No `after` = gets the trigger input
when = "big"                   # only runs on this route. Needs exactly one `after`
run = "each"                   # default. "all" = get the whole list in one execution
concurrency = "concurrent"     # default (1,000 at once). "sequential", or a number like 5
timeout = 30                   # seconds per execution, default 30
```

### Node file

```toml
module = "PurpleFlow.Nodes.Http"

[config]
url = "https://api.example.com/items?since={{ input.since }}"
headers = { authorization = "Bearer {{ creds.API_TOKEN }}" }
```

## How data moves

- A step's **input** is the output of its `after` step. First steps get the trigger input.
- **Lists run per item.** If the input is a list, the node runs once per item, in parallel, and the results come back as **one flat list**. 10 items that each return 5 results make 50 items, not 10 lists. Use `run = "all"` to get the whole list at once (bulk inserts, summaries, narrowing a list down).
- An empty list means zero executions. Steps after it get `[]` and run zero times too.
- Output caps at 10,000 items. More than that fails the run.
- **Branches:** a node returns `{:ok, output, "route"}`, and steps with `when = "route"` run. Per item, each item goes its own way. A branch nobody took simply doesn't run.
- **Branches meeting again:** a step with several `after` steps runs **each time** one of them finishes. After an if/else that's once. After two parallel branches that both ran, it's twice.
- **The run's output** is the output of the last step (the one nothing comes after). If several last steps ran, it's a map of `%{"step" => output}`.

## Templates (in any `[config]` string)

| Placeholder | Means |
|---|---|
| `{{ input.user.id }}` | from this node's input (`input.items.0` for list positions) |
| `{{ steps.fetch.output.total }}` | from an **ancestor** step's output (only ancestors, never sibling branches) |
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
| `PurpleFlow.Nodes.Http` | `url`, `method` (GET), `headers`, `query`, `body` (maps are sent as JSON) | response body. Non-2xx is an error. No retries |
| `PurpleFlow.Nodes.Postgres` | `database_url`, `query`, `params` | list of row maps, so the next step runs per row |
| `PurpleFlow.Nodes.Code` | `file` (an `.exs` next to the node file) | whatever the script returns |
| `PurpleFlow.Nodes.Workflow` | `workflow` (name) | that workflow's output. Waits for it |

**Postgres:** values always go in `params` as `$1`, `$2`, …, never pasted into `query`. Params arrive as text or numbers, so cast in SQL when needed: `$1::text::timestamptz`.

**Code scripts** get `input` and `steps` (`steps["fetch"]["output"]`). Return `{:ok, value}`, `{:ok, value, "route"}`, `{:error, "why"}`, or just a plain value. Maps use **string keys**: `input["amount"]`, not `input.amount`.

```elixir
# is_big.exs
if input["amount"] > 1000, do: {:ok, input, "big"}, else: {:ok, input, "small"}
```

Outputs must be JSON-shaped: maps, lists, strings, numbers, booleans, nil.

## Gotchas

- **Webhook input is wrapped**: `%{"body" => ..., "query" => ..., "headers" => ...}`. Most webhook workflows start with a tiny Code step that returns `input["body"]` (see `workflows/samples/hello/numbers.exs`).
- Webhook calls wait for the result by default. For runs that can take longer than ~100s (Cloudflare's limit), use `respond = "immediately"`.
- A list output from an HTTP or Postgres node makes the next step run per item. That's usually what you want. If not, use `run = "all"`.
- Workflows are loaded when the server starts. **After editing, reload**: the Reload button on the home page, or restart the server.
- The UI's Run button makes a real run. HTTP and Postgres steps really call out.

## Check a workflow before reloading

This loads every workflow and prints the problems, without starting the app (only its database connection, to check `creds.NAME` references are set):

```sh
mix run --no-start -e '
Application.ensure_all_started(:ecto_sql)
PurpleFlow.Repo.start_link()
{ok, errors} = PurpleFlow.Workflow.Loader.load_all("workflows")
IO.puts("loaded: #{ok |> Map.keys() |> Enum.join(", ")}")
for {path, problems} <- errors, do: IO.puts("#{path}:\n  - " <> Enum.join(problems, "\n  - "))'
```

It catches bad TOML, missing files, unknown modules, unknown `after` names, loops, `when` misuse, unset credentials, references to non-ancestors, and Code script syntax errors.

## Run and inspect

- **Webhook:** `curl -X POST localhost:4000/hooks/<path> -H 'content-type: application/json' -d '<json>'`. The reply is the output. The run ID is in the `x-run-id` header.
- **UI:** `localhost:4000`, then the workflow's Run box, then the run page. Click a step to see its input and output. Per-item steps expand into one row per item.
- **Database** (dev db `purple_flow_dev`): `runs` has one row per run (`status`, `input`, `output`, `error`). `step_runs` has one row per node execution (`step`, `item`, `from_item`, `status`, `route`, `input`, `output`, `error`).
- **A failed run's `error`** says which step and item failed and why. Nothing after a failure starts.

## A new node type

Only when HTTP, Postgres, and Code really can't do it. Add a module under `lib/purple_flow/nodes/`:

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
- Optional: `execute/3` also gets `steps`, and `prepare/2` checks config when the workflow loads.
- Keep docs short and plain. Add a test that calls `execute/2` directly, then run `mix precommit`.
