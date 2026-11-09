Follow the repo's [`OP-PARAMS.md`](../../OP-PARAMS.md) (version 2.0), scaled
down for a sample made only of workflows. Lee approved leaving out mutation
testing and CI, and whatever else doesn't fit (2026-11-09). This file adds
what's specific to Purple Goo.

| Binding | Purple Goo |
|---|---|
| **precommit** | `samples/purple-goo/check.sh`, from the repo root with the app running: every workflow loads with no problems, `goo_tests` passes, and the top monad streams |
| **test** | the `goo_tests` workflow (`tests/goo_tests/cases.exs` and `check.exs`), against `goo_fake_llm` |
| **coverage** | none; every rule in spec 010 has a case in `## Tests` instead |
| **mutation** | none (left out) |
| **security** | the repo's |
| **run** | copy the folder into the workflows folder |
| **CI** | none (left out) |
| **doc tool** | the `#` comment at the top of every `workflow.toml` and node `.toml` (shown on the canvas), and a comment at the top of every `.exs` |
| **docs** | `specs/`, `README.md` |
| **copies** | none |
| **branching** | the repo's |

- **The design doc wins.** Lee's `index — 1.11-agent` doc and his rulings
  are the source. If they and spec 010 disagree, report it; don't patch
  over it.
- **Test first, in workflows.** Add the behavior to spec 010's `## Tests`,
  then a case to `cases.exs` with its expected values written out in
  `check.exs`, then run the check and watch it fail for the reason you
  expect. Then build it.
- **Errors come back up.** Every stage that can fail ends its run
  (`on_fail = "end_run"`), and a run that ends with no output counts as an
  error. A run with a failed step otherwise ends `complete` with nothing,
  and the failure would vanish.
- **Name every route.** A step without `when` takes items on every route
  except `failed` and `overflow`, so when a step branches, give both
  branches a route and a matching `when`.
