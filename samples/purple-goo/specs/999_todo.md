# 999 — To do

Status: living
Created: 2026-11-09

## Planned

- **Batch size in `goo_map`.** The gather step's `size` is 1,000,000, so a
  list longer than that splits into several outputs. Raise it in
  `goo_map/gather.toml` if you need more; see `goo_map`'s `finish` step.
- **Client tools after a tool round.** The client's own tools are offered
  only on the top agent's first call; once a `run_workflow` round starts,
  the tool children can't hand a call back to the chat app. Making that
  work means answering the app mid-chain. See [030](030_tools.md) rule 5.
