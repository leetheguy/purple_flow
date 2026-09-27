# 120 — Flow

Status: draft
Created: 2026-09-27
Replaces: [030](030_runs.md)

Items flow through a run one at a time. Every step has a queue in front of it. When an execution finishes, what it produced goes straight into the queues of the steps after it, and those steps start on it right away. Nothing waits for a whole step to finish.

This is the OTP way: many small processes, each doing its job, telling each other when they're done. The engine gives authors a few controls (`concurrency`, `delay`, `max_queue`) and otherwise gets out of the way. How much to run, how fast, and in what order are design decisions for whoever writes the workflow, not limits the engine sets for them. See the guidelines in `samples/AGENTS.md` and the `purpleflow-workflows` skill.

## Items

- **An item is one JSON-shaped value.** One item, one execution: a node is always called with exactly one item as its input.
- **A list splits.** When a node returns a list, each element becomes its own item. An empty list is zero items. Only the top level splits: `[[1, 2], [3]]` is two items, `[1, 2]` and `[3]`.
- **Anything else is one item**, including an object that holds a list. `{"rows": [...]}` travels as one item, and the next step gets all of it in one execution. That's how a group moves as a group: wrap it. The Batch node ([140](140_batch.md)) does exactly this.
- **The trigger's input** is treated like a node's output: a list splits into items for the first steps, anything else is one item.
- A node can also hand over items while it's still running, instead of all at once when it returns. See [150](150_streaming.md).

## Steps and queues

Every step has a queue. Items produced by the steps in its `after` (on the right route, see below) go to the back of it. The step takes items from the front and starts one execution per item, as long as:

- fewer than `concurrency` of its executions are running,
- at least `delay` milliseconds have passed since it last started one, and
- no step directly after it is full and set to wait (see **Backpressure**).

Step settings in `workflow.toml`:

| Field | Default | Meaning |
|---|---|---|
| `concurrency` | `1000` | Most executions of this step running at once, across the whole run. A number, 1 or more. `1` runs one at a time, in queue order. |
| `delay` | `0` | Milliseconds between starts of this step's executions, across the whole run. `delay = 100` is at most 10 starts a second. |
| `timeout` | `0` | Seconds one execution may take before it's stopped. `0` means no limit. |
| `max_queue` | none | The most items that may wait in this step's queue. No limit if left out. |
| `on_full` | `"wait"` | What happens when the queue is at `max_queue`: `"wait"` or `"overflow"`. Only with `max_queue`. |
| `on_fail` | `"continue"` | What a failed execution does to the run. See [130](130_failures.md). |

`concurrency` and `delay` count every execution of the step in the run, however many items arrive and from however many branches.

`run` (`"each"`/`"all"`) is gone, and so are the words `"sequential"` and `"concurrent"` for `concurrency`. A workflow that still uses them fails to load, with a message saying what to use instead.

## Backpressure

With `on_full = "wait"`, a full queue holds back the steps that feed it. A step doesn't start a new execution while any step directly after it has a full queue and is set to wait. That holding back travels up the chain by itself: once this step stops starting, its own queue fills, and so the step before it stops too.

- A full queue holds back every step feeding it, and a step is held back by any full step after it, whichever branch it's on. After a fork, one slow branch slows the other.
- It stops *new* executions. An execution already running still delivers everything it returns, so a queue can go over `max_queue` for a moment.
- A node handing over items while it runs ([150](150_streaming.md)) waits at the hand-off until there's room.

With `on_full = "overflow"`, an item that arrives at a full queue doesn't go in. It goes down this step's `overflow` route instead: steps with `after = ["this step"]` and `when = "overflow"` get it. An overflowed item with no such step is dropped. Either way, it's saved as a record with status `overflow` on the full step, so it shows up.

## Routes

A node can return `{:ok, output, "route"}`. Every item from that execution takes that route. A step with `when = "route"` gets only items that took its route. A step without `when` gets every item, whatever its route, except items on `failed` and `overflow`.

