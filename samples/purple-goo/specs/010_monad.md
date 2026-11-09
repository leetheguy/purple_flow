# 010 — The monad

Status: implemented
Created: 2026-11-09

Source: Lee's design doc, `index — 1.11-agent` (2026-11-08). Where this spec
and that doc disagree, the doc and Lee's rulings win; report it, don't patch
over it.

## What it is

A **monad** is one AI call with an internal world. Its **metadata** says
who it is (personas), what data it pulls in, and which child monads it
hears from. A monad with children is a **synthesizer**: the children's
answers reach it as its own thoughts. A child can have children of its own,
to any depth. One workflow, `goo`, is every monad in the tree.

## The call

`goo` is an OpenAI-compatible chat endpoint: `POST
/hooks/goo/v1/chat/completions`, so the base URL is `/hooks/goo/v1`. It
takes any OpenAI chat request (model, messages, tools, tool results, …) plus
a `metadata` object, which never reaches the provider:

```json
{
  "personas": ["You are ..."],
  "data": ["weather", {"workflow": "notes", "data": {"topic": "x"}}],
  "monads": [{"personas": ["..."], "monads": [...]}],
  "opening": [{"workflow": "add_tools", "data": {}}],
  "closing": [{"workflow": "save_chat", "data": {}}],
  "model": "child-model-id",
  "provider_url": "https://openrouter.ai/api/v1/chat/completions"
}
```

Every key is optional. An empty or missing list does nothing. Metadata is
open: any other key rides along untouched for opening and closing workflows
to use (depth counters, budgets, anything an architect wants). There are no
termination guardrails. A tree that recurses forever is the builder's to fix.

## Rules

1. **A call never changes its caller's data.** A monad takes its metadata
   subtree and the history, and returns a response.
2. **A child gets only its own subtree** as its `metadata`, never its
   parent's or its siblings'. It gets the parent's request (history, tools)
   with `model` set to the subtree's `model`, or the parent's model if the
   subtree has none. `provider_url` isn't inherited either; a child without
   one uses the default (OpenRouter).
3. **Order of a monad's work:**
   1. *Opening* workflows run one after another. Each gets
      `{"frame": frame, "data": data}` as its body and returns the frame,
      changed however it likes. The frame is `{"request", "meta"}`.
   2. *Data* workflows each get `{"frame", "data"}` and return data: a
      message (a map with `role`), text, or anything else, which is sent as
      JSON.
   3. *Monads* (children) are called, each with its own subtree.
   4. The AI is called with `[personas, the synthesizer instruction,
      existing messages, data, thoughts]`. Personas are system messages, in
      order. The synthesizer instruction is there only if the monad has
      children. Each child's answer is a system message beginning
      `Thought: `.
   5. The *denormalizer* builds the frame for closing: `messages` is
      everything the AI saw plus its answer, with every persona, the
      instruction, and every thought removed by exact match (never by
      position). Data stays, so the agent remembers its work. `response` is
      the AI's message.
   6. *Closing* workflows run one after another, like opening.
   7. The monad returns `frame.response`:
      `{"content", "reasoning", "tool_calls", "finish_reason", …}`.
4. **Nothing injected is returned upward.** A parent only ever sees a
   child's response; personas, instructions and thoughts stay inside the
   frame that made them.
5. **Callers.** `goo_map` calls a list of workflows (the data workflows, or
   the children) and returns their outputs in list order. `goo_chain` runs
   opening and closing workflows in order. Given an empty list, both are a
   no-op: nothing is called, and the input passes through.
6. **Errors are returned, loudly.** Every stage of `goo` ends the run on
   failure, so a broken monad fails with a message naming the step and why.
   A called workflow whose run ends with no output (a step in it failed
   without `on_fail = "end_run"`) is an error naming it, never an empty
   value. A failed data workflow fails the monad. A parent gets a failed child
   as a thought, `Thought (a monad failed):
   <error>`, and never synthesizes over a silent gap. At the top, the
   webhook caller gets `500 {"error": ...}`, or the provider's own error
   status and body.
7. **Only the top monad streams.** The root's AI call streams its answer to
   the caller in OpenAI's format. Children run as child runs, which nobody
   waits on, so they answer only their parent.
8. **Performers are a pattern, not a mechanism.** A performer is a root
   monad whose personas are a mask and whose one child is the synthesizer.
   The synthesizer's answer reaches it as a thought, and the performer's
   answer is the one that streams. The same goes for mutators: any monad
   fed to a synthesizer is one.

## Tests

The tests are workflows (`tests/goo_tests`), run against a fake provider
(`tests/goo_fake_llm`) that echoes back what it was sent.

- A request with no metadata reaches the provider as sent: same messages,
  no `metadata` key.
- Personas come first, as system messages, in order.
- Data results come after the existing messages, in list order; text,
  messages, and other values each take their shape.
- Each child is called with only its own subtree and the parent's history.
- A child's answer reaches the parent as a thought, after the data, with
  the synthesizer instruction after the personas.
- A grandchild's answer reaches the root only through its parent.
- A child's model comes from its subtree, else the parent's.
- Opening workflows run in order, and the frame each returns is what the
  next one gets.
- Closing workflows run in order and see the history without personas,
  instructions, or thoughts, but with data.
- A failed child reaches its parent as a failed thought.
- A failed data workflow fails the monad, with the reason.
- A called workflow whose run ends with no output (a step in it failed)
  is an error naming that workflow, never an empty value.
- A failed top-level call fails the run with the reason.
- The callers do nothing on an empty list.

## Log
