# Purple Goo

A society of mind made of PurpleFlow workflows. Each AI call is a
**monad**, and a monad can hear from other monads before it answers: their
answers become its own thoughts, never spoken aloud. Those monads can have
monads of their own, as deep as you like. One recursive workflow, `goo`, is
the whole tree.

It speaks OpenAI's chat API, so any chat app (LibreChat, Open WebUI, an
OpenAI SDK) can use it. Point it at the base URL `/hooks/goo/v1`.

## Try it

Copy this folder into your workflows folder. It needs the
`OPENROUTER_API_KEY` credential (or set `_meta.provider_url` to another
OpenAI-compatible API).

```sh
curl -N -X POST localhost:4000/hooks/goo/v1/chat/completions \
  -H 'content-type: application/json' -d '{
  "model": "openai/gpt-4o-mini",
  "messages": [{"role": "user", "content": "Should I quit my job to sail around the world?"}],
  "metadata": {
    "personas": ["You are a wise friend. Answer in three sentences."],
    "monads": [
      {"personas": ["You feel the pull of adventure. Say what excites you."]},
      {"personas": ["You worry about money and safety. Say what scares you."]}
    ]
  }}'
```

The two children answer first. Their answers reach the friend as thoughts,
and the friend's answer streams back.

## Metadata

Everything goes in the request's `metadata`, which the provider never sees.
Every key is optional.

| Key | What it is |
|---|---|
| `personas` | prompts that make this monad who it is, sent first as system messages |
| `data` | data workflows to call: names, or `{"workflow", "data"}`. Each gets `{"frame", "data"}` as its body and returns text, a message, or any value |
| `monads` | child monads, each a metadata tree of its own (it can set `model`) |
| `opening` | `{"workflow", "data"}` to run in order before anything else. Each gets `{"frame", "data"}` and returns the frame, changed as it likes |
| `closing` | the same, after the AI answers. The frame then has `messages` (history without anything injected, data kept) and `response` |
| `model` | the model for this monad (a child defaults to its parent's) |
| `_meta` | the environment, inherited by every child (a child's own `_meta` keys win): `provider_url`, the chat completions URL (default OpenRouter); `swarm_skill`, `false` to leave out the skill sheet (below); and anything else that should travel down the tree, like a depth counter |

Nothing else inherits: a child has exactly the personas, data, and monads
its own tree gives it. Anything else you add rides along for your opening
and closing workflows: budgets, whatever you want to measure. There are no
limits on depth, so a tree that builds itself forever runs forever. The
provider key goes to whatever `_meta.provider_url` says, so only point it
at providers you trust with it.

## Patterns

- **Synthesizer:** any monad with `monads`. It's told the thoughts are its
  own and not to mention them.
- **Performer:** a mask at the top. Give the root a persona like "speak as
  a mystic, but change no facts", and one child: the real synthesizer. Its
  answer arrives as a thought, and the performer's answer is the one that
  streams.
- **Mutator:** any monad fed to a synthesizer. Mix and match them per call
  instead of writing every combination by hand.

## Designing swarms

[skills/swarm-json/SKILL.md](skills/swarm-json/SKILL.md) teaches an agent
to write these trees: the keys, the patterns above and more, how to write
personas, and what a tree costs. Give it to any agent you want designing
swarms. Every monad gets it too, after its personas, so a monad can design
a child swarm when asked. It's a system message on every call; set
`"_meta": {"swarm_skill": false}` at the root to leave it out of a tree.

All the prompts `goo` adds live in `goo/prompts.exs`. Its copy of the
skill sheet must match `SKILL.md`; edit `SKILL.md`, then copy it over.

## Errors

A failure anywhere comes back up with its reason. A failed child becomes a
`Thought (a monad failed): …` for its parent; a failed data, opening, or
closing workflow fails the monad; at the top, the caller gets
`500 {"error": ...}`.

## Working on it

The design is in [specs/](specs/000_overview.md), and the rules for working
on it are in [AGENTS.md](AGENTS.md). The tests are workflows too, run
against a fake provider, so they cost nothing:

```sh
samples/purple-goo/check.sh    # from the repo root, with the app running
```