Two route names are the engine's own:

- **`failed`**: an execution that fails sends `{"error": message, "input": the item}` down it. See [130](130_failures.md).
- **`overflow`**: items that didn't fit in a full queue, as they arrived. See **Backpressure**.

`when` still needs exactly one `after`.

## Several `after` steps

A step with several `after` steps gets items from all of them, into the same queue, one execution per item. There's no joining: after parallel branches, it runs once per item from each branch.

## Earlier outputs follow the item

Each item remembers the path it took. `{{ steps.fetch.output }}` (and the Code node's `steps["fetch"]["output"]`) is the item `fetch` produced on the way to *this* item, not everything `fetch` produced.

- If `fetch` returned a list of 500 users, the item for user 7 sees user 7 as `steps.fetch.output`.
- If `fetch` returned one object, that object is its item, and every item after it sees the same one.
- Only ancestors can be referenced, as before, and that's checked at load time. An ancestor the item didn't pass through (the other side of a branch) fails the execution.
- Items produced on a `failed` or `overflow` route count as produced by the step they came from.

## The run's end

The run is over when nothing is queued, running, or waiting in a batch anywhere. It doesn't matter how many items went through, or in what order.

**Its output** comes from the last steps (the ones nothing comes after) that ran:

- A step that ran once: that execution's output.
- A step that ran more than once: every item its executions produced, as one flat list, in the order the executions started.
- One last step ran: the output is that. Several: `{"step": output, ...}`, counting only the ones that ran. None: `null`.

The 10,000-item cap is gone.

## Records

One `step_runs` row per execution, as before, with `item` numbering the step's executions in the order they started (0, 1, 2, …), and `from_item` saying which execution of the step before produced its input. A streamed execution's `output` is every item it produced ([150](150_streaming.md)).

**Saving is batched.** The run saves its step rows in one insert at most every 250 milliseconds, not one insert per execution, and saves any it still holds before it finishes. A run of 10,000 fast executions writes a few dozen inserts, not 10,000.

## Who does what

- **`PurpleFlow.Run`**: one GenServer per run. It holds the queues, starts executions, hears their results, routes the items, saves rows, and decides when the run is over. It's registered by run ID in `PurpleFlow.RunRegistry`, so it can be found to kill it ([130](130_failures.md)).
- **Executions**: one process per execution under `PurpleFlow.StepSupervisor`, started and watched by the run (`Task.Supervisor.async_nolink`). It fills the templates, calls the node, redacts credentials, and hands the result back. If it crashes, the run hears about it and records an error. If it goes over its `timeout`, the run kills it and records `timed_out`.

## Messages

| Topic | Message | When |
|---|---|---|
| `"run:<id>"`, `"runs"` | `{:run_started, id, workflow}` | the run starts |
| `"run:<id>"` | `{:run_progress, id, stats}` | at most every 250 ms while anything changed, right after the latest rows are saved |
| `"run:<id>"`, `"runs"` | `{:run_finished, id, status}` | the run ends |

`stats` is `%{"step" => %{queued:, running:, ok:, failed:, overflow:}}`. The per-execution `step_started` and `step_finished` messages are gone: a busy run would send thousands a second.

## Tests

Fixture workflows with the fake node, as before:

- straight line; a list splits and each item runs on its own; an object holding a list doesn't split
- items move on before the step before them is done (a fast item reaches the next step while a slow one is still running)
- `concurrency` caps running executions across the run; `concurrency = 1` goes in queue order
- `delay` spaces out starts
- `timeout = 0` never times out; a timeout stops the execution
- backpressure: with `max_queue` and `on_full = "wait"`, the step before holds back
- overflow: extra items take the `overflow` route and are recorded as `overflow`
- routes, and branches meeting again (once per item from each branch)
- `steps.X.output` is the item on this item's path
- the run's output, for one execution, several, and several last steps
- rows are saved in batches, and all of them are there when the run finishes
- old settings (`run`, `"sequential"`) fail to load with a clear message
