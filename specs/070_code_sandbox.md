# 070 — Code node sandbox

Status: superseded by [100](100_runner_container.md).
Created: 2026-09-25

## Why

A Code node (see [020](020_nodes.md)) runs today via `Code.eval_quoted`, in the
same BEAM VM as the whole app. That script can currently do anything the app
itself can do: call `PurpleFlow.Env.get/1` to read a credential,
`System.get_env/1` to read the container's raw environment, query
`PurpleFlow.Repo` directly, or open a socket to anywhere and send whatever it
wants. There's no line between "runs a small transform" and "has the app's
full trust."

The people writing Code nodes are meant to be agents building workflows, not
necessarily the same person who owns the credentials those workflows use.
Credentials themselves are a separate system (encrypted at rest, edited
through a UI a human controls — see the credentials spec once it exists).
That system is unaffected by this one: the app still needs to read
credentials to actually call the APIs a workflow uses, and this spec doesn't
change how it does that. What this spec is about is the much narrower
question of what an agent-written *Code* step, specifically, should be able
to reach — nothing that step doesn't already have as `input`/`steps`. An
agent building a flow should be able to write and test a Code step freely,
without that step being able to read a secret it has no business seeing, or
phone home with one on its own initiative. This isn't about distrustful
workflow *authors* — it's about not leaving a wide-open door in case something
in that position ever misbehaves, deliberately or not.

Encrypting credentials at rest doesn't touch this. The app has to decrypt a
credential to use it, so anything that can act *as* the app can decrypt it
too. The only thing that actually closes this hole is not letting Code node
execution act as the app in the first place.

## What this spec covers, and what it doesn't

**Covers:** stopping a Code node from reading ambient secrets (env vars,
`PurpleFlow.Env`, the database) or the app's other internal state, by running
the script somewhere that simply doesn't have them.

**Doesn't cover:** stopping a workflow from sending a credential it was
legitimately handed (via `{{ creds.NAME }}` in an HTTP node's config, once the
credentials system exists) to the wrong place. That's a separate control —
per-credential allowed-host lists on the HTTP/Postgres nodes — tracked
separately, not solved by sandboxing Code.

**Doesn't cover:** a full container-escape-resistant sandbox. This design
assumes the sandboxed process is still on the same machine, same kernel, same
filesystem as the app. It stops a Code script from reading secrets *through
the app's own APIs and ambient environment*. It does not stop, say, a kernel
exploit. If that bar is ever needed, the follow-up is a separate container
with its own network namespace (see "Later" below).

## Approach: a separate OS process per execution, via `:peer`

Erlang/OTP ships a stdlib module, `:peer`, built for exactly this: starting a
second, independent BEAM node as its own OS process, controlled from the
parent over a plain stdio pipe (`connection: :standard_io` — no TCP port, no
distribution cookie, nothing network-reachable). This is the mechanism
`iex --remsh` and Erlang's own test tooling are built on; it isn't exotic.

Why this instead of shelling out to a bare `elixir script.exs`: the release
image is a compiled Mix release with its own bundled ERTS, but no standalone
`elixir` CLI installed (that would mean shipping the whole Elixir toolchain
in the runner image just to run one script). The release already carries
Elixir's own compiled `.beam` files as an OTP application, though, and `:peer`
lets a fresh node start with **only those** on its code path — not the app's
own `_build`/`lib` directory. A peer node built this way can run any Elixir
expression, but literally cannot `Code.ensure_loaded?(PurpleFlow.Env)`, because
`PurpleFlow.Env` was never on its code path to begin with. This was confirmed
against a live prototype (see "Verified" below).

A plain `:peer.start(%{env: []})` is **not** enough on its own. `:peer`'s
`env` option, like the underlying `erlang:open_port/2` option it maps to,
only *adds* entries on top of whatever the OS would normally hand a new child
process — it doesn't replace the child's environment. A peer node started
that way still inherits the parent's full environment, `DATABASE_URL`,
`SECRET_KEY_BASE`, and everything else included, and a script running on it
can read all of it via plain `System.get_env/1`. `System.get_env/1` is core
Elixir (a thin wrapper over the `:os.getenv/1` BIF) — it isn't something
restricting the code path can touch, since it's not app code, it's the
language itself, and it's loaded on any BEAM node by definition.

The actual fix is to stop the leak at the OS level, before any BEAM code
starts running at all: launch the peer's `erl` through `env -i`, which execs
its argument with a deliberately empty environment. `:peer` supports this
via its `exec` option, which replaces the executable it launches:

```elixir
exec: {System.find_executable("env"), [~c"-i", System.find_executable("erl")]}
```

With this, the peer process starts with none of the parent's environment
variables. The only entries present afterward are the handful `erl`'s own
launcher script sets for itself to find its own install (`ROOTDIR`,
`BINDIR`, `EMU`, `PROGNAME`) plus `PATH` and `PWD` — no app secrets, because
they were never in the process's environment block to begin with.

Each Code node execution:

1. Starts a fresh `:peer` node, **linked** to the calling process
   (`:peer.start_link/1`, not `:peer.start/1` — see "why linked" below):
   non-distributed, stdio-connected (`connection: :standard_io`, so no TCP
   port or distribution cookie ever exists), launched via the `env -i`
   wrapper above, with its code path restricted to
   Elixir/EEx/Logger/Compiler's `ebin` directories only (not the app's own
   `_build`/`lib`).
