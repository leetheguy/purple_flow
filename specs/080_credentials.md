# 080 — Credentials

Status: implemented
Created: 2026-09-25

## Why

A workflow's secrets — API tokens, database passwords, anything a step needs
to authenticate somewhere — are stored encrypted in Postgres and set through
a dedicated web UI, not written into workflow files or handed to whatever is
building a workflow.

A workflow references a credential by name: `{{ creds.STRIPE_KEY }}` in a
node's `[config]`. That's the only interaction a workflow (or whatever wrote
it) ever has with a credential — a read, by name, resolved at run time. There
is no way for a workflow, a node, or an agent building either to create a
credential, set its value, view its value, or change it. If a workflow
references a name that isn't set, that's a plain, visible error pointing at
`/credentials`, where a human sets it directly. The value never has to pass
through anything that isn't that UI.

This is a narrower guarantee than "credentials are encrypted," which only
protects a database dump or a filesystem snapshot. The [Code node
sandbox](070_code_sandbox.md) is what stops a workflow's own code from
reaching a credential any other way than the one path meant to reach it —
this spec and that one are two halves of the same boundary.

## What this spec covers, and what it doesn't

**Covers:** storing a credential's value encrypted; a `{{ creds.NAME }}`
template kind that resolves it into a node's config at run time; a UI for a
human to create, view (name/description only, never the value), edit, and
archive credentials; a login gate on the whole web UI, since a credential
store behind an open door isn't a credential store.

**Doesn't cover:** per-credential allowed-host locks on the HTTP/Postgres
nodes (see [070](070_code_sandbox.md)'s "Later" section for the same idea).
A credential, once resolved into a workflow's config, can be sent anywhere
that workflow's HTTP step points it — this spec makes credentials safer to
store and grant, not where a workflow holding one can send it.

**Doesn't cover:** credential types, OAuth flows, or scoping a credential to
specific workflows. Every credential is a plain string, usable by name in
any workflow. If that turns out to be too coarse later, it's a narrower
follow-up.

## The credential

| Field | Type | Notes |
|---|---|---|
| `name` | text, unique | how workflows reference it: `{{ creds.NAME }}` |
| `key` | text, encrypted, nullable | the secret value itself |
| `description` | text | free text, shown in the UI so a human remembers what it's for |
| `archived_at` | utc_datetime_usec, nullable | set when the credential is trashed; `nil` means active |

Plus `inserted_at`/`updated_at`, same as every other table here.

`key` is nullable: a credential can exist as a named, documented slot before
a human gets around to filling in the value. A workflow referencing
`{{ creds.STRIPE_KEY }}` before it's set gets a clear "isn't set yet" error,
same as referencing a name that doesn't exist at all. "Set" vs. "unset" (does
`key` have a value) is a different axis from active vs. archived (below); a
row can be in any combination — an unset credential can be archived just as
well as a set one.

### Archiving (trash)

Deleting a credential outright would free its name for reuse. That's the
exact ambiguity [naming](#naming) rejects elsewhere: if a name can point to
two different secrets over time, the name alone stops reliably identifying
one specific secret's history — including in past run records that resolved
it. So trash doesn't delete the row:

- `archived_at` is stamped with the current time.
- `name` is simultaneously replaced with a randomized value, so the original
  name is immediately free for a brand-new credential, with no
  unique-constraint collision against the archived row.
- A workflow referencing the original name afterward gets exactly the same
  error as a name that was never created. `PurpleFlow.Credentials` and
  `PurpleFlow.Template` don't distinguish "never created" from "archived,"
  on purpose — the distinction only matters to a human looking at the
  `/credentials` list, and archived rows don't appear there (see the UI
  section).
- There's no un-archive action. Trash is meant to feel safe to click (the
  record isn't gone), not to be a working undo path.

### Naming

A name has to survive being written as `{{ creds.NAME }}` and parsed back
out by `PurpleFlow.Template` unambiguously. That parser is what derives the
rules, not a general notion of "safe":

- **No `.`** — `{{ creds.a.b }}` is split on every `.`, so a name containing
  one is either truncated silently or collides with how
  `{{ steps.name.output.path }}` is parsed. This is the one rule that would
  cause silent wrong behavior rather than a clear rejection, so it's the one
  that matters most.
- **No `{` or `}`** — the placeholder syntax itself can never contain either
  character inside `{{ }}`, so a name with one could be created but then be
  permanently unreferenceable from any workflow. Rejected at creation
  instead of allowing a dead-end row.
- **No leading or trailing whitespace, and not empty** — surrounding
  whitespace inside `{{ }}` is trimmed before parsing, so `"NAME"` and
  `" NAME "` would parse identically from a workflow, letting two distinct
  rows silently collide in what a workflow actually reaches. Empty string is
  whitespace's degenerate case, rejected the same way.
- **Unique** — enforced at the database level (a unique index), not just in
  the UI, so two concurrent requests can't both create the same name.

