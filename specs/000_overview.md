# 000 — Overview

Status: implemented
Created: 2026-09-25

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

- Webhook that replies with the run's result instead of just the run ID. This is needed to run purple_goo as a workflow.
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
- [170 — SSH node](170_ssh.md)
- [180 — Noop, Wait, and Respond nodes](180_noop_wait_respond.md)
- [190 — Run files](190_run_files.md)
- [200 — OAuth credentials](200_oauth_credentials.md)
- [210 — Canvas](210_canvas.md)
- [999 — To-do](999_todo.md)

## Log

- 2026-09-25 — Webhooks reply with the run's output by default (see [040](040_triggers.md)'s log), so "Webhook that replies with the run's result instead of just the run ID" is no longer a "Later" item.
- 2026-09-25 — [070](070_code_sandbox.md): Code node scripts run on an isolated peer node, not in the app's own process. Spec 070 joins the list above.
- 2026-09-25 — [080](080_credentials.md): credentials are stored encrypted in Postgres and referenced as `{{ creds.NAME }}`, not `.env` variables referenced as `{{ env.NAME }}`; `dotenvy` is no longer a dependency. The whole browser UI is behind a login. From "Later": "Auth for the UI and webhooks" and "A proper credential store" are done (webhook auth itself arrives on 2026-09-26, see 040's log), "Multi-tenant hosting" no longer needs a sandboxed Code node, and "Per-credential allowed-host locks on the HTTP/Postgres nodes" is added. Spec 080 joins the list above.
- 2026-09-26 — [100](100_runner_container.md): Code node scripts run in a separate runner container, replacing 070's peer node. Spec 100 joins the list above.
- 2026-09-26 — [090](090_workflow_files.md): workflow files, isolated and live. The workflows folder is exposed to agents and people through a `files` service (dufs); the app mounts it read-only and reloads on every change, so "Auto-reload when TOML files change" is no longer a "Later" item. Spec 090 joins the list above.
- 2026-09-27 — [120](120_flow.md), [130](130_failures.md), [140](140_batch.md), [150](150_streaming.md), [160](160_live_runs.md): **the model changes from "a step runs, then the next" to items flowing through queues.** Every step has a queue; each item gets its own execution and moves on as soon as it's done (rule 4 and 5 of "The whole model"): a list output splits into items, and nothing waits for a whole step. `run = "all"` is gone (a Batch node gathers items instead), and so is the 10,000-item cap. Rule 6 and "Fail loud, no retries" change: a failure stops that item, not the run, unless its step says `on_fail = "end_run"`; failures can be handled on a `failed` route. Each execution no longer saves its own record or broadcasts "done": the run saves rows in batches and broadcasts `run_progress` at most every 250 ms. Nodes can stream (the HTTP node, and webhooks with `respond = "stream"`). Runs can be killed. The process tree gains `Registry (PurpleFlow.RunRegistry)`, which finds a run by its ID, next to `RunSupervisor`. From "Later": "Referencing the *matching item* of an earlier step" is done (`steps.X.output` is the item on this item's path), and "Depth limit for workflows that call themselves" is dropped: a workflow may run itself, and making it stop is the workflow's job. Specs 120, 130, 140, 150, and 160 join the list above, as does [110](110_workflow_folders.md) (workflows in subfolders), which was never added to it; 030 is superseded by 120.
- 2026-09-27 — [170](170_ssh.md): a built-in SSH node runs commands on other machines and can stream their output. Erlang's `:ssh` application (part of OTP, not a new package) joins the dependencies. Spec 170 joins the list above.
- 2026-09-28 — [180](180_noop_wait_respond.md): built-in Noop, Wait, and Respond nodes; a Respond step answers a waiting webhook caller early while the run carries on. Spec 180 joins the list above, as does [170](170_ssh.md), which was never added to it.
- 2026-09-28 — [999](999_todo.md): planned and open work is listed in 999, a living to-do list, so this spec's "Later" section is no longer kept up to date. Its remaining items moved there.
- 2026-09-28 — [190](190_run_files.md): runs can carry files. Webhook uploads are saved in a volume of their own, items hold a reference, and a run's files are deleted when it ends. Spec 190 joins the list above.
- 2026-09-28 — [200](200_oauth_credentials.md): credentials can be OAuth logins, connected once on the Credentials page and used as `{{ creds.NAME }}` like any other; the app keeps the token working. A Gmail sample sends email with them. Spec 200 joins the list above.
- 2026-09-30 — [210](210_canvas.md): a read-only **canvas** shows each workflow as boxes pointing at boxes, with the comments at the top of its files. Workflows are still edited as TOML; a visual builder is still an idea. Spec 210 joins the list above.
