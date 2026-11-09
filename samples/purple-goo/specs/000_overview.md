# 000 — Purple Goo overview

Status: living
Created: 2026-11-09

## What it is

Purple Goo is a society of mind built out of PurpleFlow workflows. Each AI
call (a **monad**) can hear from other monads before it answers, and their
answers become its thoughts. One recursive workflow is the whole stack. It's
for builders who want an AI with an internal world, and for chat apps that
speak OpenAI's API.

## The model

1. A monad is one call to `goo`: an OpenAI chat request plus `metadata`.
2. A monad with children is a synthesizer; the children's answers are its
   thoughts. Children can have children.
3. A child gets only its own metadata subtree.
4. Nothing injected is returned upward; a parent sees only responses.
5. Errors are returned, never swallowed.
6. Only the top monad streams.

The details are in [010](010_monad.md).

## Rules

- Follows the repo's `OP-PARAMS.md`, scaled down (see `../AGENTS.md`).
- No termination guardrails, no imposed telemetry. Metadata is open.

## Architecture

| Folder | Workflow | What it does |
|---|---|---|
| `goo/` | `goo` | the monad: open, inject data, hear children, call the AI, denormalize, close |
| `goo_map/` | `goo_map` | calls a list of workflows, returns outputs in order, errors as data |
| `goo_chain/` | `goo_chain` | runs workflows one after another on a frame |
| `tests/goo_tests/` | `goo_tests` | the test suite, as a workflow |
| `tests/goo_fake_llm/` | `goo_fake_llm` | a fake OpenAI provider that echoes what it got |
| `tests/fixtures/` | `goo_test_*` | small data, opening, and closing workflows the tests use |

## Dependencies

PurpleFlow, with the OpenAI Chat, Workflow, Batch, Code, and Noop nodes,
and the `OPENROUTER_API_KEY` credential.

## Specs

| Spec | Status | Summary |
|---|---|---|
| [000](000_overview.md) | living | this overview |
| [010](010_monad.md) | implemented | the monad: metadata, order of work, callers, errors, streaming |
| [999](999_todo.md) | living | planned work and open questions |
