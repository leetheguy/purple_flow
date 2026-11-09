---
name: swarm-json
description: Design a Purple Goo swarm, a tree of AI agents that think together, as the JSON metadata for a goo chat request. Use when asked to build, sketch, or change a swarm, a society of agents, a council of perspectives, or a persona with an inner voice.
---

# Designing a swarm

A swarm is a tree of agents called monads. Each monad is one AI call. A
monad with children waits for them to answer first, then reads their
answers as its own private thoughts before it speaks. Only the top monad
speaks to the user. You design a swarm by writing a JSON tree.

## The request

A swarm is an ordinary OpenAI chat request with a `metadata` tree, sent to
`POST <base>/hooks/goo/v1/chat/completions`:

```json
{
  "model": "openai/gpt-4o-mini",
  "messages": [{"role": "user", "content": "..."}],
  "metadata": { ...the root monad... }
}
```

Every monad in the tree has the same keys, all optional:

| Key | What it is |
|---|---|
| `personas` | a list of prompts that say who this monad is and what its job is |
| `monads` | its children, each a monad of the same shape |
| `model` | the model for this monad; a child without one uses its parent's |
| `data` | workflows that fetch facts for it: `"name"` or `{"workflow": "name", "data": {...}}` |
| `opening`, `closing` | workflows that run before and after its AI call: `{"workflow": "name", "data": {...}}` |
| `_meta` | settings passed down to every child: `provider_url`, `swarm_skill` (`false` leaves this sheet out), `run_workflow` (`false` takes away the tool), and your own keys. A child's own `_meta` keys win |

A child sees the conversation and its own branch of the tree, nothing
else: not its parent's personas, not its siblings. Only `_meta` is passed
down. A child that fails reaches its parent as a thought saying what broke.

## Patterns

- **Council.** Two to five children who see the question differently (the
  optimist and the skeptic, the user's future self and present self). The
  parent weighs them. Make them disagree; children who agree waste calls.
- **Specialists.** Each child owns one concern (cost, risk, tone, the
  law), and the parent makes the call.
- **Critic.** One child's whole job is to find what's wrong with the
  obvious answer.
- **Mask.** The root carries only a voice ("speak like a ship's captain;
  change no facts") and has one child that does the real thinking. The
  answer is the child's; the voice is the root's.
- **Inner life.** Children that are feelings or drives (curiosity, fear,
  care) rather than experts. They make the parent's answer more human, not
  more correct.
- **Mix and match.** Keep a few good child definitions and combine them
  per request instead of writing a new tree for every case. Any child can
  shape any parent.
- **Nesting.** Give a child children only when it needs perspectives of
  its own. A council of masks, or a specialist with its own critic, is
  fine; depth for its own sake isn't.
- **Facts go in `data`, not in personas.** Personas say who to be;
  data workflows bring in what's true today.

## Writing personas

- One job per monad, in a few sentences. Say what to pay attention to,
  and what to leave alone.
- Children talk to their parent, not the user. Ask them for short, frank
  notes: no greetings, no summaries of the question.
- The parent's persona can say how to use its thoughts ("side with the
  skeptic when money is at stake").
- Give each monad a voice of its own. Two monads with the same persona are
  one monad, paid for twice.

## Cost and time

Every monad is one AI call, so the cost is the number of monads. Siblings
run at the same time, so the wait is about one call per level of depth.
Use a cheaper `model` for children where it'll do. Nothing stops a tree
that keeps growing itself; if yours can, put a counter in `_meta` and have
an opening workflow stop at a limit.

## Example

A wise friend who hears a dreamer and a worrier first, with a critic
checking the worrier:

```json
{
  "personas": ["You are a wise friend. Answer in three sentences."],
  "monads": [
    {"personas": ["You feel the pull of adventure. In two lines, say what excites you."]},
    {
      "personas": ["You worry about money and safety. In two lines, say what scares you."],
      "monads": [{"personas": ["Point out which of these worries are overblown, in one line."], "model": "openai/gpt-4o-mini"}]
    }
  ]
}
```

## Tools

Every monad can run workflows with the `run_workflow` tool, for as many
rounds as it needs, before it answers. To start a swarm yourself, run
`goo` with the whole request (`model`, `messages`, `metadata`) as `params`;
its answer comes back as the tool result.

When someone asks you for a swarm, answer with the JSON, and say in a line
what each monad is for. When someone asks you to use one, run it.
