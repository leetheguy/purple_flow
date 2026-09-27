# 140 — Batch

Status: implemented
Created: 2026-09-27

Items flow one at a time ([120](120_flow.md)). Some steps want many at once: a bulk insert, a summary, an API that takes 100 records per call. The Batch node gathers items and hands them on as one.

```toml
# chunk.toml
module = "PurpleFlow.Nodes.Batch"

[config]
size = 100      # hand on a batch as soon as it has this many items
wait = 2000     # optional: or once the oldest item has waited this many milliseconds
```

It's a step like any other in `workflow.toml` (`name`, `node`, `after`, `when`). Its output is one item:

```json
{"items": [<item>, <item>, ...]}
```

An object, so it doesn't split again: the step after it gets the whole batch in one execution, as `input.items`.

After a batch, `{{ steps.X.output }}` ([120](120_flow.md)) still works for any earlier step whose output every item in the batch shares, like a single `fetch` that all of them came from. Earlier steps where the items differ can't be referenced past the batch; they're in `input.items` instead.

## When a batch goes

A batch is handed on as soon as any of these happens:

- it has `size` items
- its oldest item has waited `wait` milliseconds (if `wait` is set)
- nothing more can reach it: none of the steps before it, all the way back, have anything queued, running, or waiting in a batch of their own

So the last, smaller batch always goes. `size = 100` over 1,005 items makes ten batches of 100 and one of 5. Nothing is ever left behind when a run ends normally. When a run is killed or ends on a failure, what's waiting in a batch is dropped ([130](130_failures.md)).

## How it's different

The Batch node is a node module (`PurpleFlow.Nodes.Batch`) so it's set up like one, but the run treats it specially: items going to a Batch step collect in its batch instead of each starting an execution. Handing on a batch is recorded as one execution, whose input is the list and whose output is `{"items": [...]}`. It can't fail, and `concurrency`, `delay`, `timeout`, `max_queue`, and `on_fail` don't apply to it.

`size` must be a whole number, 1 or more. `wait`, if set, must be a whole number of milliseconds, 1 or more. Both are checked when the workflow loads.

## Tests

- full batches go as soon as they're full, before the steps before them are done
- the last, partial batch goes when nothing more can reach it
- `wait` sends a partial batch while more is still coming
- the output is one object, and the next step runs once per batch
- earlier outputs all the items share can still be referenced after the batch
- bad `size` or `wait` fails to load
