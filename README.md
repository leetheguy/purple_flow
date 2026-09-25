# PurpleFlow

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

You need Elixir and Postgres (dev login `postgres` / `postgres` on localhost).

```sh
mix setup          # install deps, create the database
mix phx.server     # http://localhost:4000
mix test
```

- Workflows live in `workflows/`. Two examples are included: `hello` (webhook, per-item routes) and `users` (HTTP, per-item).
- Credentials go in `.env` (see `.env.example`) and are used as `{{ env.NAME }}`.
- After editing workflow files, hit **Reload** on the home page.

The design is in [specs/](specs/000_overview.md).
