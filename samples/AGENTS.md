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

A run works like this. Something starts it (a web request, a schedule, or a person clicking Run). Each step's output becomes the next step's input, one item at a time: every step has a queue in front of it, and items flow through as soon as they're ready (see How data flows).

Only folders containing a `workflow.toml` are workflows. Other files are ignored.

## Comments for people

People look at workflows too, mostly on the app's canvas: a picture of the workflow, one box per step with arrows between them. Each box shows the step's name and **the comment at the top of its step file**. The top box, and the Workflows page, show **the comment at the top of `workflow.toml`**. So always leave both, written for a person skimming, not for you:

- At the top of `workflow.toml`: what the workflow is for, what starts it, and what comes out. A `Try it:` line with a `curl` is welcome.
- At the top of every step file (the `.toml`, not the `.exs`): one or two plain sentences on what the step does, and anything surprising (a route it sends items down, a credential it needs).

```toml
# Looks up each new signup in the CRM and sends the ones it finds to "known".
module = "PurpleFlow.Nodes.Code"

[config]
file = "lookup.exs"
```

The comment is the `#` lines before the first setting. Comments further down are fine for notes on a setting, but they don't show up anywhere. Keep them current when a step changes.

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
# Fetches new orders every hour and flags the big ones.

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
| `after = ["a"]` | this step gets step `a`'s items. Leave it out for the first step, which gets what started the run |
| `when = "big"` | only take items the step before sent down the route named `big` (see Branching). Needs exactly one `after` |
| `concurrency = 5` | at most this many of this step's runs at once, across the whole run (default 1000). `1` means one at a time, in order |
| `delay = 200` | milliseconds between starts of this step's runs (default 0). For rate-limited APIs |
| `timeout = 60` | seconds one run of the step may take before it's stopped (default 0: no limit) |
| `max_queue = 100` | the most items that may wait in this step's queue (default: no limit) |
| `on_full = "wait"` | with `max_queue`: what happens when the queue is full. `"wait"` (default) holds back the steps feeding it; `"overflow"` sends extra items down the `overflow` route instead |
| `on_fail = "end_run"` | a failure here ends the whole run. Default `"continue"`: only that item stops |

Webhook options:

