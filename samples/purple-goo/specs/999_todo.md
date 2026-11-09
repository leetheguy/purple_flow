# 999 — To do

Status: living
Created: 2026-11-09

## Planned

- **The Purple Flow tool and its instruction sheet** ("one tool lazy-loads
  many skills; each skill is a subworkflow"), injected by default, with
  tool calls run inside `goo` (call the subworkflow, add the result, call
  the AI again). For now, tools and tool results pass through to the
  provider and back to the client unchanged. From the design doc's
  normalizer and "AI agent call" sections; see [010](010_monad.md).
- **Batch size in `goo_map`.** The gather step's `size` is 1,000,000, so a
  list longer than that splits into several outputs. Raise it in
  `goo_map/gather.toml` if you need more; see `goo_map`'s `finish` step.
