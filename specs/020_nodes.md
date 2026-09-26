# 020 — Nodes

Status: draft

## Contract

```elixir
defmodule PurpleFlow.Node do
  @callback execute(input :: term(), config :: map()) ::
              {:ok, output :: term()}
              | {:ok, output :: term(), route :: String.t()}
              | {:error, reason :: term()}
end
```

- `input` is one JSON-shaped value (maps have string keys). If the step received a list, this is **one item** of it, and the node never knows it's running per item. With `run = "all"`, it's the whole list.
- `config` is the node file's `[config]` table, with templates already filled in.
- `route` is optional and used for if/else. See [030](030_runs.md).
- Raising an exception counts as `{:error, ...}`.

That's the entire interface. A new node type is a new module. Nothing else changes.

Two optional extras:

- **`execute(input, config, steps)`**: implement this instead if the node needs its ancestors' outputs directly (`steps["fetch"]["output"]`). The Code node does.
- **`prepare(config, node_dir)`**: runs once when the workflow loads, so mistakes show up early. Returns `{:ok, config}` or `{:error, message}`. The Code node uses it to read and check its `.exs` file.

A node may use anything internally, including Jido. The runtime never knows or cares.

## Built-in nodes

### `PurpleFlow.Nodes.Http`

Uses `Req`. Config: `method`, `url`, `headers`, `body`, `query`. Output is the decoded response body. A non-2xx response is an error.

### `PurpleFlow.Nodes.Postgres`

Uses `Postgrex`. Config: `query` and `params`, plus `database_url` (usually `{{ creds.SOME_DB_URL }}`). Values go in `params` (`$1`, `$2`, …), **never** templated into `query`. That prevents SQL injection. Output is a list of row maps, so the next step runs per row.

Connections are pooled, with one pool per `database_url` (default size 10), so a step running 1,000 items at once doesn't open 1,000 connections.

Other databases get their own modules (`Nodes.Mysql`, `Nodes.Sqlite`, …). If they turn out to share code, it goes into a plain helper module they all call.

### `PurpleFlow.Nodes.Code`

Config: `file`, the path to an `.exs` file, relative to the node file. The script runs with two variables set: `input` (this node's input) and `steps` (its ancestors' outputs, as `steps["fetch"]["output"]`).

```toml
# is_big.toml
module = "PurpleFlow.Nodes.Code"

[config]
file = "is_big.exs"
```

```elixir
# is_big.exs
if input["amount"] > 1000 do
  {:ok, input, "big"}
else
  {:ok, input, "small"}
end
```

The file is read and parsed when the workflow loads, so a syntax error fails the workflow's checks rather than a run. Edits take effect on `reload/0`.

If the script returns `{:ok, _}`, `{:ok, _, route}`, or `{:error, _}`, that result is used as-is. Any other value `v` becomes `{:ok, v}`.

This runs arbitrary code, but not in this app's own container — it runs in a separate runner container with no secrets, no database, and no network access beyond answering the app. See [070](070_code_sandbox.md).

### `PurpleFlow.Nodes.Workflow`

Runs another workflow and returns that workflow's output (see [030](030_runs.md)). If the other workflow fails, this step fails.

```toml
module = "PurpleFlow.Nodes.Workflow"

[config]
workflow = "enrich_contact"
```

It starts the child run with this node's input as the trigger input. It subscribes to the child's topic *before* starting the run, then waits for the child's `run_finished` message. The step's `timeout` covers the wait.

## Tests

Each node is tested on its own by calling `execute/2` directly:

- **Http:** against a local test server (`Req.Test`).
- **Postgres:** against the test database.
- **Code:** with sample snippets, including route and error returns.
- **Workflow:** with a small fixture workflow.

No run machinery is needed.
