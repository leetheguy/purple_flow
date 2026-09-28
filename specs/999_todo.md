# 999 — To-do

Status: draft
Created: 2026-09-28

The list of planned work and open questions, in one place. Unlike every other spec, this one is never finished: it's kept current, not kept as history. Add an item when something is planned or left open; delete it when it ships (the spec that ships it says so in its own text or log) or is dropped (say why in the commit). Each item links to where it came from.

It replaces the "Later" sections in [000](000_overview.md), [090](090_workflow_files.md), and [100](100_runner_container.md), and gathers the open questions left in other specs' logs. Those sections and log entries stay as they are, as history.

## Planned

- **More ways to handle files**, when needed: save an HTTP response as a file, send a file with the HTTP or Respond node, save SSH output as a file. The minimum (webhook uploads, SSH `stdin_file`) is in [190](190_run_files.md).
- **Retries.** An option per step to retry a failed item (`retries`, `retry_delay`), off by default. From [000](000_overview.md).
- **Waiting for all branches.** A step that runs once after all of its `after` branches finish, instead of once per item from each ([120](120_flow.md) has no joining). From [000](000_overview.md).
- **Per-credential allowed-host locks** on the HTTP, Postgres, and SSH nodes, as an option on the credential. From [080](080_credentials.md), [090](090_workflow_files.md), [100](100_runner_container.md).
- **Agent node**, wrapping purple_goo's agent call, and running purple_goo's pipeline as a workflow. From [000](000_overview.md).
- **Run-a-workflow endpoint for agents**, so testing a workflow doesn't need a webhook on it. From [090](090_workflow_files.md).
- **Run retention.** Runs and their step records are kept in Postgres forever, so the database only grows. An option to prune them after some age or count. (A run's files don't need it: they're deleted when the run ends, [190](190_run_files.md).)

## Open questions

- **Code scripts and files.** Scripts see a file's reference but not its bytes, since the runner has no access to the run files volume. Sending bytes to the runner, as an option on the step? From [190](190_run_files.md).
- **Non-zero SSH exits:** always an error, or an option to return them as output or send them down a route? From [170](170_ssh.md)'s log.
- **Missed cron firings** while the app is down: catch up at boot, as an option on `[trigger.cron]`? From [040](040_triggers.md)'s log.
- **Resuming interrupted runs**, as a per-workflow option. From [130](130_failures.md)'s log.
- **Durable waits.** A Wait step lives in memory, so a restart interrupts it ([180](180_noop_wait_respond.md)). Long waits, and a Wait that resumes when a webhook is called (like n8n's), would need the run's state saved. Likely the same work as resuming interrupted runs.
- **A non-superuser database role** for the app, as an option. From [050](050_storage.md)'s log.
- **Scripts sharing the runner VM** can see each other; a VM per workflow is the idea, without losing the shared VM's speed. From [100](100_runner_container.md).

## Ideas

- Rollback of a run's side effects. From [000](000_overview.md).
- A visual workflow builder (canvas to TOML). From [000](000_overview.md).
- Multi-tenant hosting. From [000](000_overview.md).
- Separate files-service logins per agent, or per-folder permissions. From [090](090_workflow_files.md).
- Collapsible folder groups on the Workflows page. From [110](110_workflow_folders.md).
