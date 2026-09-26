# 070 — Code node sandbox

Status: implemented.

## Why

A Code node (see [020](020_nodes.md)) runs Elixir that an agent wrote. The
people writing Code nodes are meant to be agents building workflows, not
necessarily the same person who owns the credentials those workflows use.
An agent should be able to write and test a Code step freely, without that
step being able to read a secret it has no business seeing, or phone home
with one.

Inside the app's own container, a script can reach far more than its
`input` and `steps`: the app's modules (`PurpleFlow.Credentials`,
`PurpleFlow.Repo`), the container's environment variables — directly, or
through any same-user process's `/proc/<pid>/environ` — the database over
the network, and the internet. The BEAM has no in-VM security boundary that
closes all of that for arbitrary Elixir. A container does.

## What this spec covers, and what it doesn't

**Covers:** running every Code node script in a separate container that has
nothing worth reaching — no secrets, no database, no internet, no route back
to the app — while keeping Code steps as fast as plain in-process Elixir.

**Doesn't cover:** stopping a workflow from sending a credential it was
legitimately handed (via `{{ creds.NAME }}` in an HTTP node's config) to the
wrong place. That's per-credential allowed-host lists on the HTTP/Postgres
nodes, a separate control (see "Later").

**Doesn't cover:** a Docker or Linux kernel exploit. The runner is as
isolated as a locked-down container is, which is the same line every
container-based code runner draws.

## The runner

A second service in `docker-compose.yml`, `runner`, built from the same
image as the app but started with a different command. It runs one
long-lived BEAM VM, started once when the container starts, which does
exactly one thing: accept a script and its `input`/`steps`, evaluate it,
and send back the result.

- **Nothing to steal.** Its compose `environment:` block contains no
  secrets: no `PURPLEFLOW_SECRET_KEY`, `DATABASE_URL`, `SECRET_KEY_BASE`, or
  admin login, and no `env_file`. It never starts the web app, the database
  pool, or the scheduler. `config/runtime.exs` only requires the app's
  secrets when running as the app, so the runner starts without them (never
  with placeholder values standing in for them).
- **Nowhere to go.** It's attached to one network, `runner`, which is
  `internal: true` (no internet) and shared only with the app. It isn't on
  the network the database is on.
- **No Erlang distribution.** The app and the runner are the same release
  with the same baked-in cookie, so both run with
  `RELEASE_DISTRIBUTION=none`: there's no node for a script to connect to.
- **Locked down.** `read_only: true`, `cap_drop: [ALL]`,
  `security_opt: [no-new-privileges:true]`, the image's non-root user, and
  memory/CPU/process-count limits. The release writes its runtime config at
  boot, so `/tmp` is a tmpfs and `RELEASE_TMP` points there. `restart: unless-stopped`, so if a script manages to
  take the whole VM down, it comes back on its own.

## Talking to it: one direction only

The app connects to the runner, never the other way around. The runner
only ever answers requests the app makes.

- The app opens a TCP connection to the runner for each Code step
  execution, sends one request, reads one response, and closes it.
- Messages are length-prefixed JSON. Request: the script's source, `input`,
  and `steps`. Response: `{"ok": value}`, `{"ok": value, "route": name}`,
  or `{"error": message}`, mirroring the Code node's
  `{:ok, _}` / `{:ok, _, route}` / `{:error, _}` results. Code node outputs
  are JSON-shaped (see [020](020_nodes.md)), so nothing is lost in the
  encoding. Plain JSON, not Erlang distribution and not
  `:erlang.binary_to_term/1`: nothing the runner sends back can be more
  than data.
- The `runner` network has a fixed subnet in `docker-compose.yml`. The app
  rejects any inbound web request whose source address is in that subnet,
  before routing — so a script can't call the app's webhooks, UI, or
  anything else on it, even though the two share a network.

## Inside the runner

Each request is handled by its own Erlang process, which evaluates the
script with `Code.eval_string/3`, binding `input` and `steps`, and writes
back the result. There's no per-script VM boot: a Code step costs one local
network round trip plus the script's own running time.

- **Timeouts** are enforced where every step's are: `PurpleFlow.StepTask`
  enforces the step's `timeout` in the app and kills the step's task, which
  closes its connection. The runner kills a script's process when its
  connection closes, so a timed-out script stops running instead of
  lingering.
- **Crashes** in a script are contained to its own process and come back
  as `{"error": message}`.
- **Scripts share the runner VM.** Two scripts running at the same moment
  are in the same VM, so a deliberately malicious script could interfere
  with another script's run. That's accepted: it would take an agent
  deliberately writing an attack on other workflows, and the most it could
  reach is other scripts' data inside a box that has no secrets and no way
  to send anything anywhere.

`PurpleFlow.Nodes.Code.prepare/2` reads and parses the `.exs` file when the
workflow loads, so a syntax error shows up then, not mid-run. The runner
parses the source again on its side; it never receives an AST or any other
Erlang term from the app.

## Outside Docker

Development and `mix test` run without the compose stack. When no runner
address is configured, the app starts the same runner server inside its
own VM and talks to it over localhost, so the protocol, the timeouts, and
the result handling are all exercised exactly as in production — only the
isolation is missing, and the app logs a warning at boot saying so. In a
release, a missing runner address is a boot error, not a fallback.

## Verified

- `mix test` covers the protocol end to end against the in-VM runner:
  every result shape, script errors, a script killed by its step timeout,
  and the app rejecting a request from the runner subnet.
- Checked against the real compose stack (not reachable from `mix test`):
  a Code step runs; from inside a script, `System.get_env/1` finds none of
  the app's variables, `/proc` shows no app process, and connecting to the
  database, the app, or the internet fails.

## Later (explicitly out of scope for now)

- Per-credential allowed-host locks on the HTTP/Postgres nodes.
- A VM per workflow inside the runner, if scripts interfering with other
  workflows' scripts ever turns out to matter.