| Option | Meaning |
|---|---|
| `respond = "result"` | the default: wait for the run and reply with its result (or a Respond step's answer, sooner) |
| `respond = "immediately"` | reply right away with the run's ID instead of waiting for the result. Use this for anything that takes more than about a minute |
| `respond = "stream"` | reply with a server-sent event stream: each result as it's made, then an `end` event (see Streaming) |
| `auth = "SOME_NAME"` | callers must send `Authorization: Bearer <secret>`, where the secret is a stored credential named `SOME_NAME`. Anyone else gets `401` and no run starts |
| `auth_header = "x-some-header"` | with `auth`: read the secret from this header instead, as is, with no `Bearer ` in front (some services, like Telegram, send it that way) |
| `max_upload = 100000000` | the most bytes one request may send, files included (default 100 MB; `0` = no limit). Bigger gets `413` (see Files) |

## Step files

A step file names what kind of step it is (`module`) and how it's set up (`[config]`). There are nine kinds.

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

Add `stream = "sse"` (server-sent events), `"ndjson"` (one JSON value per line), or `"lines"` (plain text lines) to read a streamed response as it arrives. Each event or line becomes its own item and moves on right away, while the rest is still coming. A server-sent event arrives as `{"event": "message", "data": ..., "id": "..."}`, with `data` already decoded if it's JSON. Streams from AI APIs usually want `stream = "sse"`.

**Command on another machine (SSH)**

```toml
module = "PurpleFlow.Nodes.Ssh"

[config]
host = "server.example.com"
user = "deploy"
private_key = "{{ creds.DEPLOY_SSH_KEY }}"   # or: password = "{{ creds.DEPLOY_PASSWORD }}"
host_key = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"
command = "df -h /"
stdin = "{{ input.text }}"                   # optional: sent to the command's input
# or: stdin_file = "{{ input.body.doc }}"   # a file's bytes instead (see Files)
connect_timeout = 30                         # optional: seconds to connect; 0 = no limit
```

The output is `{"stdout": "...", "stderr": "...", "exit_status": 0}`. A command that exits with anything but 0 fails the step. `port` defaults to 22. `host_key` is the server's fingerprint (`ssh-keyscan server.example.com | ssh-keygen -lf -` prints it); with it set, a different server is refused before it sees the password or key; without it, any server key is accepted. `command` can use `{{ }}` like any other value, so one SSH step can run whatever command the workflow builds. It runs in the server's shell, so whatever ends up in it runs there too.

Add `stream = "lines"` (plain text lines) or `"ndjson"` (one JSON value per line) to hand on each line the command prints as it arrives. With `command = "tail -f /var/log/app.log"`, that follows a log until the step is killed or times out.

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

**Batch**

```toml
module = "PurpleFlow.Nodes.Batch"

[config]
size = 100       # hand on a batch once it has this many items
wait = 2000      # optional: or once the oldest has waited this many milliseconds
```

Gathers items and hands them on as one: `{"items": [...]}`. The step after it runs once per batch and reads `input.items`. The last, smaller batch goes once nothing more can reach it, so nothing is left behind. Use it for bulk inserts, summaries, and APIs that take many records per call.

**Run another workflow**

```toml
module = "PurpleFlow.Nodes.Workflow"

[config]
workflow = "other_flow_name"
```

The output is whatever that workflow outputs. This step waits for it to finish, with no time limit unless the step sets `timeout`. A workflow may run itself this way; see Guidelines.

**Wait**

```toml
module = "PurpleFlow.Nodes.Wait"

[config]
ms = 5000                          # wait this many milliseconds
# or: until = "2026-10-01T09:00:00Z"
```

Waits, then hands its input on unchanged. Each item waits on its own. The step's `timeout` covers the wait.

**Answer the webhook now (Respond)**

```toml
module = "PurpleFlow.Nodes.Respond"

[config]
status = 202                       # default 200
headers = { "x-job" = "{{ input.body.id }}" }  # optional
body = { accepted = true }         # default: this step's input. Text is sent as text, anything else as JSON
```

Answers whoever called the webhook right away, and the run carries on without them. Use it to say "got it" quickly and keep working. It only answers a webhook that's waiting for the result (the default); the first Respond step to run answers, and any later one does nothing. The step hands its input on unchanged.

**Do nothing (Noop)**

```toml
module = "PurpleFlow.Nodes.Noop"
```

Hands its input on unchanged. A named place for branches to meet, or a placeholder.

## Filling in values: `{{ }}`

Any text in `[config]` can include values from the run:

| Write | Gets |
|---|---|
| `{{ input.user.id }}` | a field from this step's input. Use numbers for list positions: `{{ input.items.0 }}` |
| `{{ steps.fetch.output.total }}` | a field from the item an earlier step produced on the way to this one. If `fetch` returned 500 users, the step handling user 7 sees user 7. Only steps that lead to this one, not steps on another branch |
| `{{ creds.SOME_NAME }}` | a stored secret |

If the whole value is a single `{{ }}`, the original value is kept as is, so lists stay lists and numbers stay numbers. A `{{ }}` pointing at something that doesn't exist fails the step.

## Secrets

Never put a password, API key, or token in a file. Refer to secrets by name with `{{ creds.SOME_NAME }}`.

You can't create secrets or see their values. A person adds them in the app. If your workflow uses a name that hasn't been set, it won't load, and the problem list says which name is missing. Tell the person you're working with that name so they can add it. (After a big import, the Credentials page has a button that creates an empty entry for every missing name at once, so the person only has to fill in values.)

Some secrets are **OAuth logins** (Gmail, Google Drive, and other services where you "sign in with" an account). The person connects those in the app too. In your workflow they work the same way: `{{ creds.GMAIL }}` is a working access token, kept fresh by the app, so an HTTP step sends it as `authorization = "Bearer {{ creds.GMAIL }}"`. If the service stops accepting the login, the step fails with a message saying it needs reconnecting; pass that on to the person. To ask for one, tell the person the service, the name you'll use, and the scopes it needs (for sending Gmail: `https://www.googleapis.com/auth/gmail.send`).

## How data flows

- **One item, one run.** A step runs once for every item it gets, and each run gets exactly one item.
- **A list splits.** When a step returns a list, each element becomes its own item. If 10 items each produce 5 results, the next step runs 50 times. An empty list means nothing goes on.
- **Anything else is one item**, including an object holding a list. Return `{"rows": [...]}` and the next step gets the whole list in one run. That's how you keep a group together. The Batch step does it for you.
- **Every step has a queue.** Items don't wait for the rest of their step: each one moves on to the next step's queue as soon as it's ready. The next step takes items off its queue as fast as its `concurrency` and `delay` allow. So items finish in whatever order they finish, not the order they came in, unless a step has `concurrency = 1`.
- **Failures stop one item, not the run.** A failed item goes no further, and the rest carry on. To handle failures, add a step with `when = "failed"` after the step that might fail: it gets `{"error": "...", "input": <the item>}`. To stop everything on the first failure (an email blast, say), set `on_fail = "end_run"` on that step.
- **Branching:** a Code step can send its result down a named route, and only steps with a matching `when` get it. Each item takes its own route.
- **Joining back up:** a step with several `after` entries gets the items from all of them, one run per item.
- **The result of the run** is the output of the last step (the one nothing comes after): its output if it ran once, or all its items as a list if it ran more than once. With several last steps, it's `{"step_name": output, ...}`, one entry per step that ran.
- **Kill:** a run that's stuck can be stopped from its page in the app.

## Streaming

Three things stream:

- **An HTTP step with `stream`** hands on each message of the response as it arrives (see HTTP request above).
- **An SSH step with `stream`** hands on each line the command prints as it arrives (see SSH above).
- **A webhook with `respond = "stream"`** replies as a server-sent event stream. Every item the last step produces is sent as `data: <item as JSON>` as soon as it exists, and the stream ends with `event: end` and `data: {"status": "complete", "run_id": "..."}`.

Together: a webhook that streams an AI's answer back to its caller is a workflow whose last step is an HTTP step with `stream = "sse"` and whose webhook has `respond = "stream"`. Items stream back as they arrive.

## Guidelines

This is a power tool. It won't stop you from doing big or risky things; it gives you the controls to do them well. Things to keep in mind:

- **Think about the queues.** Every step has a queue, and it fills whenever items arrive faster than the step handles them. A slow step after a fast one (an AI call after a database query, say) builds a queue. That's fine; it's what queues are for. Watch the run page: it shows each step's queue, what's running, and how many succeeded.
- **Pace calls to outside services.** A step's `concurrency` (how many at once) and `delay` (milliseconds between starts) apply across the whole run. For an API that allows 10 requests a second, use `delay = 100`. For an API that dislikes parallel calls, use `concurrency = 1`.
- **Hold back or spill over.** `max_queue` caps a queue. With `on_full = "wait"`, the steps feeding it slow down to match. With `on_full = "overflow"`, extra items go to a step with `when = "overflow"`, where you decide what happens to them.
- **Group before bulk work.** Put a Batch step before bulk inserts and before APIs that take many records at once, instead of making one call per item.
- **Mind the fan-out.** A list of 1,000 items that each produce 1,000 more is a million runs of the next step. There's no limit, so it will do exactly that.
- **Decide what a failure means.** The default is to let one item fail and carry on. Add a `when = "failed"` step to log, retry elsewhere, or notify someone. Use `on_fail = "end_run"` where one failure means the rest shouldn't happen.
- **Set a timeout where it matters.** There's no time limit by default. A step calling something that can hang forever should set `timeout`.
- **Order is yours to keep.** Items flow in whatever order they finish. If order matters, use `concurrency = 1` on the steps where it does, or put things back in order in a Code step after a Batch.
- **Workflows may run themselves.** A workflow can run itself, directly or through others, as deep as you like. It's up to you to make sure it stops.

## What a webhook sends in

A workflow started by a web request gets:

```json
{"body": <what the caller sent>, "query": <URL parameters>, "headers": <request headers>}
```

Your first step usually wants `input.body`. Runs started with the Run button in the app get the same shape, so one workflow works both ways. The caller's `authorization` and `cookie` headers (and the `auth_header`, if set) are left out, so they're never saved.

## Files

A webhook can take files, sent as a form upload (`multipart/form-data`):

```sh
curl -F note=hello -F doc=@report.pdf "BASE/hooks/my-flow"
```

The file itself isn't put in the input. It's saved on the server, and the input holds a small reference to it where the file was:

```json
{"body": {"note": "hello", "doc": {"file": "0192…/0192…", "name": "report.pdf", "type": "application/pdf", "size": 48213}}, ...}
```

The reference moves through steps like any other value. To send the file somewhere, give it to an SSH step's `stdin_file`:

```toml
command = "cat > /srv/uploads/report.pdf"
stdin_file = "{{ input.body.doc }}"
```

A run's files are deleted when the run ends, so use them within the run that received them. Code scripts see the reference, not the file's contents. `name` is whatever the uploader called the file; if you put it into an SSH `command`, the server's shell runs whatever it says.

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

The checks catch broken file syntax, missing files, paths that leave the folder, unknown step kinds and step names, steps that loop back on themselves, misused `when`, bad step and webhook options, `{{ steps.x }}` naming a step that doesn't lead to this one, missing secrets, and script syntax errors.

## Try it

If the workflow has a webhook, call it:

```sh
curl -X POST "BASE/hooks/my-flow" -H "content-type: application/json" -d '{"hello": "world"}'
```

The reply is the run's result (or a Respond step's answer), unless the webhook has `respond = "immediately"` or `respond = "stream"`. If it has `auth`, you need its secret, and you don't have that; ask the person to run it from the app instead.

Real runs do real things: HTTP steps really send requests, and database steps really read and write.

## Rules

- Keep every path inside this folder. Use relative paths only (`node = "../shared/notify.toml"` is fine), with no absolute paths and no `..` that climbs out of the folder.
- Don't put secrets in files.
- Don't try to reach anything but `BASE/fs/`, `BASE/api/workflows`, and `BASE/hooks/`. Nothing else will let you in.