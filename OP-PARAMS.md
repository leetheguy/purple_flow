# Operating Parameters

These rules come from building PurpleFlow (Sep–Oct 2026): 25 specs, 70-odd
commits, over 90% test coverage, and very few bugs reaching the live app.

Version 1.0 (2026-11-03). Changes are listed at the end.

**These are the rules every agent working on this project follows.** They're
written for agents, but they hold for people too.

- **Precedence.** The project's `AGENTS.md` can make a rule more specific, or
  fill in a binding (below). It can't loosen a rule unless the user approved
  that in writing, and it should say so.
- **Conflicts.** If this file, `AGENTS.md`, the specs, and the code disagree,
  stop and ask the user. Don't guess which one is right.
- **Exceptions.** If you can't follow a rule, say which one and why, in your
  summary to the user and in the commit message. Never skip a rule quietly.

## Project bindings

This file names no language, framework, or tool. Each project's `AGENTS.md`
fills in a table like this, and every rule below uses these names:

| Binding | What it is | Example |
|---|---|---|
| **precommit** | one command that runs every local check | `make check`, `npm run precommit`, `cargo clippy -- -D warnings && cargo test` |
| **test** | runs the test suite | `pytest`, `go test ./...`, `cargo test` |
| **coverage** | runs the tests and enforces the coverage floor | `pytest --cov --cov-fail-under=90`, `cargo llvm-cov --fail-under-lines 90` |
| **mutation** | runs mutation testing on chosen files (section 4) | `cargo mutants --file src/x.rs`, `mutmut run`, `npx stryker run` |
| **security** | scans dependencies for known vulnerabilities and commits for secrets | `cargo audit`, `pip-audit`, `npm audit`, gitleaks |
| **run** | starts the app the supported way | `docker compose up -d --build` |
| **CI** | where the automatic checks run | `.github/workflows/ci.yml` |
| **doc tool** | the language's documentation generator, and the format code docs are written in (section 7) | ExDoc (`@moduledoc`, `@doc`), rustdoc (`///`), Sphinx (docstrings), godoc, TypeDoc (`/** */`) |
| **docs** | the docs that must change with behavior (section 6) | `README.md`, `docs/agents.md` |
| **copies** | files kept as copies of others, and who makes each copy | `deploy/AGENTS.md` ← `docs/agents.md`, by the user |
| **branching** | how work reaches the main branch, and who pushes | feature branch → PR; or merge locally, user pushes |

---

## 1. Philosophy

- **Build power tools.** Safeguards are *options* with sensible defaults (a
  timeout, a queue limit, a failure policy, a pinned key). They're never
  hard blocks or limits the user can't change. Don't forbid something
  because it could be misused; a short caution in the docs is enough.
