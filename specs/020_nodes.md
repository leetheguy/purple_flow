# 020 — Nodes

Status: implemented
Created: 2026-09-25

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

Uses `Postgrex`. Config: `query` and `params`, plus `database_url` (usually `{{ env.SOME_DB_URL }}`). Values go in `params` (`$1`, `$2`, …), **never** templated into `query`. That prevents SQL injection. Output is a list of row maps, so the next step runs per row.

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

This runs arbitrary code. It's fine as long as only you write the workflow files.

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

## Log

- 2026-09-25 — [070](070_code_sandbox.md): **Code** scripts no longer run in the app's own process. They run on an isolated peer node with no access to the app's modules, database, or environment variables.
- 2026-09-25 — [080](080_credentials.md): **Postgres**: `database_url` is usually `{{ creds.SOME_DB_URL }}`, not `{{ env.SOME_DB_URL }}`.
- 2026-09-26 — [100](100_runner_container.md): **Code** scripts run in a separate runner container with no secrets, no database, and no network access beyond answering the app, replacing the peer node.
- 2026-09-26 — [090](090_workflow_files.md): **Code**: edits to a `.exs` file take effect on their own within about two seconds, with no `reload/0`. A Code node's `file` must stay inside the workflows folder. `prepare(config, node_dir)` becomes `prepare(config, node_dir, root)`, where `root` is the workflows folder, so a node can resolve files it names without leaving it.
- 2026-09-27 — [120](120_flow.md): **Contract**: `input` is always one item; there's no `run = "all"` whole-list input. A returned list splits into items for the next steps; anything else, including an object holding a list, is one item. `steps` is this item's path: each ancestor's item that led here.
- 2026-09-27 — [150](150_streaming.md): **Contract**: a node may call `PurpleFlow.Node.emit(value, route \\ nil)` while it runs to hand an item on right away. **Http** takes `stream` (`"sse"`, `"ndjson"`, or `"lines"`) to emit one item per streamed message as it arrives, and returns `[]`.
- 2026-09-27 — [140](140_batch.md): a new built-in node, **`PurpleFlow.Nodes.Batch`** (`size`, `wait`), gathers items and hands them on as `{"items": [...]}`. The run handles it itself.
- 2026-09-27 — [120](120_flow.md): **Workflow**: steps have no timeout by default, so this node waits for the other workflow as long as it takes, unless its step sets `timeout`.
- 2026-09-27 — [170](170_ssh.md): a new built-in node, **`PurpleFlow.Nodes.Ssh`** (`host`, `port`, `user`, `password` or `private_key`, `host_key`, `command`, `stdin`, `stream`), runs a command over SSH and returns `{"stdout", "stderr", "exit_status"}`; a non-zero exit is an error. With `stream` it emits each line of stdout as it arrives.
- 2026-09-28 — [180](180_noop_wait_respond.md): three new built-in nodes, each handing its input on unchanged. **`PurpleFlow.Nodes.Noop`** does nothing. **`PurpleFlow.Nodes.Wait`** (`ms` or `until`) waits first. **`PurpleFlow.Nodes.Respond`** (`status`, `headers`, `body`) answers the waiting webhook caller while the run carries on. **Contract**: a node may call `PurpleFlow.Node.respond(reply)` to answer that caller; only the first answer goes through.
- 2026-10-03 — [240](240_openai_chat.md): a new built-in node, **`PurpleFlow.Nodes.OpenAIChat`** (`url`, `headers`, `body`, `respond`), calls an OpenAI-compatible chat completions API with streaming on, passes the events to the waiting webhook caller as they arrive, and returns the whole message (`content`, `reasoning`, `tool_calls`, `finish_reason`, `model`, `id`, `usage`). **Contract**: a node may answer the caller with a stream, `PurpleFlow.Node.respond_stream/2` with `respond_chunk/2` and `respond_done/1`, under `respond/1`'s rules.
- 2026-10-16 — **Postgres**: a pool closes its connections after a minute with no queries, and the next query opens it again. Before, every `database_url` ever queried held 10 connections until the app restarted, which filled a shared server's `max_connections`.
- 2026-11-03 — **Postgres**: `pool_size` (1 or more, default 10) and `idle_timeout` (seconds, default 60; `0` keeps the pool open) are options on the node, checked when the workflow loads. Steps that share a `database_url` and both settings share a pool; different settings get separate pools. Tests: the settings shape the pool; the defaults are 10 and 60; different settings on one URL get separate pools; `prepare` refuses a `pool_size` under 1 or an `idle_timeout` under 0, naming the setting; a pool set to stay open doesn't close between queries. From the OP-PARAMS audit: no hard-coded limits a workflow can't change.
- 2026-11-07 — [260](260_file_transport.md): **HTTP**: `body_file` sends a file reference's bytes as the body, streamed from disk, with the reference's type as `content-type` unless `headers` sets one. It fails to load alongside `body`.
- 2026-11-07 — [260](260_file_transport.md): **HTTP**: `form` sends `multipart/form-data`. A field holding a file reference is a file part with its name and type, streamed from disk; other values are text (maps and lists as JSON). A step takes one of `body`, `body_file`, and `form`.
- 2026-11-07 — [260](260_file_transport.md): **HTTP**: `response_file` saves a 2xx body as a file in the run, streamed to disk, and the output is its reference. It's the file's name, or `true` for the name in `content-disposition`, then the URL's last segment, then `response`; the type is the response's `content-type`, else guessed from the name. The body is asked for uncompressed. A non-2xx, a failed request, or a file over `max_file_size` fails and leaves no file. It fails to load alongside `stream`.
- 2026-11-07 — [260](260_file_transport.md): **Postgres**: a param that's a file reference is sent as the file's bytes (for `bytea`), checked before connecting. `files` names `bytea` columns to save as files in the run, named after the column, with the reference in the row; `NULL` stays `null`. A column that isn't `bytea` or isn't in the result fails, and if any file fails (say over `max_file_size`), the files already saved for that output are deleted. `files` must be a list of column names.
