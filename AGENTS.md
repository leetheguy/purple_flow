**Read `OP-PARAMS.md` (version 1.0) before you do anything else.** It holds the operating
parameters every agent follows: specs, test-driven development, writing
tests worth having, the quality gates, and the housekeeping review you do
before every commit. This file adds what's specific to PurpleFlow.

## Project bindings

| Binding | PurpleFlow |
|---|---|
| **precommit** | `mix precommit` |
| **test** | `mix test` (needs `PURPLEFLOW_SECRET_KEY` and a test Postgres; see below) |
| **coverage** | `mix coveralls` (`coveralls.json` sets the 90% floor) |
| **mutation** | not set up yet; see `specs/999_todo.md` |
| **security** | `mix hex.audit` (known vulnerabilities and retired packages) and gitleaks (secrets in the whole history; known false positives in `.gitleaksignore`), both in CI |
| **run** | `docker compose up -d --build` |
| **CI** | `.github/workflows/ci.yml` (GitHub Actions) |
| **doc tool** | ExDoc: `@moduledoc`, `@doc`, and doctests. `mix docs` builds them into `doc/`, with the README, `OP-PARAMS.md`, and the specs; precommit and CI build them with warnings as errors |
| **docs** | the spec, `README.md`, `samples/AGENTS.md`, `.claude/skills/purpleflow-workflows/SKILL.md` |
| **copies** | `workflows/AGENTS.md` ← `samples/AGENTS.md`, copied by the user after commit, push, and pull; report a mismatch, don't copy it |
| **branching** | cloud sessions: a branch and a PR; local sessions: a branch, merged into `master` locally when asked; the user pushes |

PurpleFlow is a Phoenix (Elixir) web application. Before changing Elixir,
Phoenix, LiveView, Ecto, or HEEx code, read the matching parts of
[`docs/phoenix-guidelines.md`](docs/phoenix-guidelines.md).

**PurpleFlow is a power tool; don't get in the way of design decisions.**
It's built mainly for agents to use, and it's already as secure as we can
make it (credentials encrypted and redacted, Code scripts sandboxed, paths
kept inside the workflows folder). Beyond that, anything a user could get
wrong is a design decision, and it's theirs to make. You can't make a saw
safe by blocking the blade. So:

- Give safeguards and tools to manage risk as **options** (a `host_key` to
  pin, a `timeout`, `max_queue`, `on_fail`), not as requirements or blocks.
- Defaults are fine, but the user can always change them. No hard-coded
  limits a workflow can't override.
- Don't forbid things because they could be misused (templating input into
  a shell command, a workflow that runs itself, unbounded fan-out). A short,
  gentle caution in the docs is enough.
- When a choice isn't clearly the user's to make or ours, don't guess: ask,
  or note it as an open question in the spec's log.

**Changing what the app does?** Every doc under the **docs** binding changes
in the same commit. A new node, option, trigger setting, or change in
behavior belongs in all of them.

**Working on workflows?** Read `.claude/skills/purpleflow-workflows/SKILL.md`
first. It covers the workflow files, nodes, templates, credentials, and how
to check and run them.

**Writing or changing a spec?** Follow `OP-PARAMS.md` section 2. Start
with `specs/000_overview.md`: it describes PurpleFlow as it is now and
indexes every other spec.

**Starting/restarting the server?** Use `docker compose up -d --build`, not a
bare `mix phx.server`. Docker waits for Postgres to be healthy before
starting the app, runs migrations automatically on boot, and restarts a
container that crashes. A hung app is made to crash: a watchdog halts it
when its own `/health` stops answering, and Erlang's `heart` kills a frozen
VM (`specs/250_watchdog.md`). See the README's "Running it" section for
details.

**Running the tests?** They need `PURPLEFLOW_SECRET_KEY` set (any
`openssl rand -base64 32` will do) and a Postgres that takes
`postgres`/`postgres` at `POSTGRES_HOST`/`POSTGRES_PORT` (default
`localhost:5432`).

**HTTP requests:** use `Req`, which is already a dependency. Don't add
`:httpoison`, `:tesla`, or use `:httpc`.