No format is enforced beyond that — not `UPPER_SNAKE_CASE`, not any
particular length, no restriction on punctuation, spaces, or unicode beyond
the two literal characters above. `TELEGRAM_BOT_TOKEN` and `lee's stripe key
(prod)` are both valid names.

## Storage: encrypted at rest

`key` is encrypted with AES-256-GCM before it's written, using a master key
read from `PURPLEFLOW_SECRET_KEY` — an environment variable set on the app
container from its parent (host or `docker-compose.yml`'s `environment:`).
Erlang's built-in `:crypto` module does the encryption; no new dependency is
needed for this.

Being encrypted at rest means: someone with only a database dump, or only
filesystem access to the Postgres data directory, can't read credential
values. It does **not** mean the running app can't read them — it has to be
able to, to fill them into a workflow's config and actually call the API in
question. That's an intentional, unavoidable property of any system that
uses the credential, not a gap in this one. What actually stops an
unauthorized *reader* of a credential is the login gate (below) and the
[Code node sandbox](070_code_sandbox.md), which has no code path to
`PurpleFlow.Credentials` at all.

## Reading a credential: `{{ creds.NAME }}`

The one way a workflow references a secret. In `PurpleFlow.Template`:

- `classify/1` has a `["creds", name] -> {:creds, name}` clause.
- `lookup/3` has a `{:creds, name}` clause that calls
  `PurpleFlow.Credentials.get(name)` and pushes the resolved value into the
  `secrets` accumulator, so `PurpleFlow.Redact` scrubs it from every saved
  record, error, and broadcast, the same as any other resolved value.
- A missing credential fails clearly, pointing at the fix: `{:error,
  "credential #{name} isn't set — set it at /credentials"}`.

## `PurpleFlow.Credentials`

The module a template lookup and the UI both go through:

- `list/0`: every **active** (`archived_at` is `nil`) credential's `id`,
  `name`, `description`, and whether it's set (`key` is present) — never the
  key itself, not even to the UI that manages them.
- `get(name)`: the decrypted value of the active credential named `name`, or
  `nil` if it's unset, archived, or was never created — those three cases
  are indistinguishable from here on purpose (see "Archiving" above). This
  is the one function that ever produces a plaintext value, and it's called
  from exactly one place: `PurpleFlow.Template`'s `{:creds, name}` lookup.
- `create(name, description)`: makes a new, active, unset credential.
- `update(id, attrs)`: changes `name`, `description`, and/or `key` (`attrs`
  may include any of the three) on an existing row. Setting `key` here goes
  through the same "encrypt before writing" path as everywhere else — one
  write path for the encrypted value, not several. Used by both the add
  row (via `create/2`, then `update/2` if a value was typed in the same
  submission) and each row's inline edit form.
- `archive(id)`: stamps `archived_at` and replaces `name` with a fresh
  random value, atomically (one update), so a concurrent reader can never
  observe a half-archived row with the old name and a set `archived_at`, or
  vice versa.

No function here is reachable from a Code node's sandboxed peer (see
[070](070_code_sandbox.md)) — that peer has no code path to
`PurpleFlow.Credentials` at all, same as it has none to `PurpleFlow.Repo`.

## UI: `/credentials`

One page, one LiveView. A search box at the top filters the rows below it by
name or description as you type (client-side — this is never going to be a
list with pagination-scale row counts). Below the search box: an
always-present add row, then one row per active credential, newest first.

### The secret field: what the browser is allowed to know

The one rule everything below follows: **the server never sends a stored
`key` value to the browser, in any form, ever** — not even to compute a
mask client-side. A set credential's secret field displays as a fixed
placeholder of dots (ten, say — an arbitrary constant, unrelated to the
real value's length, so the UI can't even leak *that* much) whenever it
isn't being edited. The moment edit mode opens that field, it becomes a
real, empty `<input>` — not pre-filled with dots, not pre-filled with
anything, because there is nothing to pre-fill it with; the server was
never holding a plaintext value to send. What you see while typing into it
is exactly what you typed, nothing more.

### The add row

Always visible, pinned above the list, not something you open with a
button. Three fields — name, description, secret — and a **Save** button
plus a **Clear** button (not Cancel: there's no prior row state to revert
to here, just emptied inputs). Save calls `create/2` and, in the same
submission, `update/2` to set the initial `key` if the secret field wasn't
left empty; Clear blanks all three fields without touching the database.
After a successful save, the row list gets the new credential and the add
row resets to empty, ready for the next one.

### Each row

Two states:

- **Display state** (default): name, description, and the ten-dot secret
  placeholder (or nothing, if unset) as plain text, plus two icons — a
  pencil (edit) and a trash can (archive).
