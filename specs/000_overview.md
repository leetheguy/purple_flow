# 000 — Overview

Status: draft

## What this is

A barebones n8n alternative, built on Elixir/OTP. Workflows are TOML files in git. A trigger starts a run, the run walks the workflow's steps, each step runs a node, and every node's input and output is saved so you can see exactly what happened.

## The whole model

1. A **trigger** (webhook, cron, manual) starts a **run** with some input.
2. The run walks the **steps** listed in the workflow's TOML file.
3. Each step runs a **node**. A node takes one input and returns one output (a JSON-shaped value).
4. If a step's input is a **list**, the node runs once per item, in parallel (or once for the whole list, if the step says `run = "all"`). Results are always one flat list, never a list of lists.
5. When a step finishes, its record is saved and a "done" message is broadcast. The run hears it and starts whatever comes next.
6. If anything fails, the run stops. Everything that happened up to that point is already saved.

There are no loops or cycles. Parallelism comes only from "list in, run per item" (rule 4).

## Rules

- **One node contract.** Every node is a module with `execute(input, config)`. There's no connector library. HTTP, Postgres, and Code nodes cover most jobs. See [020](020_nodes.md).
- **TOML, one file per node, one file per workflow.** No YAML and no frontmatter. Git does the versioning. See [010](010_workflows.md).
- **No credentials in TOML, ever.** Credentials are env vars (`.env`), referenced as `{{ env.NAME }}`, and redacted from every record. See [010](010_workflows.md).
- **Everyone does their own job.** Each node execution runs in its own process, saves its own record, and broadcasts when it's done. The run only decides what starts next. See [030](030_runs.md).
- **Fail loud, no retries.** A failure stops the run and leaves a full record. Retries and rollback come later, once real use shows what's needed.
- **Light docs in code.** Module docs and comments are short and plain, like these specs. Someone who doesn't know Elixir should be able to follow them: say what it does and why, and explain Elixir/OTP terms in a few words when they come up.
- **Logs before canvas.** The v1 UI is an execution history viewer, like n8n's executions view. Workflows are edited as TOML. See [060](060_ui.md).

## Process tree

```
PurpleFlow.Supervisor
├── PurpleFlow.Repo                          # Postgres
├── Phoenix.PubSub (PurpleFlow.PubSub)       # all broadcasts
├── Registry + DynamicSupervisor             # Postgres node connection pools, one per database URL
├── PurpleFlow.Workflows                     # loads + holds parsed workflow definitions
├── Task.Supervisor (PurpleFlow.StepSupervisor)   # every node execution runs here
├── DynamicSupervisor (PurpleFlow.RunSupervisor)  # one PurpleFlow.Run per run
├── PurpleFlow.Scheduler                     # Quantum, for cron triggers
└── PurpleFlowWeb.Endpoint                   # UI + webhooks, started last
```

Order matters. Nothing should accept a trigger until everything a run needs is already up, so the endpoint and scheduler start last.

## Dependencies

| Need | Package |
|---|---|
| Web, UI, webhooks, pubsub | `phoenix`, `phoenix_live_view` (Bandit adapter) |
| Storage | `ecto_sql`, `postgrex` |
| TOML | `toml_elixir` |
| HTTP node | `req` |
| Cron | `quantum` |
| JSON | `jason` |
| `.env` loading | `dotenvy` |

Check current versions on Hex before adding them.

## Borrowed from purple_goo

purple_goo was a predecessor to purple_flow. purple_flow absorbed relevant architecture from purple_goo.

- `PurpleGoo.Id` (hand-rolled UUIDv7) copied over as `PurpleFlow.Id`. Every run ID is a UUIDv7.
- One process per run under a `DynamicSupervisor` with `restart: :temporary`, like `RequestSession`. A crashed run must **not** restart, or it would redo its side effects.
- Subscribe before you start work, so you can't miss the reply.
- Boot order: shared plumbing first, anything that accepts outside input last.

purple_goo is not a dependency. Running purple_goo's pipeline as a PurpleFlow workflow is a later goal (see below).

## Later (not v1)

- Agent node, wrapping purple_goo's ReAct-based agent call.
- Retries, rollback.
- A step that waits for *all* of its parallel branches before running once.
- Referencing the *matching item* of an earlier step (like n8n's `$('Fetch').item`), using `from_item`.
- Depth limit for workflows that call themselves.
- Auth for the UI and webhooks.
- A proper credential store (like n8n's) instead of `.env`.
- Auto-reload when TOML files change.
- Visual workflow builder (canvas → TOML).
- Multi-tenant hosting, which would need a sandboxed Code node.

## Specs

- [010 — Workflows (TOML)](010_workflows.md)
- [020 — Nodes](020_nodes.md)
- [030 — Runs](030_runs.md)
- [040 — Triggers](040_triggers.md)
- [050 — Storage](050_storage.md)
- [060 — UI](060_ui.md)
