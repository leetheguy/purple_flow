# 110 — Workflow folders

Status: implemented
Created: 2026-09-27

## Why

The workflows folder is a folder. People and agents already know how to
organize one: make a subfolder, move things into it. Purple Flow should
use that structure as it is, both when loading workflows and when listing
them, rather than invent a way of grouping workflows that only exists in
the UI.

## What this spec covers, and what it doesn't

**Covers:** finding workflows at any depth in the workflows folder, what a
workflow's `folder` is, the Workflows page showing the folder tree, and
the Files link for a nested workflow.

**Doesn't cover:** namespacing. Workflow names and webhook paths stay flat
and unique across the whole folder, exactly as in [010](010_workflows.md).
`/workflows/:name`, `/runs`, and `/hooks/:path` don't change. Moving a
workflow into a subfolder doesn't change its name or its history.

## Which folders are workflows

```
workflows/
  AGENTS.md
  hello/                ── workflow
    workflow.toml
  billing/              ── group
    invoices/           ── workflow  (folder "billing/invoices")
      workflow.toml
    reports/            ── group
      monthly/          ── workflow  (folder "billing/reports/monthly")
        workflow.toml
  shared/               ── group with no workflows: not listed
    slack.toml
```

- **A folder with a `workflow.toml` is a workflow**, at any depth.
- **A folder without one is a group.** The app looks inside it for more
  workflows and groups.
- **The app doesn't look inside a workflow's folder.** Everything under
  it belongs to that workflow. `hello/tmp/workflow.toml` is a file of
  `hello`, not a second workflow.
- The search skips dot-folders like `.git` and doesn't follow symlinks,
  the same way the folder watcher does. A symlinked folder is neither a
  workflow nor a group. It was never watched for changes anyway, so
  editing inside one never reloaded.
- A workflow's **`folder`** is its path relative to the workflows folder,
  using `/`: `hello`, `billing/invoices`. It's what the status endpoint
  reports and what the Files link opens. Two workflows in
  `billing/sync/` and `ops/sync/` are two different folders. Their `name`s
  must still differ.
- Every path rule in [090](090_workflow_files.md) still applies to the
  whole workflows folder, not to the workflow's parent folder.
  `../../shared/slack.toml` from `billing/invoices/` is fine.

## The Workflows page

The list mirrors the folder tree:

```
▸ billing
    ▸ reports
        monthly
    invoices
hello
ping
```

- **Groups come before workflows, at every level.** Within each, sorted
  by name. The same order as a file browser.
- A group is a small heading row with a folder icon and its own name (not
  the full path). Each level down is indented a little more. The
  workflow cards themselves don't change.
- Only groups that lead to at least one listed workflow show up. `shared/`
  above never appears.
- **Search** filters workflows as it does now, and matches the full
  folder path. `billing` finds everything under `billing/`. A matching
  workflow always shows the groups above it, so you can tell where it
  lives. Groups with no matches are hidden.
- Groups can't be collapsed. That can come later if lists get long.
- **Didn't load** entries keep showing their path, which already includes
  any subfolders.
- DOM ids that use a folder (`load-error-…`, `group-…`) replace `/` with
  `--` and spaces with `-`, so they stay valid ids.

## The Files link

Each workflow card's **Files** button opens `/files/<folder>/`, which
shows that workflow's folder in the files browser. For
`billing/invoices` that's `/files/billing/invoices/`.

The link passes the folder to the verified route as a list of segments
(`~p"/files/#{Path.split(folder)}"`), so each segment is encoded on its
own and a name with a space or a `#` still works. A plain string would be
encoded as a single segment: `/files/billing%2Finvoices/`, which doesn't
open the folder.

## Docs

- `samples/AGENTS.md` and the README: workflows can go in subfolders, and
  a folder with a `workflow.toml` is a workflow, at any depth. Names stay
  unique across all folders.
- On implementation, add a Log entry to [090](090_workflow_files.md)
  (workflows at any depth, `folder` is a relative path, symlinked folders
  aren't searched) and to [060](060_ui.md) (the Workflows page shows the
  folder tree).

## Tests

**Loading** (`PurpleFlow.Workflows`, on a temporary folder):

- a workflow two levels down loads, with `folder` `a/b`
- `hello/tmp/workflow.toml` isn't loaded as a second workflow
- `billing/sync` and `ops/sync` with different names both load; with the
  same name, the usual duplicate-name problem
- a node path climbing from a nested workflow to `shared/` loads; one
  leaving the workflows folder doesn't
- a symlinked folder isn't searched
- editing a file in a nested workflow reloads it

**Workflows page:**

- groups are listed before top-level workflows, and nested groups before
  their sibling workflows
- a group with no workflows doesn't appear
- searching for a nested workflow shows its groups and hides the others
- a nested workflow's Files link is `/files/billing/invoices/`, and a
  folder name with a space is encoded within its segment

## Log

- 2026-09-27 — **Groups collapse.** Replaces "Groups can't be collapsed." Each group starts collapsed; clicking its heading opens or closes it. Which groups are open is kept on the page's server side, so it survives the page updating when runs start and finish, but not a reload. While a search is typed, every group with a match is shown open; clearing the search goes back to what was opened by hand.