- **Edit state** (after clicking the pencil): the same three fields become
  real inputs. Name and description are pre-filled with their current
  values (those aren't secret; showing them back is fine). The secret
  field opens **empty**, per the rule above — genuinely empty, not
  blank-meaning-"unchanged," with leaving it empty on save meaning "don't
  change the stored key." The pencil/trash icons are replaced with **Save**
  and **Cancel** buttons.
  - **Save** calls `update/2` with whatever changed: name/description
    always, `key` only if the secret field is non-empty when submitted.
  - **Cancel** discards all in-progress edits and returns the row to
    display state, untouched — nothing was written to the database, since
    `update/2` is only ever called on Save.

### Trash

The trash icon calls `archive/1` directly (see "Archiving" above) — no
inline confirmation state, no second click. The record isn't deleted, so
this is treated as safe to act on immediately: the row disappears from the
list (archived rows aren't shown), and its name becomes free for a new
credential right away.

### Copying the name

The name, in display state, is click-to-copy: a single click copies it to
the clipboard, and a small icon next to it flashes briefly (a checkmark
appearing and fading, say) as the only feedback — no toast, no page-level
notification, since this needs to stay lightweight for something that might
happen often.

The secret field has no copy action, in either state. Getting a generated
token or key into the clipboard in the first place (from wherever it was
generated) is the person's own responsibility, same as with any other
password manager's "new value" field — this UI doesn't try to help with
that half of the job, only with never showing the value back out once it's
saved.

No usage tracking, no per-workflow scoping, no credential types — this
module doesn't know workflows exist, and the UI doesn't either.

## Login: gating the whole app, not just this page

Locking `/credentials` alone doesn't accomplish anything if the workflow
that already holds a credential can still be triggered by anyone — running
"the Stripe workflow" gets the same secret out as reading it directly would.
So the login gate covers the entire browser UI (`/`, `/workflows/:name`,
`/runs/:id`, `/credentials`), not just the credentials page.

`/hooks/*` (webhooks) stays unauthenticated. That's the whole point of a
webhook trigger — Telegram, Stripe, or any other external caller has no way
to supply a login. A workflow that needs to verify its caller (checking a
provider's signature header, say) does that itself.

Mechanism: HTTP Basic Auth in front of the `:browser` pipeline in
`PurpleFlowWeb.Router`, checked against `PURPLEFLOW_ADMIN_USERNAME` and
`PURPLEFLOW_ADMIN_PASSWORD` (or a hash of the password — an implementation
detail to settle while building, not a design question), both set from the
container's parent environment. Separate username and password env vars,
rather than one shared secret, on purpose: nothing here needs more than one
account today, but keeping username and password distinct from the start
means real per-user accounts and usage logging later are additive, not a
breaking change to how the container is configured.

## Tests

- `PurpleFlow.Credentials`: create, update (name, description, and key,
  independently and together), list (only active rows, never leaks a
  value), archive (name randomized, `archived_at` set, no longer in
  `list/0`, `get/1` on the old name returns `nil`), and that `get/1`
  round-trips a value through actual encryption and decryption, not just
  in-memory storage.
- Naming validation: rejects `.`, `{`, `}`, leading/trailing whitespace, and
  empty string; accepts everything else, including punctuation and unicode;
  a duplicate active name is rejected at the database level even under
  concurrent inserts.
- `PurpleFlow.Template`: a `{{ creds.NAME }}` reference resolves, redacts,
  and fails clearly when unset — including when `NAME` belongs to an
  archived credential, which must fail identically to a name that was never
  created.
- The router: `/`, `/workflows/:name`, `/runs/:id`, and `/credentials` all
  require Basic Auth; `/hooks/*` doesn't.
- The `/credentials` LiveView:
  - the add row creates a credential and resets itself; Clear blanks it
    without writing anything.
  - a row's Edit button switches it to inputs with name/description
    pre-filled and the secret field empty; Cancel discards changes without
    writing anything; Save persists whatever changed, including leaving the
    secret untouched when that field was left empty.
  - the rendered HTML for a set credential's row never contains the actual
    stored value, in either display or edit state — checked directly
    against the LiveView's rendered output, not just against what the test
    happens to assert on, so a future change can't accidentally start
    leaking it without a test noticing.
  - archiving a row removes it from the list and frees its name for reuse.
  - the search box filters rows by name and description.

## Log

- 2026-09-26 — Fixes found in review: the `key` column is `binary`, not `text`. `set?(name)` is added: it says whether an active credential named `name` has a value, without decrypting anything, and `PurpleFlow.Workflow.Loader` uses it to check `creds.NAME` references at load time (decrypting every referenced credential just to check it was set crashed on a wrong key). The `/credentials` search filters in the LiveView over the full list, not client-side.
- 2026-09-26 — [100](100_runner_container.md): the Code node sandbox this spec relies on is the runner container: scripts run in a separate container with no `PURPLEFLOW_SECRET_KEY` to decrypt with, no database, and no route back to the app. That's what keeps `PurpleFlow.Credentials` out of a script's reach, not a restricted code path.
- 2026-09-26 — [090](090_workflow_files.md) (draft): setting a credential reloads workflows, so one that failed only because its `creds.NAME` wasn't set starts working without anyone touching a file.
