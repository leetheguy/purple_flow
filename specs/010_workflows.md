# 010 — Workflows (TOML)

Status: draft
Created: 2026-09-25

## Layout

One folder per workflow. The workflow file lists steps. Each step points at a node file.

```
workflows/
  sync_records/
    workflow.toml
    fetch.toml
    is_big.toml
    is_big.exs      # code for the is_big Code node
    save.toml
```

A node file can be shared between workflows by pointing at it with a relative path (`node = "../shared/slack_post.toml"`).

## Workflow file

```toml
[workflow]
name = "sync_records"

[trigger.webhook]
path = "sync-records"      # replies with the run's output; see 040

[trigger.cron]
schedule = "0 * * * *"

[[steps]]
name = "fetch"
node = "fetch.toml"

[[steps]]
name = "is_big"
node = "is_big.toml"
after = ["fetch"]

[[steps]]
name = "save_big"
node = "save.toml"
after = ["is_big"]
when = "big"
timeout = 60
```

Step fields:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Unique within the workflow. |
| `node` | yes | Path to the node file, relative to this workflow file. |
| `after` | no | Steps that must finish first. No `after` means the step gets the trigger's input. |
| `when` | no | Only run if the step in `after` returned this route. Allowed only with a single `after`. See [030](030_runs.md). |
| `timeout` | no | Seconds per node execution. Default 30. |
| `run` | no | `"each"` (default): a list input runs once per item. `"all"`: runs once with the whole input. See [030](030_runs.md). |
| `concurrency` | no | How many per-item executions run at once: `"concurrent"` (default, 1,000), `"sequential"` (1), or a number. |

A workflow can have any number of triggers. See [040](040_triggers.md).

## Node file

```toml
module = "PurpleFlow.Nodes.Http"

[config]
method = "GET"
url = "https://api.example.com/records?since={{ input.since }}"
headers = { authorization = "Bearer {{ creds.API_TOKEN }}" }
```

`module` is any module implementing `PurpleFlow.Node`. `config` is passed to it after templates are filled in.

## Templates

Any string in `config` can contain:

- `{{ input.some.path }}`, a value from the node's input
- `{{ steps.fetch.output.some.path }}`, a value from an earlier step's output (see [030](030_runs.md))
- `{{ creds.NAME }}`, a credential. See Credentials below.

If a string is *only* one template (`"{{ input.ids }}"`), the raw value is used, so numbers, lists, and maps keep their type. Otherwise the value is turned into text and inserted into the string. A missing path fails the step.

The runtime fills templates before calling the node, so nodes never see `{{ }}`.

## Credentials

**No passwords, keys, or tokens in TOML, ever.** Credentials are stored encrypted and referenced by name through `{{ creds.NAME }}`. See [080](080_credentials.md) for how they're stored, how a name is chosen, and the UI that sets them — a workflow file only ever reads one by name, never creates or sees one.

- A credential is created and given a value through the `/credentials` UI, not through any workflow file.
- At load time, a workflow that uses a `creds.NAME` that isn't set fails its checks.
- **Credentials are never saved or shown.** Filled-in config is never stored or logged. Before any record, error, or log line is saved, every credential value a step used is replaced with `[redacted]`.

## Loading

`PurpleFlow.Workflows` reads `workflows/` at boot and keeps the parsed definitions in memory. `PurpleFlow.Workflows.reload/0` re-reads everything, and triggers are re-registered.

Each workflow is checked when it's loaded:

- the TOML parses
- node files exist, and Code nodes' `.exs` files exist and parse
- each `module` exists and implements `PurpleFlow.Node`
- `after` names exist
- no cycles
- `when` is only used with a single `after`
- every `creds.NAME` used is set, including a webhook's `auth` credential
- every `steps.NAME` used in a template is an ancestor of that step

A workflow that fails a check is logged and skipped. Other workflows still load.

## Tests

Parse good and bad fixtures. Each check above has a failing fixture that produces a clear error.

Redaction: run a node that echoes a credential in its output and in an error, and assert that the saved rows only contain `[redacted]`.

## Log

- 2026-09-26 — [090](090_workflow_files.md) (draft): **Layout**: the workflows folder can live anywhere on the host (`WORKFLOWS_PATH`) and is meant to be its own git repo; the samples live in `samples/` at the repo root. Every `node` path must stay inside the workflows folder; absolute paths and paths that leave it fail to load. **Loading**: workflows reload on their own within about two seconds of a change, per workflow; a workflow that fails to reload keeps running its last good version.
