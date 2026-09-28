# 180 — Noop, Wait, and Respond nodes

Status: implemented
Created: 2026-09-28

Three small built-in nodes. Each hands its input on unchanged, so it can sit anywhere in a workflow without reshaping the items that pass through it.

## Noop

```toml
module = "PurpleFlow.Nodes.Noop"
```

Does nothing. No config. Useful as a named place for branches to meet, a placeholder while a workflow is being built, or a last step that makes a run's output obvious.

## Wait

```toml
module = "PurpleFlow.Nodes.Wait"

[config]
ms = 5000                          # wait this many milliseconds
# or:
until = "2026-10-01T09:00:00Z"     # wait until this time
```

- Exactly one of `ms` or `until`; a workflow with both or neither fails to load.
- `ms` is a number, 0 or more (text holding a number works, for templates).
- `until` is an ISO 8601 time with an offset (`Z` or `+02:00`), or a TOML date-time. A time already past doesn't wait.
- Both take templates: `ms = "{{ input.retry_after_ms }}"`. Plain values are checked at load time; templated ones when the step runs, and a bad one fails that item.
- Each item waits on its own, so with the step's default `concurrency` many items wait at once. `concurrency = 1` makes them wait in turn.
- The step's `timeout` covers the wait, and Kill stops it.
- A wait lives in memory. A restart marks the run `interrupted` ([130](130_failures.md)), like any other run cut off, so very long waits are at the mercy of restarts.

A step's `delay` paces starts across a run; Wait holds each item for a time. They combine.

## Respond

Answers the webhook that started the run, now, while the run carries on. Like n8n's "Respond to Webhook".

```toml
module = "PurpleFlow.Nodes.Respond"

[config]
status = 200                                       # default 200
headers = { "x-request-id" = "{{ input.id }}" }    # optional
body = { ok = true, id = "{{ input.id }}" }        # default: this step's input
```

- A text `body` is sent as is, as `text/plain` unless `headers` sets a `content-type`. Anything else is sent as JSON.
- `status` is 100 to 599. Header names are lowercased; values are one line of text (numbers and booleans become text). Bad values fail the item, and nothing is sent.
- The reply isn't redacted: it's what the workflow chose to send, like an HTTP node's request body. The step's saved record is redacted as usual.
- The `x-run-id` header is always added.

### Who it answers

It answers only a caller that's waiting on the run: a webhook with `respond = "result"` (the default). The **first** Respond step to run answers, and the run goes on without the caller. After that, and in any run nobody is waiting on, a Respond step answers no one and just hands its input on:

- webhooks with `respond = "immediately"` (already answered) or `respond = "stream"`
- cron, the UI's Run button, `PurpleFlow.run/3`
- a run started by the Workflow node: a child's Respond step never answers the parent's caller

A run that ends before any Respond step runs answers with its output, as `respond = "result"` always has ([040](040_triggers.md)'s log). So adding a Respond step to a workflow needs no other change.

Since a Respond step may run once per item, a step reached by many items answers with the first to get there. Put it where exactly one item passes, or after a Batch step, when that matters.

### How the answer travels

- The webhook controller starts the run with `respond_to: self()` and waits in `PurpleFlow.run_and_wait/3`, which returns `{:responded, reply}` if a Respond step answers before the run ends.
- `PurpleFlow.Node.respond(reply)` is the node side. `PurpleFlow.StepTask` sets it up, like `emit/2`: it asks the run, which sends `{:run_respond, run_id, reply}` to the waiting caller once and forgets it. It returns `:ok` if the reply went to a caller, `:none` if nobody was waiting. Outside a run (a test calling `execute` directly) it sends `{:respond, reply}` to the calling process.

## Tests

- **Noop:** hands its input on.
- **Wait:** `ms` waits at least that long; `ms` as text; `until` in the future waits, in the past doesn't; bad values are errors; `prepare` wants exactly one of the two and checks plain values, not templates.
- **Respond:** default reply is the input with status 200; config sets status, headers (lowercased), and body; bad status or headers are errors and send nothing; `prepare` checks plain values.
- **Webhook:** a Respond step's status, headers, and JSON body reach the caller while the run is still running; a second Respond step answers no one and the run ends `complete`; a text body is sent as text.
