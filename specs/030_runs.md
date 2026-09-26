# 030 — Runs

Status: draft
Created: 2026-09-25

## Who does what

- **`PurpleFlow.Run`**: one GenServer per run. It decides what starts next, and that's all it does.
- **Node executions**: one task per execution under `PurpleFlow.StepSupervisor`. The run hands each task its input plus earlier steps' outputs. The task fills templates, calls `execute/2`, saves its own record ([050](050_storage.md)), and broadcasts that it finished.

Tasks are not linked to the run. They run their own code, call their own APIs, save their own records, and broadcast when they finish, error, or timeout on their own, even if the run has stopped.

## Lifecycle

```
start(workflow, input)
  -> save run row (status: running), broadcast run_started
  -> subscribe to "run:<run_id>"
  -> start every step with no `after`, giving it the trigger input
  -> on step_finished: update in-memory state, start any steps now ready
  -> nothing running and nothing left to start -> save run (complete, output), broadcast run_finished, stop
  -> on any failure -> save run (failed, error), broadcast run_finished, stop
```

## Input vs. earlier outputs

- **Input** is only the most recent output: the output of the step's `after` step. It can be a single value or a list.
- **Earlier outputs** of every step that already ran stay in the run's state. A step can reference its **ancestors**: the steps you reach by following `after` backward. Sibling branches can't be seen. Ancestors can be referenced:
  - in templates: `{{ steps.fetch.output }}` ([010](010_workflows.md))
  - in Code nodes: the `steps` variable ([020](020_nodes.md))
- The run only hands a task its ancestors' outputs, so siblings are simply not there. Referencing a non-ancestor in a template fails the workflow's checks at load time. Referencing an ancestor that didn't run (the other side of an if/else) fails the step.

## Starting a step

Each step has a `run` mode (set in the workflow TOML). It decides what happens when the input is a list:

- **`run = "each"` (default):** if the input is a list, start one task per item, in parallel, and give each task one item. An empty list means zero executions. If the input is a single value, start one task.
- **`run = "all"`:** start one task and give it the whole input, list or single value. Use this for code that works on the whole list, for bulk SQL inserts, or to narrow a list down before calling an API.

## Flat lists

Data between steps is always **one flat list of items** (or a single value), never a list of lists. This matches how n8n works.

- A per-item step's results are joined into one flat list, in item order. If one item's execution returns a list, its elements go straight into that flat list.
  - Example: 10 items that each return 5 results make a list of 50 items.
- Each item remembers which item it came from (`from_item`), so the UI can trace it back.
- **Size cap:** if a step's output would have more than 10,000 items, the run fails.
- A `run = "all"` step that returns a list starts a new flat list.

## When a step is ready

A step starts **each time one of its `after` steps finishes**, and gets that step's output as its input. Nothing tracks branches that didn't run. They simply never start anything.

- **After an if/else:** only one branch runs, so the step where the branches meet runs once.
- **After parallel branches:** if both branches run, the step runs twice, once per branch. This is the same as n8n. Waiting for both is a later feature.

## If/else (routes)

A node can return `{:ok, output, "route_name"}`. A step with `when = "route_name"` gets only the outputs that took that route.

- **Single execution:** only the matching `when` step runs.
- **Per item:** each item goes down its own route, like n8n's IF node. A `when` step gets the flat list of item outputs that took its route. If no items took that route, it doesn't run.

The branches' outputs have to make sense to whatever step comes after them. That's up to the workflow author.

## State (in the run's memory)

```elixir
%{
  run_id: "0192…",
  workflow: %PurpleFlow.Workflow{},
  steps: %{
    "fetch" => %{status: :done, output: [...]},
    "is_big" => %{status: :running, pending: 3, outputs: %{0 => ..., 4 => ...}, routes: %{...}}
  }
}
```

Only steps that have started appear here. Step status is one of `:running | :done | :failed`.

## Messages

Everything goes over `Phoenix.PubSub`. The UI listens to the same messages.

| Topic | Message | Sent by |
|---|---|---|
| `"run:<run_id>"` | `{:step_started, run_id, step, item}` | task |
| `"run:<run_id>"` | `{:step_finished, run_id, step, item, result}` | task, after saving |
| `"run:<run_id>"`, `"runs"` | `{:run_started, run_id, workflow}` | run |
| `"run:<run_id>"`, `"runs"` | `{:run_finished, run_id, status}` | run |

`item` is `nil` for single executions and the item's position (0, 1, 2, …) for per-item ones.

## Run output

The run's output is the output of the steps that nothing else comes after. If there's one, it's that step's output. If there are several, it's a map of `%{"step_name" => output}`, counting only the ones that ran.

## Failure

Any error, raise, or timeout fails the run.

- The run starts nothing new, saves itself as `failed` with the error, and stops.
- Tasks already running finish on their own and save their records.
- There are no retries.

**Timeouts:** each task enforces its own. It runs the node and gives up after the step's `timeout` seconds. Then it saves a `timed_out` record and broadcasts it like any other result. The run has no timers.

**Run process crash** (a bug): no restart (`restart: :temporary`). At boot, any run still marked `running` is marked `interrupted`.

## Parallelism limit

Set per step with `concurrency` in the workflow TOML:

```toml
concurrency = "concurrent"  # default: up to 1,000 at a time
concurrency = "sequential"  # one at a time, in item order
concurrency = 5             # any number, e.g. for a rate-limited API
```

If a sequential step fails on an item, the items after it never run.

## Tests

Use fixture workflows with a fake node module (returns what the test tells it to, with an optional delay). Cover:

- straight line
- list → per item, flattened
- `run = "all"`
- `concurrency = "sequential"` and numeric
- empty list
- 10,000-item cap
- routes (single and per item)
- if/else branches meeting again (runs once)
- parallel branches meeting again (runs twice)
- error
- timeout

Assert on the saved records and the broadcasts.
