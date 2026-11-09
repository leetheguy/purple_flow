# 030 — Tool calls

Status: implemented
Created: 2026-11-09

## What it is

Every monad's agent can run Purple Flow workflows as tools, as many rounds
as it needs. A tool round never loops inside a run: the workflow runs the
tool, then calls itself, a **tool child**, with the tool's result in the
history. When an agent finally answers without calling a tool, the chain
collapses: each tool child hands that answer up unchanged. The top monad
then speaks: one last AI call, with the answer as a thought, which is the
call that streams to the chat app.

## The tool

`run_workflow`: `{"name": "<workflow>", "params": {...}}` runs that
workflow with `params` as its body and returns its output. Any workflow is
a tool, `goo` included, so an agent can start a swarm of its own. It's
offered to every monad's agent by default; `_meta.run_workflow = false`
leaves it out, and cascades like the rest of `_meta`.

## Roles

A call to `goo` is one of three roles. The role travels in `goo_role` in
the request, which never reaches the provider.

- **Top** (no `goo_role`): anything that calls `goo` from outside,
  including an agent running it as a tool. It speaks.
- **Monad** (`"monad"`): a child in the tree. Its answer, after any tool
  rounds, is its answer; it doesn't speak.
- **Tool** (`"tool"`): a tool child. It gets the history as its parent's
  agent saw it, plus the call and the results, and only `_meta` as its
  metadata. It injects nothing (the personas and thoughts are already in
  that history), runs no data, opening, or closing workflows, and doesn't
  speak.

## Rules

1. **Think.** The agent's call doesn't stream, so a tool call can be caught
   before anyone sees it. It's offered `run_workflow`, and at the top, the
   client's own tools.
2. **Tool round.** For a `run_workflow` call, `goo` runs the workflow
   (several calls in one message run at the same time), then calls a tool
   child with the history, the assistant's message, and one `tool` message
   per call, in order. A result that's text is sent as is; anything else is
   JSON. A failed tool, or one that returns nothing, is a result too:
   `{"error": "..."}`, so the agent can see what broke and decide. A call
   to a tool that isn't `run_workflow` gets an error result saying it can't
   be run here.
3. **Collapse.** A tool child that answers without a tool call returns its
   answer. Every tool child above it hands that answer up unchanged, with no
   AI call of its own.
4. **Speak.** The top monad always makes one more call: its messages, the
   synthesizer instruction, and the answer from step 1 or 3 as a
   `Thought: `. No tools are offered. At the top of a chat, this call
   streams; anywhere else, nobody's waiting, so it doesn't.
5. **Client tools go back to the client.** If the top agent's first call
   asks for one of the client's tools (and no `run_workflow`), that message
   goes back to the chat app as an OpenAI stream, as it is, and nothing
   speaks. Children are never offered the client's tools; they couldn't
   hand the call back.
6. **Closing** sees the history the top agent started from, plus the final
   answer. The tool rounds stay inside the tool children.
7. **No limits.** Nothing caps the number of rounds. A counter in `_meta`
   and an opening workflow can stop a chain if you want one.

## Tests

- An agent that answers without a tool still speaks: the speak call gets
  the answer as a thought, with the instruction, and no tools.
- One tool round: the tool child sees the history, the assistant's call,
  and the tool's result; its answer is the top's thought.
- Two rounds: the chain goes two tool children deep and collapses to one
  thought.
- A failed tool is a result with the error, and the chain carries on.
- A monad child with a tool round answers with the chain's answer, and
  doesn't speak.
- `run_workflow` is offered by default, and `_meta.run_workflow = false`
  leaves it out.
- At the top, a client tool call goes back to the client as it is, without
  a speak call.
- Children aren't offered the client's tools.
- The top monad's answer streams through the webhook, and so does a client
  tool call (`check.sh`).

## Log