2. Sends it the already-parsed AST (from `PurpleFlow.Nodes.Code.prepare/2`,
   unchanged) plus `input` and `steps`, via `:peer.call/5` with `:infinity`
   as the timeout (see "why infinity" below).
3. Reads back `{:ok, _}` / `{:ok, _, route}` / `{:error, _}` exactly as today.
4. Tears the peer down (`:peer.stop/1`), whether it succeeded, errored, or
   timed out.

The outer per-step timeout in `PurpleFlow.StepTask` (`Task.yield` /
`Task.shutdown(inner, :brutal_kill)`) stays as-is and is the only timeout
that actually applies — if the peer wedges, the existing task-level kill
is what stops it. Two details make that true, both non-obvious enough to be
worth stating outright:

**Why `:infinity`, not a timeout of its own:** `:peer.call/4` (the arity
without an explicit timeout) defaults to 5 seconds. A step's configured
`timeout` can legitimately be longer than that, so leaving `:peer.call` at
its default would silently cut Code node steps down to 5 seconds regardless
of what the workflow asked for. `:peer.call/5` is used instead, with
`:infinity`, so the *only* timeout in effect is the step's own, enforced
where it always was.

**Why `start_link`, not `start`:** `:peer.start/1`'s controlling process is
explicitly *not* linked to its caller (that's the entire difference between
`start/1` and `start_link/1`). `PurpleFlow.StepTask` kills a wedged step
with `Task.shutdown(inner, :brutal_kill)`. A `:brutal_kill` delivers a real
exit signal to processes linked to the one being killed, but does nothing
for unlinked ones. Started with plain `:peer.start/1`, a timed-out or
crashed Code node leaves its peer's `erl` OS process running forever,
orphaned — including whatever the script was still doing when the step
"timed out." `:peer.start_link/1` ties the peer's lifetime to the step's
task, so killing the task also kills the peer.

This replaces `Code.eval_quoted` inside `PurpleFlow.Nodes.Code.execute/3`
only. Nothing about the node's public contract, its `.toml`/`.exs` file
shape, or its `prepare/2` step changes.

## Verified

Confirmed by an interactive prototype while designing this, then again by
automated tests that run for real on every `mix test`:

In `test/purple_flow/nodes_test.exs` ("Code" describe block):

- A `:peer` node with its code path limited to Elixir's own `ebin`
  directories evaluates arbitrary Elixir correctly, and existing Code node
  behavior (input/steps binding, `{:ok, _}` / `{:ok, _, route}` / `{:error,
  _}` / plain-value results) is unchanged.
- A Code script cannot read this app's environment variables — the "can't
  read this app's environment variables" test sets one, runs a script that
  calls `System.get_env/1` for it, and asserts `nil` comes back.
- A Code script cannot reach this app's modules — the "can't reach this
  app's modules" test runs a script calling
  `Code.ensure_loaded?(PurpleFlow.Env)` and asserts it returns `false`.

In `test/purple_flow/nodes/code/sandbox_test.exs`:

- Killing the process that called `Sandbox.eval_quoted/2` also kills the
  peer's OS process. The test starts a script that sleeps for a minute,
  `Process.exit(caller, :kill)`s the calling process the same way
  `Task.shutdown(_, :brutal_kill)` would, and asserts no process matching
  `-user peer` (the flag every `:peer` node runs with) is still running
  afterward. Checked against `pgrep`, not just Elixir-level bookkeeping,
  since the thing being verified is a real OS process exiting. This test
  was confirmed to actually fail (one leaked process) when `start_link` was
  swapped back for plain `start`, before being left in its fixed state.

The prototype additionally confirmed, before the `env -i` fix was in place,
that the leak was real: a peer started with only `:peer`'s own `env: []`
option (no wrapper) could still read a secret from the app's environment.
That failure mode doesn't have a standing regression test — the shipped code
never takes that path — but it's why the `env -i` wrapper exists rather than
relying on `:peer`'s `env` option alone.

## Later (explicitly out of scope for now)

- Pooling peer nodes instead of starting one fresh per execution, if per-run
  startup cost turns out to matter.
- Moving Code execution into a genuinely separate container (its own network
  namespace, no route to the credentials database at all), for defense
  against a kernel/BEAM-level escape rather than just an app-API-level one.
- Resource limits (memory/CPU caps) on the peer node, beyond the existing
  step timeout.

## Log

- 2026-09-25 — [080](080_credentials.md): `PurpleFlow.Env`, named above, no longer exists. Credentials live in `PurpleFlow.Credentials`, which is just as unreachable from the peer.
- 2026-09-26 — Fixes found in review: Code nodes failed in the Docker release, because the peer's bundled `erl` looked for `bin/start.boot`, which Mix releases don't ship. The peer boots the release's `start_clean.boot` (with `RELEASE_LIB` set). That boot file puts every app in the release on the code path, so the peer's code path is replaced outright with kernel/stdlib/compiler/elixir/eex/logger via `:code.set_path/1`, and a test asserts the exact path.
- 2026-09-26 — Superseded by [100](100_runner_container.md). A script on the peer could still read the app's secrets through `/proc/1/environ`, because the peer runs on the same machine as the app, and nothing in this design closes that. Code scripts run in a separate runner container instead. This is the "genuinely separate container" item in "Later" above.