- **If a choice isn't clearly the user's or ours, don't guess.** Ask, or write
  it down as an open question (in the spec's log, and in the to-do spec).
- **Security is where the rigor goes.** Secrets are encrypted and kept out of
  logs, untrusted code runs in a sandbox, and paths can't escape their folder.
  Everything past that is the user's design decision.
- **Fail loud.** A failure leaves a full record. Add retries and similar
  features later, once real use shows they're needed.
- **Simple beats clever.** Offered a choice, prefer the simpler and tighter
  design. Add layers only when a real, likely problem needs them.

## 2. Specs

Specs come in two kinds:

- **Two living specs** describe the project as it is and as it's going to be.
  They're rewritten in place and always kept current: `000` is **now**, and
  `999` is **next**.
- **Every other spec is history.** It records one design decision as it was
  made, and once it ships it's set in stone apart from its log.

An agent new to the project reads 000 first. It should be enough to work from,
and it points to the numbered specs for detail and for why.

### Files

- `specs/NNN_name.md`, numbered in steps of 10 (`010_…`, `020_…`). A new spec
  gets the next free multiple of 10. A spec that supersedes another gets the
  old one's number plus one (`240` → `241` → `242`), so a design and its
  redesigns sit together.
- `000_overview.md`, the living overview. It's **the source of truth for
  what the project is today**:
  - what the project is and who it's for
  - the whole model, in a few numbered rules
  - project-wide rules
  - the architecture, and where things live in the code
  - the dependencies
  - an **index of every spec**, each with a one-line summary, marking the
    ones that are superseded or still draft

  Whenever the project changes, rewrite 000 to match. That includes a full
  pivot. 000 has no log: its history is in git, and the reasons for each
  change are in the numbered spec that made it. Its status is always
  `living`.
- `999_todo.md`, the living to-do list. It holds planned work, open
  questions, and ideas, each linking to the spec it came from. Its status is
  always `living`. Add an item when something is left planned or open;
  delete it when it ships.

### Header

```markdown
# 241 — Export to CSV

Status: draft
Created: 2026-10-03
Replaces: [240](240_export_to_csv.md)   ← only for a redesign
```

`Status:` is one of these four:

- `living`: 000 and 999 only. Always kept current, rewritten in place.
- `draft`: still being designed. It can be edited freely.
- `implemented`: it shipped. **After this, only the Status line and the
  `## Log` can change.**
- `superseded by [NNN](...)`: a redesign replaced it.

### Rules

- **Say what it does, not what it changes.** Write in the present tense, as if
  it already exists, even before it's built. Avoid "used to", "no longer", and
  "replaces X" in the body. A spec stands alone, without the story of how a
  decision was reached.
- **The commit that finishes a spec also sets it to `implemented`.** Never
  leave a shipped spec marked `draft`.
- **Later changes go in a dated log entry**, at the bottom of the spec that
  changed, linking the spec that changed it:
  `- 2026-10-12 — [250](250_retries.md): steps take a retries option.`
  A change no spec drove still gets an entry, with the reason.
- **A change too big for a log entry is a new spec.** Mark the old one
  `superseded by`, and give the new one a `Replaces:` line. The new spec's
  number is the old one's plus one (see **Files**).
- **A pivot is a numbered spec too.** It records what changed direction and
  why. Then 000 is rewritten to describe the project after the pivot.
- **Every spec ends with `## Tests`**: a plain list of the behaviors that must
  be tested. Section 3 turns this list into tests.
- **A draft spec also gets `## Tasks`** once it's agreed: a checklist of
  small steps that build it, each one a commit (section 8). Tick them off as
  they land, so any agent can pick up where the last one stopped. Delete the
  list when the spec is marked `implemented`; the commits are the record.
- **Spec first for anything with a big blast radius** (secrets, sandboxing,
  auth, data loss, architecture). Treat the spec review as a real design
  pass, and go a few rounds with the user before writing code. Problems found
  in a spec cost nothing to fix. Before such a change merges, it gets an
  **independent review** (section 5).
- **Surface tensions; don't resolve them silently.** If two requirements
  conflict, ask the user with concrete options.
- For routine features, a short spec written alongside the code is fine. It
  still needs its `## Tests` list.

## 3. Test-driven development

All behavior changes are test-driven. No exceptions for "small" changes.

1. **Start from the spec's `## Tests` list.** If the behavior isn't on the
   list, add it to the spec first. If it's a bug, the bug report is the spec.
2. **Red.** Write one test for one behavior. Run it and **watch it fail, for
   the reason you expect.** A test you never saw fail proves nothing: it might
   not run, or it might pass no matter what the code does.
3. **Green.** Write the simplest code that makes it pass. Don't build ahead of
   the tests.
4. **Refactor.** Clean up the code and the tests while everything is green,
   and finish the code's docs (section 7). Run the whole suite.
5. Repeat until every item on the `## Tests` list has a passing test.

- **Every bug fix starts with a test that reproduces the bug** and fails.
  Then fix it. That test stays forever, so the bug can't come back.
- **Tests ship in the same commit as the code they cover.**
- **Never weaken a test to make it pass.** That includes loosening an
  assertion, adding a skip, deleting the test, or changing what it expects to
  match the current output. If the test is wrong, say why in the commit. If
  the code is wrong, fix the code.
- **When behavior can only be seen in the deployed environment** (sandboxing,
  packaging, containers, network isolation, permissions), passing tests
  aren't enough. Build the real thing and check it there. Code that passes
  every test can still be broken once it's packaged.

## 4. Writing tests that are worth having

A test is worth having when it **fails if the behavior breaks** and **keeps
passing when the code is restructured but the behavior isn't changed.** A
test that fails either check costs more than it saves. Most bad AI-written
tests fail one or the other.

These rules draw on Kent Beck (*Test-Driven Development by Example*), Gerard
Meszaros (*xUnit Test Patterns*), Freeman and Pryce (*Growing Object-Oriented
Software, Guided by Tests*), Vladimir Khorikov (*Unit Testing Principles,
Practices, and Patterns*), and Google's *Software Engineering at Google*.

### What makes a good test

- **Test behavior, not implementation.** Go through the public interface and
  assert on what a caller or user can see: the return value, the saved
  record, the response, the message sent. Don't assert on private functions,
  internal state, or which helper got called.
- **Ask: "If I broke this code, would this test fail?"** Picture a real bug
  (an off-by-one, a missing case, a wrong status code). If the test would
  still pass, it isn't protecting anything. Rewrite it or delete it.
  **Mutation testing** asks this automatically: the **mutation** tool makes
  small deliberate bugs in the code (a flipped condition, a changed number,
  a deleted line) and runs the tests against each one. A bug no test
  catches is a *surviving mutant*: a gap in the tests.
- **One behavior per test**, so a failure tells you exactly what broke.
  Several assertions are fine when they describe the same behavior.
- **Name tests after the behavior.** Good: `"a failed item stops there and
  the others carry on"`. Bad: `"test process_item"`. Together, the test
  names should read like the spec.
- **Arrange, act, assert.** Set up, do one thing, check the result. Keep
  these three parts visible. Prefer a little repetition over clever shared
  setup that makes a test impossible to read on its own.
- **Use concrete expected values**, written out by hand: `total == 42`.
  Never compute the expected value with the same logic as the code under
  test. That test can only ever agree with the code.
- **Cover the edges, not only the happy path.** Test empty, one, many, the
  boundary, invalid input, timeouts, and failures from anything outside the
  code. Error paths are where production bugs live.
- **Keep tests fast, independent, repeatable, and self-checking.** That means
  no order dependence, no shared mutable state, and no real clock or
  randomness without control.
- **Never sleep to wait.** Wait on a signal instead: an event, a message, a
  callback, a condition you poll with a deadline. Sleeps make tests both slow
  and flaky.
- **Clean up after yourself.** Start background work in a way the test
  framework stops it, and clear temp files and folders before and after each
  test.

### Mocks and test doubles

- **Use real code wherever it's practical**: a real database (in a
  transaction rolled back after each test), real modules, real files in a
  temp folder.
