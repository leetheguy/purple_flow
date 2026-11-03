# 000 — Overview

Status: living
Created: 2026-09-25

This is the source of truth for what PurpleFlow is today. Read it first. It's rewritten whenever the project changes; the numbered specs it links to hold the detail and the reasons behind each decision.

## What this is

A barebones n8n alternative, built on Elixir/OTP, mainly for agents to build and run workflows with. Workflows are TOML files in a folder (which can be its own git repo). A trigger starts a run, items flow through the workflow's steps, each step runs a node, and every execution's input and output is saved, so you can see exactly what happened.

It's a power tool: safeguards are options with defaults, not limits. See `AGENTS.md`.

## The whole model

1. A **trigger** (webhook, cron, or manual) starts a **run** with some input. See [040](040_triggers.md).
2. The input becomes **items**. A list splits into one item per element; anything else, including an object holding a list, is one item. See [120](120_flow.md).
3. Every **step** has a queue. Each item gets its own **execution** of the step's **node**, and what it returns goes straight into the queues of the steps after it. Nothing waits for a whole step to finish. Steps set `concurrency`, `delay`, `timeout`, and `max_queue` (with `on_full = "wait"` for backpressure or `"overflow"` for an overflow route).
4. A node can pick a **route** for its output; steps with `when = "route"` get only those items. Steps run `after` other steps, so a workflow is a graph with forks and no cycles. A workflow may run itself, or another workflow, through a Workflow node.
5. A **failure** stops that item, not the run, unless the step says `on_fail = "end_run"`. Failed items go down the `failed` route with the error and the input. No retries. See [130](130_failures.md).
6. To gather items, use a **Batch** step ([140](140_batch.md)). Nodes and webhooks can **stream** ([150](150_streaming.md)). Runs can be watched live and killed ([160](160_live_runs.md)).
7. Runs and their executions are saved in Postgres, in batches, with credentials redacted ([050](050_storage.md)). A run cut off by a restart is marked `interrupted`; nothing resumes it.

## Rules

- **One node contract.** Every node is a module with `execute(input, config)` returning `{:ok, output}`, `{:ok, output, route}`, or `{:error, reason}`. There's no connector library. See [020](020_nodes.md).
- **TOML, one file per node, one folder per workflow.** No YAML, no frontmatter. Workflows can sit in subfolders ([110](110_workflow_folders.md)). See [010](010_workflows.md).
- **No credentials in TOML, ever.** Credentials are stored encrypted in Postgres, set only by a person on `/credentials`, referenced as `{{ creds.NAME }}`, and redacted from every record. See [080](080_credentials.md), [200](200_oauth_credentials.md), [230](230_credential_value_types.md).
- **Agents write workflows, people hold the secrets.** Agents edit the workflows folder through the files service and read `/agents`; they can't see or set credentials. See [090](090_workflow_files.md).
- **Untrusted code runs elsewhere.** Code node scripts run in a separate runner container with no secrets, no database, and no network beyond answering the app. See [100](100_runner_container.md).
- **Fail loud.** A failure leaves a full record. Retries are an open idea, not a feature ([999](999_todo.md)).
- **Light docs in code.** Module docs and comments are short and plain, like these specs. Someone who doesn't know Elixir should be able to follow them: say what it does and why, and explain Elixir/OTP terms in a few words when they come up.
- **TOML is the editor.** The UI shows runs and a read-only canvas of each workflow ([210](210_canvas.md)); workflows are edited as files.

## Built-in nodes

