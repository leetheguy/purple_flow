# Welcome to Purple Flow

Hello, agent and welcome! So nice to have you here.

You've been given access to a folder of workflow files for Purple Flow, a small automation server (like n8n or Zapier), but built with you in mind. You edit workflows by reading and writing plain text files over HTTP. The server notices your changes on its own.

You need two things from whoever sent you here:

- **BASE**: the site's address, for example `https://purple.example.com` (Probably the address you received to read this file.)
- **TOKEN**: an access token

Send the token on every request as a header:

```
Authorization: Bearer TOKEN
```

The token only works for the files and for checking your work. You can't reach anything else, and you don't need to.

## Reading and writing files

All files live under `BASE/fs/`.

| To | Send |
|---|---|
| List a folder | `GET BASE/fs/some_folder/?json` |
| Read a file | `GET BASE/fs/some_folder/file.toml` |
| Write a file (creates folders as needed) | `PUT BASE/fs/some_folder/file.toml` with the file's contents as the body |
| Delete a file | `DELETE BASE/fs/some_folder/file.toml` |
| Rename or move | `MOVE BASE/fs/old/path.toml` with header `Destination: BASE/fs/new/path.toml` |
| Make an empty folder | `MKCOL BASE/fs/new_folder/` |

With curl:

```sh
curl -H "Authorization: Bearer TOKEN" "BASE/fs/?json"
curl -H "Authorization: Bearer TOKEN" "BASE/fs/my_flow/workflow.toml"
curl -H "Authorization: Bearer TOKEN" -T workflow.toml "BASE/fs/my_flow/workflow.toml"
```

Start by listing `BASE/fs/?json` and reading an existing workflow or two. They're the best examples of how things are done here.

## What a workflow is

Each workflow is one folder containing:

- `workflow.toml`: its name, what starts it, and its list of steps
- one small `.toml` file per step, saying what that step does
- optionally, `.exs` script files for steps that run code

```
my_flow/
  workflow.toml
  fetch.toml
  check.toml
  check.exs
```

A run works like this. Something starts it (a web request, a schedule, or a person clicking Run). The steps then run in order, and each step's output becomes the next step's input.

Only folders containing a `workflow.toml` are workflows. Other files are ignored.

Workflows can go in subfolders to keep things organized, as deep as you like:

```
billing/
  invoices/
    workflow.toml
  reports/
    monthly/
      workflow.toml
```

A folder without a `workflow.toml` is just a group, and the server looks inside it for more workflows. A folder with one is a workflow, and the server doesn't look inside it for others. Workflow names must be unique across every folder, and moving a workflow to another folder doesn't change its name. The `folder` in `/api/workflows` is the path from the top, like `billing/invoices`.

## workflow.toml

```toml
[workflow]
name = "my_flow"               # must be unique across all workflows

[trigger.webhook]              # optional: start it with a web request
path = "my-flow"               # it's then at BASE/hooks/my-flow

[trigger.cron]                 # optional: start it on a schedule
schedule = "0 * * * *"         # standard cron: this one is every hour

[[steps]]
name = "fetch"                 # unique within this workflow
node = "fetch.toml"            # the step's file, relative to this one

[[steps]]
name = "check"
node = "check.toml"
after = ["fetch"]              # gets fetch's output as its input
```

Step options:

| Option | Meaning |
|---|---|
| `after = ["a"]` | this step's input is step `a`'s output. Leave it out for the first step, which gets what started the run |
| `when = "big"` | only run if the step before sent its result down the route named `big` (see Branching). Needs exactly one `after` |
| `run = "all"` | when the input is a list, handle the whole list at once instead of once per item |
| `concurrency = 5` | when running once per item, at most this many at a time (default: all at once) |
| `timeout = 60` | seconds allowed per step (default 30) |

Webhook options:

| Option | Meaning |
|---|---|
| `respond = "immediately"` | reply right away instead of waiting for the result. Use this for anything that takes more than about a minute |
| `auth = "SOME_NAME"` | callers must send `Authorization: Bearer <secret>`, where the secret is a stored credential named `SOME_NAME` |

## Step files

A step file names what kind of step it is (`module`) and how it's set up (`[config]`). There are four kinds.

**HTTP request**

```toml
module = "PurpleFlow.Nodes.Http"

[config]
url = "https://api.example.com/items"
method = "POST"                          # default GET
headers = { authorization = "Bearer {{ creds.EXAMPLE_API_KEY }}" }
query = { limit = 10 }
body = { name = "{{ input.name }}" }     # sent as JSON
```

The output is the response body. A response that isn't a success (anything outside 200–299) fails the step.

**Database query (Postgres)**

```toml
module = "PurpleFlow.Nodes.Postgres"

[config]
database_url = "{{ creds.MY_DATABASE_URL }}"
query = "select * from orders where status = $1"
params = ["{{ input.status }}"]
```