- **Fake only what the code doesn't own**: third-party APIs, the network,
  the clock, and the like. Fake them where they enter the code, not deep
  inside.
- **Never write a test that only checks a mock was called with the arguments
  you just configured.** It tests the mock, not the code.

### Anti-patterns to avoid

| Anti-pattern | What it looks like |
|---|---|
| **Mirror test** | It restates the implementation line by line, so it breaks on every refactor and never catches a real bug. |
| **Snapshot of whatever it does now** | It runs the code, copies the output into the assertion, and calls the result a test. It enshrines bugs. |
| **Tautology** | It asserts something that can't be false: a value equals itself, a freshly built object has its type, "returned something" when the value is the whole point. |
| **Coverage padding** | It calls functions to raise the coverage number and asserts nothing that matters. Coverage shows what *isn't* tested. It doesn't show that tested code is correct. |
| **Testing the framework** | It checks that the database saves, the router routes, or the standard library works. Trust those, and test *your* logic. |
| **Over-mocking** | So much is faked that the test can't fail for a real reason. |
| **Flaky test** | It depends on timing, order, or the network. Fix it the day it flakes; never retry it until it passes. |
| **Giant test** | One test runs a whole scenario, and its failure tells you nothing. Split it by behavior. |

### Levels

- **Most tests are unit tests**: fast, through a module's public interface.
- **Some are integration tests**: a real database, real requests through the
  app's entry points, one whole feature end to end.
- **A few are checks against the deployed system**, plus load and stress
  tests. Keep them in the repo so they can be run again. Stress tests find
  bugs that unit tests never will.

## 5. Quality gates

- **CI** (continuous integration) is the automatic check a hosted service
  runs on every push and pull request: the green check or red X next to a
  commit. It runs the same checks as **precommit**, on a clean machine, so
  "works on my machine" can't sneak through.
- **Coverage** is the share of the code that the tests run. It has a floor
  of 90%, set in the coverage tool's config so it can't be skipped. Coverage
  shows what the tests *ran*, not what they'd *catch*; the mutation check
  covers that.

