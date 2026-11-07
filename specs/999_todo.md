# 999 — To-do

Status: living
Created: 2026-09-28

The list of planned work and open questions, in one place. Like [000](000_overview.md), this spec is living: it's kept current, not kept as history. Add an item when something is planned or left open; delete it when it ships (the spec that ships it says so in its own text or log) or is dropped (say why in the commit). Each item links to where it came from.

It gathers the "Later" sections and open questions left in other specs and their logs. Those stay as they are, as history.

## Planned

- **File transport**: HTTP downloads and uploads, SSH `stdout_file`, Postgres `bytea`, and `max_file_size`. Drafted in [260](260_file_transport.md).
- **Retries.** An option per step to retry a failed item (`retries`, `retry_delay`), off by default. From [000](000_overview.md).
- **Waiting for all branches.** A step that runs once after all of its `after` branches finish, instead of once per item from each ([120](120_flow.md) has no joining). From [000](000_overview.md).
- **Per-credential allowed-host locks** on the HTTP, Postgres, and SSH nodes, as an option on the credential. From [080](080_credentials.md), [090](090_workflow_files.md), [100](100_runner_container.md).
- **Agent node**, wrapping purple_goo's agent call, and running purple_goo's pipeline as a workflow. From [000](000_overview.md).
- **Run-a-workflow endpoint for agents**, so testing a workflow doesn't need a webhook on it. From [090](090_workflow_files.md).
- **Run retention.** Runs and their step records are kept in Postgres forever, so the database only grows. An option to prune them after some age or count. (A run's files don't need it: they're deleted when the run ends, [190](190_run_files.md).)
- **Signed requests on the HTTP node** (starting with AWS SigV4, for S3); sending a file's bytes is in [260](260_file_transport.md). Found migrating Decapod's workflows: S3 is popular enough elsewhere that it's worth solving for, even setting personal taste aside.



- **Engine test gaps found by `mix mutate`** (2026-11-03). In `run.ex`, 19 of 82 mutants survived, at lines 83, 104, 321, 333–340, 359, 423, 471, 527, 588–589, and 612; in `step_task.ex`, 1 of 3, at line 91. Each needs a test that kills it, or a reason it can't matter. Rerun with: `mix mutate lib/purple_flow/run.ex lib/purple_flow/step_task.ex --test test/purple_flow/run_test.exs --test test/purple_flow/failures_test.exs --test test/purple_flow/batch_test.exs --test test/purple_flow/streaming_test.exs --test test/purple_flow_web/webhook_controller_test.exs` (about 10 minutes). From [OP-PARAMS.md](../OP-PARAMS.md) section 5.

## Open questions

- **Non-zero SSH exits:** always an error, or an option to return them as output or send them down a route? From [170](170_ssh.md)'s log.
- **Missed cron firings** while the app is down: catch up at boot, as an option on `[trigger.cron]`? From [040](040_triggers.md)'s log.
- **Resuming interrupted runs**, as a per-workflow option. From [130](130_failures.md)'s log.
- **Durable waits.** A Wait step lives in memory, so a restart interrupts it ([180](180_noop_wait_respond.md)). Long waits, and a Wait that resumes when a webhook is called (like n8n's), would need the run's state saved. Likely the same work as resuming interrupted runs.
- **A non-superuser database role** for the app, as an option. From [050](050_storage.md)'s log.
- **Scripts sharing the runner VM** can see each other; a VM per workflow is the idea, without losing the shared VM's speed. From [100](100_runner_container.md).


## Ideas

- Rollback of a run's side effects. From [000](000_overview.md).
- A visual workflow builder (canvas to TOML). From [000](000_overview.md). The read-only canvas is [210](210_canvas.md); editing on it would build on that.
- Canvas extras, if wanted: a run's status on each box, and routing arrows that skip rows around the boxes in between. From [210](210_canvas.md).
- Multi-tenant hosting. From [000](000_overview.md).
- Separate files-service logins per agent, or per-folder permissions. From [090](090_workflow_files.md).
- Collapsible folder groups on the Workflows page. From [110](110_workflow_folders.md).
- An MCP client node/capability, only if widely requested — found migrating Decapod's workflows, but MCP itself is still unsettled enough (powerful, but not widely adopted) that it's not worth building speculatively.
