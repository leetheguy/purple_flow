# 020 — The swarm skill sheet

Status: implemented
Created: 2026-11-09

## What it is

A skill sheet that teaches an agent to design a swarm: how to write the
metadata tree for `goo`, which shapes work for which jobs, and how to write
personas for them. It's written for agents outside the tree (any agent
asked to build a swarm) and for every monad inside one, so a monad can
design a child swarm when asked to.

It explains the design in its own words. It doesn't quote Lee's design
doc.

## Rules

1. **One source.** The sheet is `skills/swarm-json/SKILL.md`. Its body
   (everything after the frontmatter) is copied into `goo/prompts.exs`,
   which holds every prompt `goo` injects. `check.sh` fails if the two
   differ.
2. **Injected after the personas.** Every monad sees `[personas, the skill
   sheet, the synthesizer instruction, history, data, thoughts]`, as one
   system message.
3. **On by default; `_meta.swarm_skill = false` leaves it out.** It's in
   `_meta`, so it cascades: turning it off at the root turns it off for the
   whole tree, and a child can set it back with its own `_meta`.
4. **Injected, so it stays inside.** The denormalizer removes it like a
   persona, so closing workflows and parents never see it.

## Tests

- The skill sheet comes right after the personas, before the synthesizer
  instruction, by default, in children too.
- Closing workflows don't see it.
- `_meta.swarm_skill = false` leaves it out (every other case runs this
  way).
- The copy in `goo/prompts.exs` matches `SKILL.md` (`check.sh`).

## Log
- 2026-11-09 — [030](030_tools.md): the sheet says a monad can start a
  swarm itself by running `goo` with `run_workflow`, and lists
  `_meta.run_workflow`.
