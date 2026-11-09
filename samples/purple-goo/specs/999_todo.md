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

## Open questions

- **Data injectors run at once, not one by one.** The design doc says
  "calls each … in order". `goo_map` keeps results in list order but runs
  the calls at the same time. Is order of results enough, or do injectors
  with side effects need to run one after another? See [010](010_monad.md)
  rule 5.
- **One caller or two.** The doc names a data caller and a monad caller.
  Both are the same shape, so `goo` uses one `goo_map` for both. Split them
  if they ever need to differ.
- **What a child inherits.** Rule 2 of [010](010_monad.md) gives a child
  only its subtree, so `provider_url` has to be set in every subtree that
  doesn't use the default. Should provider settings inherit?
