# 090 — Workflow files: isolated, live, shared through dufs

Status: draft
Created: 2026-09-26

## Why

Workflows are meant to be built by agents. Writing a workflow needs the
workflow files and nothing else: not `.env`, not the app's source, not the
database. And an agent needs to know whether its change worked without
running `mix` or anything else in the app's checkout.

This spec gives workflows their own home:

- **Isolated.** The workflow files are the only thing a workflow author can
  reach. Not the app's source, not its secrets, not the database.
- **Easy to reach.** Agents get HTTP and WebDAV; people get a web UI. Same
  files, same permissions.
- **Live.** A saved change is running within a couple of seconds. No reload
  button, no restart, no `mix` command.
- **Versioned by git, by people.** The workflows folder is its own git
  repository. Nothing commits automatically; whoever manages the workflows
  manages the history.

It's the same pattern as [100](100_runner_container.md): give each job its own
container with only what that job needs.

## What this spec covers, and what it doesn't

**Covers:** where workflow files live, the file server that exposes them,
reloading on every change, keeping workflow paths inside the workflows
folder, and telling an agent whether its change loaded.

**Doesn't cover:** a workflow author reading a credential they were never
meant to use. Anyone who can write a workflow can put `{{ creds.ANY_NAME }}`
in an HTTP node's config and send it anywhere. Isolating the files keeps
authors away from the app, not away from the credentials. Per-credential
allowed-host locks close that; they're still in "Later" (see
[080](080_credentials.md)).

**Doesn't cover:** a Docker or Linux kernel exploit, as in 100.

## The layout

```
host                                   containers
────                                   ──────────
$WORKFLOWS_PATH/  (default ./workflows)
  .git/            ── never visible to dufs
  sync_records/
    workflow.toml  ── dufs:  /data            read-write
    fetch.toml     ── app:   /app/workflows   read-only
  shared/
    slack.toml
```

- The workflows folder is a plain folder on the host, bind-mounted into two
  containers. `WORKFLOWS_PATH` in `.env` points it anywhere; the default
  is `./workflows`.
- **dufs mounts it read-write. The app mounts it read-only.** The app never
  writes workflows, so it can't, even by accident or through a bug.
- **The runner doesn't mount it at all.** The app reads each `.exs` file and
  sends the source to the runner (see 100).
- **The folder is entirely yours.** Nothing tracked by this repo lives
  inside it: the sample workflows live in `samples/` at the repo root, and
  `.gitignore` ignores `/workflows/` outright. That leaves the workflows
  folder free to be its own git repository with no files from this repo
  mixed in.

## dufs