The output is a list of rows. Always put values in `params` (`$1`, `$2`, …), never in the query text itself.

**Code**

```toml
module = "PurpleFlow.Nodes.Code"

[config]
file = "check.exs"
```

The script is written in Elixir. It gets `input` (this step's input) and `steps` (earlier steps' results, like `steps["fetch"]["output"]`). Read fields with square brackets and quoted names: `input["amount"]`. The last line is the result:

```elixir
# check.exs
if input["amount"] > 1000 do
  {:ok, input, "big"}      # result, sent down the route "big"
else
  {:ok, input, "small"}
end
```

It can also return `{:ok, value}`, `{:error, "what went wrong"}`, or just a plain value. Scripts have no internet access and no secrets, so fetch data with an HTTP step first and read it from `input` or `steps`. Results must be plain data: text, numbers, true/false, lists, and key/value maps.

**Run another workflow**

```toml
module = "PurpleFlow.Nodes.Workflow"

[config]
workflow = "other_flow_name"
```

The output is whatever that workflow outputs. This step waits for it to finish.

## Filling in values: `{{ }}`

Any text in `[config]` can include values from the run:

| Write | Gets |
|---|---|
| `{{ input.user.id }}` | a field from this step's input. Use numbers for list positions: `{{ input.items.0 }}` |
| `{{ steps.fetch.output.total }}` | a field from an earlier step's output. Only steps that lead to this one, not steps on another branch |
| `{{ creds.SOME_NAME }}` | a stored secret |

If the whole value is a single `{{ }}`, the original value is kept as is, so lists stay lists and numbers stay numbers. A `{{ }}` pointing at something that doesn't exist fails the step.

## Secrets

Never put a password, API key, or token in a file. Refer to secrets by name with `{{ creds.SOME_NAME }}`.

You can't create secrets or see their values. A person adds them in the app. If your workflow uses a name that hasn't been set, it won't load, and the problem list says which name is missing. Tell the person you're working with that name so they can add it.

## How data flows

- **A list runs once per item.** If a step's input is a list, the step runs once for each item, all at the same time, and the results are gathered into one flat list. If 10 items each produce 5 results, the next step gets 50 items, not 10 lists of 5. Use `run = "all"` when a step should get the whole list at once, for example to count, summarize, or insert many rows in one go.
- **An empty list** means the step runs zero times, and so does everything after it.
- **Branching:** a Code step can send its result down a named route, and only steps with a matching `when` run. When a step runs once per item, each item takes its own route.
- **Joining back up:** a step with several `after` entries runs once each time one of those steps finishes.
- **The result of the run** is the output of the last step.
- **Limit:** a step can produce at most 10,000 items.

## What a webhook sends in

A workflow started by a web request gets:

```json
{"body": <what the caller sent>, "query": <URL parameters>, "headers": <request headers>}
```

Your first step usually wants `input.body`. Runs started with the Run button in the app get the same shape, so one workflow works both ways.

## Check that your change worked

Changes take effect about two seconds after your last save. There's no reload step.

Important: if your edit has a mistake, the previous working version keeps running. So "the webhook still answers" doesn't prove your change worked. Check instead:

```sh
curl -H "Authorization: Bearer TOKEN" "BASE/api/workflows"
```

```json
{"reloaded_at": "2026-01-01T12:00:00Z",
 "workflows": [{"name": "my_flow", "folder": "my_flow", "problems": [], "running_older_version": false}],
 "not_loaded": [{"folder": "draft", "problems": ["step \"fetch\": can't read draft/fetch.toml"]}]}
```

Wait until `reloaded_at` is later than your last save. Then check:

- Your workflow is listed under `workflows` with `"problems": []` and `"running_older_version": false`: it worked.
- `"running_older_version": true`: your edit didn't load. `problems` says why, and the old version is still the one running.
- A new workflow that failed shows up under `not_loaded`, with its problems.

The checks catch broken file syntax, missing files, unknown step names, steps that loop back on themselves, misused `when`, missing secrets, and script syntax errors.

## Try it

If the workflow has a webhook, call it:

```sh
curl -X POST "BASE/hooks/my-flow" -H "content-type: application/json" -d '{"hello": "world"}'
```

The reply is the run's result, unless the webhook has `respond = "immediately"`. If it has `auth`, you need its secret, and you don't have that; ask the person to run it from the app instead.

Real runs do real things: HTTP steps really send requests, and database steps really read and write.

## Rules

- Keep every path inside this folder. Use relative paths only (`node = "../shared/notify.toml"` is fine), with no absolute paths and no `..` that climbs out of the folder.
- Don't put secrets in files.
- Don't try to reach anything but `BASE/fs/`, `BASE/api/workflows`, and `BASE/hooks/`. Nothing else will let you in.