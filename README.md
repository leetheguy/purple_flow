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
docker compose up -d --build   # http://localhost:4000
docker compose down
```

This starts PurpleFlow and Postgres together. Postgres has a health check, and
the app container only starts once it passes; migrations run automatically on
boot, and the container restarts on its own if the app dies. See
`docker-compose.yml` and `.env.example` for the environment variables to set
(`SECRET_KEY_BASE`, `PHX_HOST`, Postgres credentials).

For local development without Docker, you need Elixir and Postgres (dev login
`postgres` / `postgres` on localhost):

```sh
mix setup          # install deps, create the database
mix test
mix phx.server      # http://localhost:4000
```

- Workflows live in `workflows/`, mounted into the container as a volume so you can edit them on the host. Everything directly under `workflows/` is yours and gitignored — nothing you build there gets committed to this repo. Two annotated examples live in `workflows/samples/` (tracked, part of the repo): `hello` (webhook, per-item routes) and `users` (HTTP, per-item). Copy one into `workflows/` to try it — the app only loads workflows one level under `workflows/`, not `workflows/samples/` itself.
- Credentials are set at `/credentials` and used as `{{ creds.NAME }}`. See [specs/080](specs/080_credentials.md).
- After editing workflow files, hit **Reload** on the home page.

The design is in [specs/](specs/000_overview.md).

## License

[MIT](LICENSE) © 2026 [Lee Nathan](https://leenathan.com)
