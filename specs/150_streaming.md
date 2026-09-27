# 150 — Streaming

Status: draft
Created: 2026-09-27

Since items already flow one at a time ([120](120_flow.md)), streaming is just a node handing over items while it's still running, instead of all at once when it returns. The HTTP node does that for streamed responses, and a webhook can stream its run's results back to the caller as they're made.

## Handing over items while running

Any node may call, from its own execution:

```elixir
PurpleFlow.Node.emit(value)            # one item, no route
PurpleFlow.Node.emit(value, "route")   # one item down a route
```

The item goes into the next steps' queues right away, exactly like a returned item: a list splits, and `steps.X.output` for what comes after is that item. When the node returns, whatever it returns is handed over too, the usual way. A node that emitted everything returns `{:ok, []}`.

- If a step directly after is full and set to wait ([120](120_flow.md)), `emit` waits until there's room. For the HTTP node that means it stops reading the response, and the server slows down.
- The execution's saved `output` is every item it produced, emitted and returned, as a list.
- An emitted item that isn't JSON-shaped fails the execution.
- If the execution then fails, what it already emitted has already moved on.
- Outside an execution (a test calling `execute` directly), `emit` sends `{:emit, value, route}` to the calling process instead.

Code node scripts can't emit; they run in the runner container ([100](100_runner_container.md)).

## The HTTP node

```toml
module = "PurpleFlow.Nodes.Http"

[config]
url = "https://api.example.com/v1/messages"
method = "POST"
stream = "sse"           # or "ndjson", or "lines"
body = { stream = true, prompt = "{{ input.prompt }}" }
```

With `stream` set, the node reads the response as it arrives and emits one item per message in it, following the protocol named:

| `stream` | One item per | Item |
|---|---|---|
| `"sse"` | server-sent event (a blank line ends one) | `{"event": "message", "data": ..., "id": "..."}`. `event` is `"message"` when the server doesn't name one. `data` is the event's data lines joined with newlines, decoded if it's JSON, else the text. `id` only if the event has one. Comment lines are skipped |
| `"ndjson"` | line of JSON | the decoded line. Blank lines are skipped; a line that isn't JSON fails the execution |
| `"lines"` | line of text | the line, without its line ending. Blank lines are skipped |

- A non-2xx status is an error, as without `stream`, and nothing is emitted.
- An event or line cut off when the response ends: a last line with no newline is still an item for `ndjson` and `lines`; an unfinished server-sent event is dropped.
- The node returns `{:ok, []}` when the response ends.
- `timeout` defaults to no limit ([120](120_flow.md)), so a stream the server never closes runs until it's killed. Set one if that matters.

Without `stream`, nothing changes: the whole body is read, and returned when it's done.

## Streaming a webhook's results

```toml
[trigger.webhook]
path = "chat"
respond = "stream"
```

The reply is a server-sent event stream (`content-type: text/event-stream`), sent as the run goes:

- every item a last step produces (a step nothing comes after), as it's produced, as `data: <item as JSON>`
- a comment line (`: keep-alive`) every 15 seconds with nothing else to send, so proxies don't hang up
- at the end, one `event: end` with `data: {"status": "complete", "run_id": "..."}` (or `failed` with `"error"`, or `killed`)

The run ID is in the `x-run-id` header, as always. If the caller hangs up, the run keeps going; it's never tied to the connection.

`respond` is now `"result"` (default), `"immediately"`, or `"stream"`.

## Tests

- `emit` hands items on before the node returns, and the next step starts on them
- `emit` waits while a following queue is full
- HTTP with `stream = "sse"`, `"ndjson"`, and `"lines"`, including a message split across chunks and a last line with no newline
- HTTP streaming with a non-2xx status is an error and emits nothing
- `respond = "stream"` sends each last-step item as an event, then `end`