[dufs](https://github.com/sigoden/dufs) is a small single-binary file
server: static serving, uploads, deletes, search, WebDAV, and a web UI. A
third service in `docker-compose.yml`, `files`, runs the official image,
pinned to a specific version.

- **Nothing to steal.** Its compose `environment:` block holds only dufs
  settings (`DUFS_*`): its own login and its flags. No `env_file`, none of
  the app's secrets, no database URL.
- **Nowhere to go.** It's on its own network, `files`, shared with no other
  service. It isn't on the database's network or the runner's. Its only
  connection to anything is the port it publishes.
- **Its own login.** `PURPLEFLOW_FILES_USERNAME` and
  `PURPLEFLOW_FILES_PASSWORD` in `.env`, both required by compose, passed to
  dufs as `DUFS_AUTH="user:pass@/:rw"`. This login is separate from the
  app's admin login: someone who can edit workflows can't see
  `/credentials` or run history just by having that login.
- **Published on `FILES_PORT`** (default 5000), next to the app's `PORT`.
- **Locked down** like the runner: `read_only: true`, `cap_drop: [ALL]`,
  `security_opt: [no-new-privileges:true]`, memory/CPU/process-count
  limits, `restart: unless-stopped`.
- **Runs as the host user** (`user: "${PUID:-1000}:${PGID:-1000}"`), so
  files saved through dufs are owned by you on the host, and `git` and your
  editor keep working on them without permission fixes. The app only needs
  to read them.

### How agents use it

Plain HTTP, no client library needed:

| Do | Request |
|---|---|
| List a folder (JSON) | `GET /sync_records/?json` |
| Read a file | `GET /sync_records/workflow.toml` |
| Write a file | `PUT /sync_records/workflow.toml` with the file as the body |
| Make a folder | `MKCOL /sync_records/` (WebDAV) |
| Delete | `DELETE /sync_records/fetch.toml` |
| Move/rename | `MOVE` with a `Destination` header (WebDAV) |
| Search names | `GET /?q=slack&json` |

Anything that speaks WebDAV (rclone, most OSes' "connect to server") can
mount it as a folder. People use the web UI at the same address.

### Keeping `.git` out of reach

`.git/` is the one thing in the workflows folder that must never be
writable by a workflow author. A file written to `.git/hooks/` runs **on
your machine**, outside every container, the next time you run `git commit`
there. That's a real way out of the box, not a theoretical one.

- An empty, read-only mount covers `/data/.git` inside the dufs container,
  so dufs can't see the real `.git` at all, never mind write to it.
- dufs also runs with `--hidden .git`, so the empty folder doesn't clutter
  listings.
- If the workflows folder isn't a git repo yet, Docker creates an empty
  `.git/` folder on the host as the mount point. `git init` in the folder
  turns it into a real repo; nothing else is needed.

Only the mount is relied on for security. `--hidden` is cosmetic, since it
may only hide the folder from listings.

## The app watches the folder

`PurpleFlow.Workflows` checks the workflows folder once a second and
reloads when something changed. There's no Reload button and no reload
step after editing.

- **Polling, not file-system events.** Each tick lists every file under the
  folder with its size and modified time. The list is small, so the check is
  cheap. Polling needs no native helper (`inotify-tools`) in the image and
  works the same on every kind of mount, including Docker Desktop's, where
  change events from the host are unreliable.
- **Wait for saves to settle.** An agent often writes several files in a
  row. The app reloads only once a change has held still for one full tick,
  so a half-written set of files is never loaded. Worst case, a change is
  live about two seconds after the last save.
- **Also reload when credentials change.** A workflow that failed because a
  `creds.NAME` wasn't set should start working the moment someone sets it at
  `/credentials`, without anyone touching a file.
- `reload/0` reloads immediately, for tests and anything else that can't
  wait for the next tick.

### A broken save doesn't break a running workflow

Reloading works workflow by workflow, keyed by the workflow's folder:

- **Loads cleanly:** the new version replaces the old one.
- **Fails to load, and a previous version was running:** the previous
  version **keeps running**. The problems are recorded against the
  workflow, together with the fact that it's running an older version. The
  UI shows both.
- **Fails to load, nothing was running:** it's listed with its problems.
- **Folder deleted:** the workflow is unloaded and its cron job removed.

Keeping the old version running has two exceptions, because keeping it
would leave two workflows claiming the same thing: if the new version's
`name` or webhook `path` collides with another loaded workflow, the new
version is refused and the old one keeps running as before. That's the same
rule as the duplicate-name and duplicate-path checks in
[010](010_workflows.md).

Runs already in progress are unaffected by any reload. Each run holds its
own copy of the workflow it started with and finishes on that version.

Cron jobs are re-registered only for workflows whose schedule actually
changed, so a reload never drops or doubles a scheduled run.

## Paths stay inside the workflows folder

Every path a workflow names (a step's `node = "..."` and a Code node's
`file = "..."`) must resolve to somewhere inside the workflows folder.

Without this rule, `file = "../../../etc/passwd"` or an absolute path
would make the **app** read a file outside the workflows folder, and the
app's container is the one holding the secrets. With workflow files coming
from agents through dufs, "a workflow can only reach the workflows folder"
has to actually be true.

- Paths are resolved relative to the file that names them, and
  symlinks are followed. If the result isn't inside the workflows folder,
  the workflow fails to load with `step "x": node path leaves the workflows
  folder`.
- Absolute paths are refused outright, with the same message.
- Symlinks must be relative. One with an absolute target is refused even
  when it points inside the folder: the folder is at a different absolute
  path on the host than in the containers, so an absolute link can't mean
  the same thing everywhere.
- A workflow folder that's itself a symlink pointing out doesn't load.
- All of it goes through one function, `PurpleFlow.Workflow.Paths.resolve/3`.
  A node's optional `prepare` callback is `prepare(config, node_dir, root)`,
  so a node that reads a file named in its config (the Code node's `file`)
  resolves it the same way.
- `../shared/slack.toml` is fine: it stays inside the folder.
- Only folders directly under the workflows folder that contain a
  `workflow.toml` are workflows. Dot-folders like `.git` are
  never read.

## Telling an agent whether its change loaded

Agents can't see the UI, and they shouldn't need the admin login to check
their own work. The app gets one read-only JSON endpoint:

```
GET /api/workflows
Authorization: Bearer <PURPLEFLOW_AGENT_TOKEN>
```

```json
{
  "reloaded_at": "2026-09-26T15:04:05.123Z",
  "workflows": [
    {"name": "sync_records", "folder": "sync_records", "webhook": "sync-records",
     "cron": "0 * * * *", "loaded_at": "2026-09-26T15:04:05.123Z", "problems": []},
    {"name": "hello", "folder": "hello", "webhook": "hello", "cron": null,
     "loaded_at": "2026-09-26T09:12:00.000Z",
     "problems": ["hello/numbers.exs line 3: syntax error before: ')'"],
     "running_older_version": true}
  ],
  "not_loaded": [
    {"folder": "draft", "problems": ["step \"fetch\": can't read draft/fetch.toml"]}
  ]
}
```

- **The agent's loop:** save files through dufs, then poll this endpoint
  until `reloaded_at` is later than the save and the workflow's `problems`
  are empty. Then trigger a run through its webhook (or ask a person to use
  the UI's Run button) and read the result.
- `PURPLEFLOW_AGENT_TOKEN` is optional. When it isn't set, the endpoint
  doesn't exist (404). When it is, a missing or wrong token gets 401. The
  token grants this endpoint and nothing else: no runs, no credentials, no
  UI.
- Problems are the same messages the UI shows. They name credentials that
  aren't set, never credential values.
- Rejected from the runner's subnet like every other request (see 100).

## Outside Docker

`mix phx.server` and `mix test` have no dufs. The app reads
`WORKFLOWS_DIR` (default `workflows`), and the watcher runs
there too, so editing a file in your editor is live in dev as well. Tests
point `workflows_dir` at a temporary folder per test that needs to write
files, and drive the watcher with an explicit tick rather than waiting on
the clock.

## Docs

- The workflow skill (`.claude/skills/purpleflow-workflows/SKILL.md`)
  covers the dufs requests above and the save → poll `/api/workflows` → run
  loop. It has no `mix` commands.
- The README covers the `files` service and its `.env` settings, `git init`
  in the workflows folder, and where the samples are.

## Verified

- `mix test`:
  - a path leaving the folder (`../..`, absolute, and a symlink pointing
    out) fails to load with the message above; `../shared/x.toml` loads
  - editing a file reloads that workflow after it settles, and not before
  - a broken save keeps the old version running and reports both facts
  - a name or webhook collision leaves the old version running
  - deleting a folder unloads the workflow and removes its cron job
  - an unchanged cron schedule isn't re-registered on reload
  - setting a missing credential makes its workflow load
  - `/api/workflows`: 404 with no token configured, 401 on a wrong token,
    the shape above on the right one
- Checked against the real compose stack:
  - a file PUT through dufs is live in the app within about two seconds
  - the app can't write to `/app/workflows`
  - `PUT /.git/hooks/pre-commit` through dufs fails, and the host's real
    `.git/hooks/` is unchanged
  - dufs's environment holds none of the app's secrets, and it can't reach
    the database, the app, or the runner
  - files saved through dufs are owned by the host user

## Later (explicitly out of scope for now)

- Per-credential allowed-host locks on the HTTP/Postgres nodes (already in
  080's "Later"; the thing that actually stops a workflow author from
  misusing a credential).
- Separate dufs logins per agent, or per-folder permissions (dufs supports
  both through `DUFS_AUTH`), once more than one agent or person edits
  workflows.
- An endpoint that starts a run and returns its result for agents, so they
  don't need a webhook on every workflow they want to test.
