# 190 — Run files

Status: implemented
Created: 2026-09-28

The bare minimum for files: a webhook takes an upload, and an SSH step sends it on. The bytes never go into a run's JSON items or its saved records; items carry a small reference instead, the way n8n keeps binary data apart from its JSON.

## A file reference

```json
{"file": "<run id>/<file id>", "name": "report.pdf", "type": "application/pdf", "size": 48213}
```

- `file` is the file's ID: the run's ID and a new UUID. It's all a node needs to find the bytes. Anything that isn't exactly two UUIDs is refused, so an ID can't point outside the folder.
- `name` and `type` are what the uploader sent (`application/octet-stream` if it sent no type). `size` is in bytes.
- It's ordinary JSON: it moves through steps, templates (`{{ input.body.doc }}` is the whole map), Code scripts, and saved records like anything else.

`PurpleFlow.RunFiles` saves, finds (`path/1`), and deletes files.

## Where the bytes live

In the run files folder: `PURPLEFLOW_RUN_FILES_DIR`, default `/app/run_files` in a release, `run_files/` in dev. Compose mounts a volume of its own there, `purple_flow_run_files`, apart from the workflows folder and the database. Each run's files are in `<folder>/<run id>/`.

## How long they last

As long as their run. A file means nothing without it.

- When a run ends (`complete`, `failed`, or `killed`), its folder is deleted, before `run_finished` goes out.
- At boot, before anything can start a run, the whole folder is emptied: whatever is there belonged to runs a restart cut off.
- A webhook whose run never starts deletes the files it saved.

A run started by the Workflow node gets its parent's references in its input; they stay readable because the parent is waiting on it. Files a child run makes itself are gone once the child ends.

## Webhook uploads

A `multipart/form-data` request to a webhook saves each file with the run, and the run's input holds its reference where the file was:

```sh
curl -F note=hello -F doc=@report.pdf localhost:4000/hooks/upload
```

```json
{"body": {"note": "hello", "doc": {"file": "…/…", "name": "report.pdf", "type": "application/pdf", "size": 48213}},
 "query": {}, "headers": {…}}
```

- `[trigger.webhook]` takes `max_upload`, the most bytes a request may carry: default `100_000_000` (100 MB), `0` for no limit. A bigger request gets `413` and no run.
- The limit is looked up per request, from the webhook being called (`PurpleFlowWeb.MultipartParser`). Other paths keep Plug's default of 8 MB.
- Works with every `respond` mode.

## SSH: `stdin_file`

```toml
module = "PurpleFlow.Nodes.Ssh"

[config]
host = "files.example.com"
user = "deploy"
private_key = "{{ creds.DEPLOY_SSH_KEY }}"
command = "cat > /srv/uploads/report.pdf"
stdin_file = "{{ input.body.doc }}"
```

- `stdin_file` takes a file reference (or its bare `file` ID) and sends the file's bytes as the command's standard input, in pieces, waiting on SSH's flow control, so big files don't sit in memory.
- `stdin` and `stdin_file` together fail to load.
- A value that isn't a file reference, or a file that's gone, fails the item before connecting.
- Putting `name` into `command` (`cat > "/srv/uploads/{{ input.body.doc.name }}"`) runs whatever the uploader named the file in the server's shell. A gentle caution, not a block: the workflow decides.

## Not covered

Other ways of handling files (HTTP responses saved as files, sending a file with the HTTP or Respond node, Code scripts reading bytes, reading files from disk) are left for when they're needed. See [999](999_todo.md).

## Tests

- **RunFiles:** save, find by reference and by ID, delete; anything but a file ID is refused.
- **Webhook:** a multipart upload becomes a reference with the right name, type, and size, beside the form's other fields; the run's files are gone once the reply comes; over `max_upload` gets `413`.
- **Loader:** `max_upload` defaults to 100 MB, takes `0`, and must be a whole number.
- **SSH:** `stdin_file` sends a 3 MB file whole, past the flow control window; a non-file or a gone file fails; `stdin` with `stdin_file` fails to load.
