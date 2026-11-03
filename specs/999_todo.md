# 999 — To-do

Status: living
Created: 2026-09-28

The list of planned work and open questions, in one place. Like [000](000_overview.md), this spec is living: it's kept current, not kept as history. Add an item when something is planned or left open; delete it when it ships (the spec that ships it says so in its own text or log) or is dropped (say why in the commit). Each item links to where it came from.

It gathers the "Later" sections and open questions left in other specs and their logs. Those stay as they are, as history.

## Planned

- **More ways to handle files**, when needed: save an HTTP response as a file, send a file with the HTTP or Respond node, save SSH output as a file. The minimum (webhook uploads, SSH `stdin_file`) is in [190](190_run_files.md).
- **Retries.** An option per step to retry a failed item (`retries`, `retry_delay`), off by default. From [000](000_overview.md).
- **Waiting for all branches.** A step that runs once after all of its `after` branches finish, instead of once per item from each ([120](120_flow.md) has no joining). From [000](000_overview.md).
- **Per-credential allowed-host locks** on the HTTP, Postgres, and SSH nodes, as an option on the credential. From [080](080_credentials.md), [090](090_workflow_files.md), [100](100_runner_container.md).
- **Agent node**, wrapping purple_goo's agent call, and running purple_goo's pipeline as a workflow. From [000](000_overview.md).
- **Run-a-workflow endpoint for agents**, so testing a workflow doesn't need a webhook on it. From [090](090_workflow_files.md).
- **Run retention.** Runs and their step records are kept in Postgres forever, so the database only grows. An option to prune them after some age or count. (A run's files don't need it: they're deleted when the run ends, [190](190_run_files.md).)
- **Code scripts reading file bytes**, not just a file's reference, so a script can parse a file's contents (PDF, CSV, etc.) instead of only moving it around. Same gap as the "Code scripts and files" open question below; called out again because it's the one real blocker found migrating Decapod's workflows (n8n's Extract From File node).
- **Signed requests on the HTTP node** (starting with AWS SigV4, for S3), plus sending a file's bytes as a request body. Found migrating Decapod's workflows: S3 is popular enough elsewhere that it's worth solving for, even setting personal taste aside.

- **Code docs to OP-PARAMS section 7.** Add ExDoc as a dev dependency and build the docs in `mix precommit` with warnings as errors. Then bring the code docs up to the standard: an overview linking its spec on every module (4 of 68 have no `@moduledoc`), `@doc` on every public function, links to what they reference, and doctests where usage isn't obvious. From [OP-PARAMS.md](../OP-PARAMS.md).

- **Mutation testing**, for OP-PARAMS section 5: pick an Elixir mutation tool (muzak, exavier, or darwin; check which are maintained), add it as a test-only dependency, and bind it in `AGENTS.md`. From [OP-PARAMS.md](../OP-PARAMS.md).
- **Security scans in CI**, for OP-PARAMS section 5: `mix hex.audit` (it fails on known vulnerabilities) and a secret scanner such as gitleaks, both in `.github/workflows/ci.yml`. `mix.lock` is already committed.
- **Update vulnerable dependencies.** On 2026-11-03, `mix hex.audit` found advisories against bandit 1.12.5 (11 high, 3 medium; 1.14.1 is out), mint 1.10.1 (1 high, 2 medium), phoenix_html 4.3.0, plug_crypto 2.2.0, decimal 3.1.1 (medium), and lazy_html 0.1.12 (low, test only). Update them and run the full test suite and a check against the deployed stack. From [OP-PARAMS.md](../OP-PARAMS.md).

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
- A visual workflow builder (canvas to TOML). From [000](000_overview.md). The read-only canvas is [210](210_canvas.md); editing on it would build on that.
- Canvas extras, if wanted: a run's status on each box, and routing arrows that skip rows around the boxes in between. From [210](210_canvas.md).
- Multi-tenant hosting. From [000](000_overview.md).
- Separate files-service logins per agent, or per-folder permissions. From [090](090_workflow_files.md).
- Collapsible folder groups on the Workflows page. From [110](110_workflow_folders.md).
- An MCP client node/capability, only if widely requested — found migrating Decapod's workflows, but MCP itself is still unsettled enough (powerful, but not widely adopted) that it's not worth building speculatively.