| Gate | When | What it does |
|---|---|---|
| **precommit** | locally, before every commit | build with warnings as errors, remove unused dependencies, format, run the tests, build the code docs |
| **CI** | every push and pull request | the same checks in **check mode** (it reports problems but doesn't fix them), plus coverage and the **security** scans |
| **Coverage floor** | locally and in CI | the build fails at 90% coverage or below |
| **Mutation check** | before every commit, on the files the change touches | every surviving mutant gets a test that kills it, or a reason in the commit why it can't matter (it changes nothing a caller can see) |
| **Independent review** | before merging a big-blast-radius change (section 2) | a fresh agent, which didn't write the change, reviews the diff against its spec and reports what it finds; fixes go in before the merge |
| **Housekeeping review** | before every commit | section 8 |

- CI uses the same language and tool versions as production.
- CI holds no secrets, not even throwaway ones.
- Lockfiles are committed, so every build uses the same dependency versions.
  A vulnerable dependency found by the scan gets updated, or noted in 999
  with why it can wait.
- If CI is red, whoever pushed fixes it.

## 6. Docs stay in step with the code

**Anything that changes what the system does updates every doc it touches in
the same commit.** The project lists its docs under the **docs** binding.
Most projects have some of these:

1. **The specs**: a new spec or a log entry, a rewrite of whatever 000 says
   that's no longer true, and 999.
2. **The README**, for people.
3. **A guide for agents using the product**, if agents use it.
4. **A skill sheet for agents building with the product**, if there is one.

Keep `AGENTS.md`, which is for agents working *on* the codebase, separate
from guides for agents *using* the product.

## 7. Documenting the code

Code should explain itself through clear names, small functions, and plain
structure. On top of that, **every module and every public function is
documented in words**, for a person reading it for the first time.

### Who you're writing for

Assume the reader **knows how to program, but doesn't know this language
well, and knows nothing about this project.** They know what a loop, a
function, and an HTTP request are. They may not know the language's idioms
and conventions (pattern matching, lifetimes, decorators, a return-value
convention), and they don't know the project's own terms.

- **Explain what they can't know**: the project's terms, the language's
  idioms, and why the code is the way it is. Say it in a few words, or link
  to where it's explained.
- **Don't explain what they already know.** Skip loops, variables, and what
  an API is. Over-explaining is talking down, and it buries what matters.
- **Write for the real audience.** A library's public API is read by its
  users; an internal module is read by the next contributor. Pitch each one
  at its reader.

### How to write it

- **Terse, to the point, and thorough.** Short, plain sentences in the
  present tense. Cover everything a caller needs: what it does, what it
  takes, what it returns, how it fails, and any side effects. Leave out
  everything else.
- **Show an example** wherever usage isn't obvious. Where the doc tool can
  run examples as tests (doctests), make them runnable, so they can't go
  stale.
- **Link everything you reference**: other modules and functions (with the
  doc tool's cross-reference syntax), the spec that defines the behavior,
  external docs, standards, and the language docs for any idiom the reader
  may not know.
- **Every module starts with an overview**: what it's for, how it fits into
  the project, and the spec it implements.
- **Comments inside functions say why, not what.** Explain non-obvious
  decisions, workarounds, and the bug a line guards against. If a comment
  only restates the code, delete it or make the code clearer.

### When and where

- **Write the docs as you write the code**, in the same step and the same
  commit. Not afterwards, and not "later". Write a function's doc when you
  write its first test, and finish it in the refactor step (section 3).
- **Use the doc tool's format** (the **doc tool** binding), so the docs
  render, cross-link, and get checked. **precommit** builds them, and a
  broken link or a doc warning fails it like any other warning.
- **A wrong doc is worse than none.** When the code changes, its docs change
  in the same commit.

## 8. Housekeeping review before every commit

Code alone can't check everything that matters, so **every agent does this
review before every commit**, and fixes what it finds. Do it even if your
change didn't cause the problem. Put fixes for problems you didn't cause in
a separate commit, so the history stays readable. If fixing something isn't
yours to do, tell the user in your summary.

**Specs**

- [ ] 000 describes the project as it is now. Read it against the code and
      the specs: the model, rules, architecture, and dependencies are all
      current, with nothing that has since changed.
- [ ] Every spec file is in 000's index, with its summary and status
      current, and every index link works.
- [ ] Every spec has `Status:` (one of the four) and `Created:` lines.
- [ ] Specs this change ships are marked `implemented`. No shipped spec still
      says `draft`.
- [ ] Specs marked `implemented` changed only in their Status line and Log.
      Any other change to their text belongs in a log entry or a new spec.
- [ ] Every implemented spec this change affects has a dated log entry.
      Recent commits that changed behavior without one get one now.
- [ ] 999: shipped items are deleted, and new open questions or deferred work
      are added.
- [ ] Each behavior on the touched specs' `## Tests` lists has a test.

**Docs**

- [ ] Every doc under the **docs** binding matches what the code does now.
      Check names, options, defaults, environment variables, and commands
      against the code, not against memory.
- [ ] Every file under the **copies** binding matches its source. Make the
      copy if it's yours to make; otherwise tell the user.
- [ ] Nothing still refers to removed or renamed things. Search the repo for
      the old names.
- [ ] Setup and run instructions still work as written.

**Agent notes**

- [ ] Memory notes and other saved agent context about this project are
      still true. Fix or delete the wrong ones, and record what was learned.
- [ ] The rules in `AGENTS.md` and this file still describe how the project
      actually works. Raise any gap with the user.

**Code and tests**

- [ ] **precommit** passes, and coverage is over 90%.
- [ ] No leftover debug output, commented-out code, or TODOs that belong in
      999.
- [ ] No tests were weakened, skipped, or deleted to get green (section 3).
- [ ] The mutation check ran on the touched files, and every survivor is
      killed or explained (section 5).
- [ ] Every module and public function this change touches has docs in the
      **doc tool**'s format that match what the code does now, with links
      to what they reference (section 7).
- [ ] No secrets, credentials, or personal paths in anything committed.

**The commit**

- [ ] One behavior per commit, small enough to review in one sitting:
      roughly 200 lines of changed code at most, not counting tests and
      docs. Split bigger work along the spec's `## Tasks`. Pure renames and
      generated files can be larger, in a commit of their own.
- [ ] Imperative subject naming the behavior. The body says what changed and
      **why**, and gives the spec number.
- [ ] Ticked off the task in the spec's `## Tasks`, if it has one.

## 9. Working with the user

- **`AGENTS.md` is the project's contract.** Project-specific rules and the
  bindings live there, in short imperative sentences. A rule that isn't
  written down doesn't exist for the next agent.
- **Write the setup down once.** When an agent first gets the toolchain
  working somewhere new (a cloud container, a fresh machine), it adds the
  verified steps to the project's setup docs, so the next agent doesn't
  spend an hour on it.
- **Save lessons where the next agent will find them.** When something goes
  wrong, save the lesson and why it matters, as one fact per note.
- **Explore, plan, then build.** Before changing anything, read 000, the
  specs involved, and the code. For anything beyond a small fix, agree the
  plan with the user (the draft spec and its `## Tasks`) before writing
  code. Code that solves the wrong problem is the most expensive kind.
- **Follow the branching binding.** Don't push, open pull requests, or merge
  unless the binding or the user says to.
- **Plain language everywhere.** Specs, docs, commits, and summaries to the
  user are short and plain, pitched like the code docs (section 7): explain
  what the reader can't know, and nothing they already do.
- **Progress updates.** During long work, write one line between steps
  saying what's next. Long silence looks like a hang.
- **Security talk is about likelihood × impact.** Lead with one simple
  recommendation and state the remaining risk once. Don't stack worst cases
  and extra layers.
- **Audits.** Every so often, audit the project against a mature competitor's
  history of big failures. Fix what you find, and log the rest as open
  questions.
- **Run the app the supported way** (the **run** binding), with health checks
  and automatic restarts where the setup allows. A process can hang without
  crashing.

## 10. New-project checklist

- [ ] `OP-PARAMS.md` (this file) at the repo root, and an `AGENTS.md` whose
      first line tells agents to read it, followed by the project bindings
- [ ] `specs/000_overview.md` (the living overview, with the spec index) and
      `specs/999_todo.md`
- [ ] A **precommit** command: warnings as errors, format, unused
      dependencies, tests
- [ ] A coverage tool with a 90% floor in its config
- [ ] The **doc tool**, with its build in precommit and warnings as errors
- [ ] A **mutation** tool, and the **security** scans in CI, with the
      lockfile committed
- [ ] **CI** running precommit in check mode, with the same versions as
      production
- [ ] A **run** setup with health checks, restarts, and migrations on boot
- [ ] A guide or skill sheet, if agents will use the product
- [ ] A setup doc for new environments, once the first one works
- [ ] An example env file, with the real one ignored by git

---

## Versions

The version has two numbers. The first goes up when a change asks more of
agents or changes what they must do: a new rule, a stricter rule, a changed
binding. The second goes up for clarifications, examples, and wording that
don't change what agents do. A project's `AGENTS.md` names the version it
follows.

- **1.0** (2026-11-03): the first version.