HTTP (can stream), Postgres, Code, SSH (can stream, [170](170_ssh.md)), Workflow, Batch, Noop, Wait, Respond (answers a waiting webhook early, [180](180_noop_wait_respond.md)), and OpenAI Chat (streams a chat answer back to the caller in OpenAI's format, [240](240_openai_chat.md)). Their options are in [020](020_nodes.md) and its log, and in `samples/AGENTS.md`.

## Deployment

Docker Compose runs four services, behind one site and one sign-in:

| Service | What it does |
|---|---|
| `app` | the Phoenix app: UI, webhooks, runs. Mounts the workflows folder read-only and reloads on every change ([090](090_workflow_files.md)). |
| `runner` | the same release in runner mode, running Code node scripts ([100](100_runner_container.md)). |
| `files` | dufs, serving the workflows folder to agents and people at `/fs/`, through the app. |
| `db` | Postgres 17, or an existing server via `docker-compose.external-db.yml`. |

Run files (webhook uploads) live in a volume of their own and are deleted when the run ends ([190](190_run_files.md)). The whole UI is behind a login form; `/hooks/*`, `/health`, and `/agents` are open, and a webhook can require a token (`auth`, [040](040_triggers.md)).

## Process tree (app)

```
PurpleFlow.Supervisor
├── PurpleFlow.Repo                               # Postgres
├── (marks runs a restart cut off as interrupted)
├── Phoenix.PubSub (PurpleFlow.PubSub)            # all broadcasts
├── Registry + DynamicSupervisor                  # Postgres node pools, one per database URL, closed when idle
├── Task.Supervisor (PurpleFlow.StepSupervisor)   # every node execution runs here
├── Registry (PurpleFlow.RunRegistry)             # finds a run by its ID
├── DynamicSupervisor (PurpleFlow.RunSupervisor)  # one PurpleFlow.Run per run, never restarted
├── PurpleFlow.Scheduler                          # Quantum, for cron triggers
├── PurpleFlow.Workflows                          # loads, checks, and watches the workflow files
├── PurpleFlowWeb.LoginThrottle                   # locks out repeated failed sign-ins
└── PurpleFlowWeb.Endpoint                        # UI + webhooks, started last
```

Order matters: nothing accepts a trigger until everything a run needs is up. A crashed run is not restarted, or it would redo its side effects. The runner container starts only `PurpleFlow.Runner.Server`, its connections, and a reaper that cleans up what scripts leave behind.

## Where things live

| Path | What's there |
|---|---|
| `lib/purple_flow/run.ex`, `step_task.ex` | the run engine: queues, routes, executions |
| `lib/purple_flow/workflow/`, `workflows.ex` | loading, checking, and watching workflow files |
| `lib/purple_flow/nodes/` | the built-in nodes |
| `lib/purple_flow/runner/` | the Code runner (both sides) |
| `lib/purple_flow/credentials*` | encrypted credentials and OAuth |
| `lib/purple_flow_web/` | UI (LiveViews), webhooks, login, files proxy |
| `samples/` | sample workflows, the agent guide (`AGENTS.md`), and pressure tests (`testing/`) |
| `.claude/skills/purpleflow-workflows/` | the skill sheet for agents building workflows |

## Dependencies

| Need | Package |
|---|---|
| Web, UI, webhooks, pubsub | `phoenix`, `phoenix_live_view` (Bandit adapter) |
| Storage, Postgres node | `ecto_sql`, `postgrex` |
| TOML | `toml_elixir` |
| HTTP and OpenAI Chat nodes | `req` |
| Cron | `quantum` |
| JSON | `jason` |
| SSH node | OTP's own `:ssh` (no package) |
| Test coverage | `excoveralls` |

Check current versions on Hex before adding any.

## Specs

**Living:**

- [000 — Overview](000_overview.md): this page.
- [999 — To-do](999_todo.md): planned work, open questions, and ideas.

**History** (each one as decided, with later changes in its log):

- [010 — Workflows (TOML)](010_workflows.md): the workflow and node files, templates.
- [020 — Nodes](020_nodes.md): the node contract and the first built-in nodes.
- [030 — Runs](030_runs.md): *superseded by 120.*
- [040 — Triggers](040_triggers.md): webhooks, cron, manual runs, webhook replies and auth.
- [050 — Storage](050_storage.md): runs and executions in Postgres.
- [060 — UI](060_ui.md): the run history viewer.
- [070 — Code sandbox](070_code_sandbox.md): *superseded by 100.*
- [080 — Credentials](080_credentials.md): encrypted credentials and the login.
- [090 — Workflow files](090_workflow_files.md): the files service, live reload, path containment.
- [100 — Runner container](100_runner_container.md): where Code scripts run.
- [110 — Workflow folders](110_workflow_folders.md): workflows in subfolders.
- [120 — Flow](120_flow.md): items flowing through queues.
- [130 — Failures](130_failures.md): `on_fail`, the `failed` route, kill.
- [140 — Batch](140_batch.md): gathering items.
- [150 — Streaming](150_streaming.md): nodes and webhooks that stream.
- [160 — Live runs](160_live_runs.md): watching runs as they happen.
- [170 — SSH node](170_ssh.md)
- [180 — Noop, Wait, and Respond nodes](180_noop_wait_respond.md)
- [190 — Run files](190_run_files.md): webhook uploads and files in runs.
- [200 — OAuth credentials](200_oauth_credentials.md)
- [210 — Canvas](210_canvas.md): a read-only picture of each workflow.
- [220 — Missing credentials](220_missing_credentials.md): creating every unset credential in one click.
- [230 — String and Text credentials](230_credential_value_types.md)
- [240 — OpenAI Chat node](240_openai_chat.md)
