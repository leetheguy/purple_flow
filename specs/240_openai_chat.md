# 240 — OpenAI Chat node

Status: implemented
Created: 2026-10-03

A node that calls an OpenAI-compatible chat completions API with streaming on, and streams the answer straight back to the webhook caller in the same format. A chat app (LibreChat, Open WebUI, anything using an OpenAI SDK) pointed at a PurpleFlow webhook then sees an ordinary OpenAI stream, and the steps after the node get the whole message once it's done.

`respond = "stream"` ([150](150_streaming.md)) can't do this: it wraps every item as JSON and ends with its own `end` event, and OpenAI clients need the provider's events as they are, ending with a bare `data: [DONE]`. They also wait for the connection to close, so the stream has to end when the answer does, not when the run does.

## Config

```toml
module = "PurpleFlow.Nodes.OpenAIChat"

[config]
url = "https://openrouter.ai/api/v1/chat/completions"
headers = { authorization = "Bearer {{ creds.OPENROUTER_API_KEY }}" }
body = "{{ steps.build.output }}"   # model, messages, temperature, …
respond = true                      # default
```

- `url` and `body` are required; `body` must be a table (often one placeholder for a map an earlier step built). The node always sends it with `"stream": true` and `POST`s it as JSON.
- `headers` are sent as they are.
- `respond = false` reads the stream without answering anyone.

## Answering the caller

It answers like a Respond step ([180](180_noop_wait_respond.md)): only a caller waiting on a webhook with `respond = "result"` (the default), and only if nothing has answered yet. With nobody to answer, it just reads the stream.

- At the first part of a 2xx response it takes the caller: status 200, `content-type: text/event-stream`, `cache-control: no-cache`, and the `x-run-id` header as always.
- Each server-sent event is passed on as it arrives: `data: <its data>`, with an `event:` line when the event has a name other than `message`. Data that was JSON is passed on as JSON (re-encoded, same meaning); text as text. Comment lines (`: ...`) are dropped.
- The stream ends with `data: [DONE]` (added if the provider didn't send it), and the caller's connection closes. The run carries on without it.
- While nothing arrives for 15 seconds, the webhook sends a `: keep-alive` comment, as with `respond = "stream"`. OpenAI clients ignore comments.
- If the caller hangs up, the node keeps reading and the run carries on.

## Output

Once the answer is complete, the whole message, built from the chunks:

```json
{"content": "Hello!", "reasoning": "Hmm, a greeting.", "tool_calls": null,
 "finish_reason": "stop", "model": "...", "id": "...", "usage": {...}}
```

- `content` joins every `choices[0].delta.content`; `reasoning` joins `delta.reasoning` or `delta.reasoning_content` (null if there was none).
- `tool_calls` joins tool call pieces by `index` (name and arguments are text to join), as a list in index order; null if none.
- `finish_reason`, `model`, `id`, and `usage` are the last ones seen, or null.

## Failures

- **A non-2xx response:** the caller gets that status and body (decoded if it's JSON), and the step fails with `HTTP <status>: <body>`.
- **An `error` sent mid-stream** (OpenRouter does this): passed on to the caller like any event, and once the stream ends the step fails with `the provider sent an error: <message>`.
- **The request fails** (connection refused, dropped): if the caller was already taken, it gets a last `data: {"error": {"message": ...}}` and the stream ends; if not, it gets `502` with that error. The step fails with `request failed: ...`.
- **The step dies** (killed, timed out, crashed): the webhook watches the execution, so the caller's stream just ends.

## How the answer travels

- `PurpleFlow.Node.respond_stream(status, headers)` is the node side, set up by `PurpleFlow.StepTask` like `respond/1`. It asks the run, which sends the waiting caller `{:run_respond, run_id, %{"status", "headers", "stream" => {pid, ref}}}` once and forgets it, and returns `{:ok, sink}` to the node, or `:none` if nobody was waiting.
- The node then sends `PurpleFlow.Node.respond_chunk(sink, data)` and `respond_done(sink)` straight to the caller's process. The webhook controller relays chunks until done, or until the execution's process goes down.
- Outside a run (a test calling `execute` directly), `respond_stream` sends `{:respond_stream, status, headers}` to the calling process, and the chunks and the end come to it as `{:respond_chunk, ref, data}` and `{:respond_done, ref}`.
- Any node can use these three functions to stream its own answer.

## Tests

- Events reach the caller as they came, comments dropped, ending with `[DONE]`; the output joins content and reasoning, and keeps `id`, `model`, `usage`, `finish_reason`; the request has `stream: true`.
- Tool call pieces are joined.
- A missing `[DONE]` is added; a named event keeps its `event:` line; an empty answer still answers with `[DONE]`.
- `respond = false` answers no one.
- A mid-stream provider error is passed on and fails the step.
- A non-2xx response goes to the caller with its status and body; a failed request answers 502.
- `prepare` wants `url` and `body`, and `respond` true or false; a body that isn't a table fails.
- **Webhook:** the caller gets the stream as sent, and the step after gets the whole message; a step that dies mid-answer ends the caller's stream.
