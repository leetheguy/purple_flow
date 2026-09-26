# Purple Flow

## Human written intro

Purple Flow makes building workflows as easy for AI as n8n makes automation for people.

I love n8n with all of my heart. It's an amazing tool that's quick to learn, quick to master, and so fun and easy to build with.

But, like every solution at all ever, it has its limitations. For me, those limitations looked like:

- Stripped down AI Agent output (I want the full OpenAI JSON without an http request please)
- Limited streaming ability
- AI reasoning challenges (not much training data; most tutorials are video; MCP can be confusing for light models)
- Latency issues
- No self-hosted middle rungs between "just me" and business for (currently) $960 per month
- No Git version control without enterprise
- Scalability and licensing challenges (can't easily turn your solution into a SaaS or sell it)

So I built Purple Flow. It's a minimal, first-principles reimagining of n8n made with Elixir. I borrowed the architectural decisions I loved and built everything else from scratch using OTP efficiency and reliability.

All the workflows and nodes are plain-text TOML files. Easy for agents to reason about while still being human readable.

Most n8n nodes are convenience wrappers for APIs. Many of them don't cover every use case and you need to drop down to http requests anyway. AI can easily look up APIs and generate http requests for them, so no convenience wrappers are needed. Here's what you get instead:

- triggers
  - webhook
  - cron
  - manual
- nodes
  - http - your trusty http request node
  - postgres - only one db for now; but http can cover anything with a REST interface
  - code - just a reference to an actual .exs code script
  - workflow - calls sub-workflows to keep things tidy and reusable
  - if/else - except not really a node; flow control is a natural part of workflows

---

Because you own everything, you can build full workflows for distribution to clients. And you can manage version control however you like.

Because this is built on the BEAM VM, you can scale your workflows to thousands of simultaneous executions. (And that's conservative if you're careful.) That means you can turn a convenient personal tool into paid SaaS with just a little elbow grease.

## AI written intro

A barebones n8n on Elixir/OTP. Workflows are TOML files in git.

```
trigger (webhook / cron / manual)
  -> run walks the workflow's steps
  -> each step runs a node: one input in, one output out
  -> list input? the node runs once per item, in parallel (or once for all)
  -> results are always one flat list
  -> every execution saves its own record and broadcasts "done"
  -> the run starts whatever's next
  -> any failure stops the run; everything so far is already saved
```

Built-in nodes: HTTP, Postgres, Code, and "run another workflow". A new node type is just a module implementing `execute(input, config)`.

The UI is an execution history viewer (Phoenix LiveView). Pick a run and see every step's input and output.

## Running it

The supported way to run PurpleFlow is Docker Compose:

```sh
mkdir -p workflows && git init workflows   # once, before the first `up`
docker compose up -d --build   # http://localhost:4000, files on http://localhost:5000
docker compose down
```

This starts PurpleFlow, Postgres, the Code node runner, and the files service
together. Postgres
has a health check, and the app container only starts once it passes;
migrations run automatically on boot, and the container restarts on its own if
the app dies. Code node scripts run in the `runner` container, which has no
secrets, no database, no internet, and no way to reach the app (see
[specs/100](specs/100_runner_container.md)). See
`docker-compose.yml` and `.env.example` for the environment variables to set
(`SECRET_KEY_BASE`, `PURPLEFLOW_SECRET_KEY`, `PURPLEFLOW_ADMIN_USERNAME`,
`PURPLEFLOW_ADMIN_PASSWORD`, `PURPLEFLOW_FILES_USERNAME`,
`PURPLEFLOW_FILES_PASSWORD`, and optionally `PHX_HOST`, `DATABASE_URL`,
`WORKFLOWS_PATH`, `FILES_PORT`, `PUID`/`PGID`, `PURPLEFLOW_AGENT_TOKEN`, and
`PURPLEFLOW_RUNNER_SUBNET` if the runner's default network, `10.250.250.0/24`,
collides with one of yours).

### Workflow files

Workflows live in their own folder, `workflows/` by default (`WORKFLOWS_PATH`
points it anywhere). It's yours: this repo ignores it, and it's meant to be
its own git repository. Nothing commits automatically; you manage its history.

- **The app only reads it** (mounted read-only) and picks up every change on
  its own within about two seconds. There's no reload step. If an edit breaks
  a workflow, the last version that loaded keeps running, and the home page
  says so.
- **People and agents edit it through the files service** (dufs), with its
  own login (`PURPLEFLOW_FILES_USERNAME` / `PURPLEFLOW_FILES_PASSWORD`): a web
  UI at `http://localhost:5000`, plain HTTP (`PUT` to write a file, `DELETE`,
  `GET /folder/?json` to list), and WebDAV for mounting it as a folder. It
  never sees the folder's `.git`.
- **Agents check their changes** at `GET /api/workflows` on the app, with
  `Authorization: Bearer $PURPLEFLOW_AGENT_TOKEN`: what loaded, what didn't,
  and why.
- A step's `node` and a Code node's `file` must stay inside the folder:
  relative paths only, and relative symlinks only.

Create the folder and run `git init` in it before the first `docker compose
up`. Otherwise Docker creates it, and its empty `.git`, owned by root.

See [specs/090](specs/090_workflow_files.md).

For local development without Docker, you need Elixir and Postgres (dev login
`postgres` / `postgres` on localhost):

```sh
mix setup          # install deps, create the database
mix test
mix phx.server      # http://localhost:4000
```

Outside Docker there's no runner container, so Code node scripts run inside
the app's own VM, with no isolation. The app logs a warning at boot saying so.

- Workflows live in `workflows/` (see "Workflow files" above), and edits there load on their own in dev too. Two annotated examples live in `samples/`: `hello` (webhook, per-item routes) and `users` (HTTP, per-item). Copy one into `workflows/` to try it.
- Credentials are set at `/credentials` and used as `{{ creds.NAME }}`. See [specs/080](specs/080_credentials.md).

The design is in [specs/](specs/000_overview.md).

## License

[MIT](LICENSE) © 2026 [Lee Nathan](https://leenathan.com)
