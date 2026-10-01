# 220 — Missing credentials

Status: implemented
Created: 2026-09-30

Importing many workflows at once can leave dozens of credential names to create by hand, one add-row at a time. The `/credentials` page offers to create them all in one click, so the person only has to fill in values.

## What counts as missing

A credential name a workflow folder uses, with no active credential by that name. A folder uses its webhook `auth` and every `{{ creds.NAME }}` in its steps' node files. The names come straight from the files (`PurpleFlow.Workflow.Loader.credential_names/2`), so a workflow that doesn't load, for this or any other reason, still counts. A credential that exists but has no value isn't missing: it already has a row to fill in.

`PurpleFlow.Workflows` records each folder's names at every reload, and `credential_names/1` gives them as `%{name => [folder]}`.

## The page

- Under the search box, only when something is missing: a notice listing the missing names, and a **Create N missing** button.
- The button creates an unset **text** credential for each name, with the description "Needed by" and the folders that use it. Workflows reload once for the whole batch, not once per credential (`PurpleFlow.Credentials.create_stubs/1`).
- A name that can't be a credential (a webhook `auth` with a leading space, say) is skipped and named in an error flash; the rest are still created.
- The notice follows reloads, so it changes as workflow files change.

A stub is always text. For an OAuth login, archive the stub and add it again as OAuth.

## Tests

- Loader: `credential_names` finds webhook `auth` and `creds` references in node configs, nested in lists, once each and sorted, for a workflow that fails to load; a missing file gives none.
- Credentials page: the notice lists names used by workflows that don't exist, not ones that do; the button creates unset text stubs described with the folders that use them, and the notice goes away; no notice when nothing is missing.

## Log

- 2026-10-01 — [230](230_credential_value_types.md): stubs are **String** credentials, the new name for a one-line value. A stub can be switched to Text from its edit row.
