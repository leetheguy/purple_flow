# 260 — File transport

Status: draft
Created: 2026-11-07

PurpleFlow moves files; it doesn't make or change them. A file comes into a run (a webhook upload, an HTTP download, an SSH command's output, a Postgres `bytea` value), travels from step to step as a reference ([190](190_run_files.md)), and goes out, bytes and all, to something that keeps or uses it (an HTTP request, an SSH command, a Postgres row). Converting, parsing, resizing, and storing files for good are jobs for the tools and services a workflow connects to.

## How long a file lasts

As long as its run, as in [190](190_run_files.md). Inside the run, the reference is how steps share the file: the step that sends it reads the real bytes.

The reference means nothing outside the run. A workflow that needs a file later sends it somewhere that lasts (S3, a server over SSH, a database) and hands on that place's own link or key. The same goes for anything that answers with a file: a webhook reply, a Workflow node's child run, a chat tool showing an image. Each gets a link to where the workflow saved the file.

A child run started by the Workflow node can read the files its parent handed it. The files it brings in itself are gone when it ends, so a reference to one of them is no use to the parent.

## `max_file_size`

```toml
[workflow]
name = "backups"
max_file_size = 100_000_000   # bytes; default 100 MB; 0 for no limit
```

The largest file that can come into the workflow's runs, checked on each file as it arrives: every webhook upload, HTTP `response_file`, SSH `stdout_file`, and Postgres `bytea` read. A bigger file fails the item it came in on (a webhook answers `413` and starts no run), and the partial file is deleted. Files going out aren't checked again.

100 MB holds nearly any text or document, any image, and a short video. Raise it for big videos, archives, or database dumps; `0` turns it off.

It's separate from the webhook's `max_upload` ([190](190_run_files.md)), which limits a whole request, form fields and every file together.

## Bringing files in

Every way a file comes in streams it to disk as it arrives, keeping count against `max_file_size`, except Postgres (see below). The reference's `size` is the number of bytes saved.

### HTTP: `response_file`

```toml
[config]
url = "https://reports.example.com/{{ input.id }}.pdf"
response_file = "report.pdf"     # or true: named by the response
```

- A 2xx response's body is saved as a file, and the step's output is its reference.
- The name is `response_file`'s text. With `true`, it's the filename in the response's `content-disposition`, else the URL's last path segment, else `response`.
- The type is the response's `content-type`, else guessed from the name.
- The body is asked for uncompressed, so the file holds exactly what the URL serves.
- A non-2xx response fails the item, with the start of its body in the message, and saves no file.
- Fails to load alongside `stream`.

### SSH: `stdout_file`

```toml
[config]
command = "pg_dump shop | gzip"
stdout_file = "shop.sql.gz"
```

- The command's standard output is saved as a file named `stdout_file`. Its type is guessed from the name (`application/octet-stream` if the name doesn't say).
- Output is `{"stdout": <file reference>, "stderr": ..., "exit_status": 0}`.
- A non-zero exit status fails the item, as always, and the file is deleted.
- Fails to load alongside `stream`.

### Postgres: reading `bytea`

```toml
[config]
query = "SELECT id, filename, data FROM attachments WHERE id = $1::text::uuid"
params = ["{{ input.id }}"]
files = ["data"]
```

- Each column named in `files` is saved as a file, and the row holds its reference in place of the bytes. Its name is the column's name and its type `application/octet-stream`.
- A `NULL` stays `null`. A column in `files` that isn't `bytea`, or isn't in the result, fails the item.

## Sending files out

### HTTP: `body_file` and multipart forms

```toml
[config]
method = "PUT"
url = "https://storage.example.com/uploads/{{ input.body.doc.name }}"
body_file = "{{ input.body.doc }}"
```

- `body_file` takes a file reference (or its bare ID) and sends the file as the request body, streamed from disk. `content-type` is the reference's `type` unless `headers` sets one; `content-length` is its size.
- `body` and `body_file` together fail to load.

```toml
[config]
method = "POST"
url = "https://api.example.com/documents"
form = { title = "{{ input.body.title }}", doc = "{{ input.body.doc }}" }
```

- `form` sends `multipart/form-data`. A file reference becomes a file part with its name and type, streamed from disk; any other value becomes a text field.
- `form` with `body` or `body_file` fails to load.

### SSH: `stdin_file`

Already in [190](190_run_files.md).

### Postgres: writing `bytea`

```toml
[config]
query = "INSERT INTO attachments (filename, data) VALUES ($1, $2)"
params = ["{{ input.body.doc.name }}", "{{ input.body.doc }}"]
```

- A param that's a file reference is sent as the file's bytes, so it fits a `bytea` column. A reference saved as JSON would mean nothing after the run, so there's no other way to read one.

Postgres sends a value whole, so a file read or written this way sits in memory for the step (once per item running at the same time). A gentle caution in the docs; `max_file_size` and `concurrency` are the controls.

## In every case

- A value that isn't a file reference, or a file that's gone, fails the item before connecting, with the message `RunFiles.path/1` gives.
- A failure partway leaves no partial file behind.

## Not covered

- Making or changing files (Code scripts reading or writing bytes, converting, extracting text). Done by external tools a workflow calls.
- Answering a webhook with a file, and passing images to OpenAI Chat. Pass a link to where the file was saved.

## Tests

- **max_file_size:** defaults to 100 MB, takes `0`, must be a whole number; a webhook file over it gets `413` and no run; an HTTP download, SSH output, or Postgres value over it fails the item and leaves no file.
- **HTTP `response_file`:** a 3 MB download is saved whole, with the given name and the response's type; `true` names it from `content-disposition`, then the URL; a non-2xx fails and leaves no file; fails to load with `stream`.
- **SSH `stdout_file`:** a 3 MB output is saved whole, with the right name, guessed type, and size; a non-zero exit fails and leaves no file; fails to load with `stream`.
- **Postgres reads:** a `bytea` column in `files` becomes a reference holding the same bytes; `NULL` stays `null`; a column that isn't `bytea` fails.
- **Postgres writes:** a file reference param lands in a `bytea` column byte for byte; a gone file fails before querying.
- **HTTP `body_file`:** the server receives the file whole, with the reference's type and the right length; `headers` can set the type; fails to load with `body`.
- **HTTP `form`:** file parts arrive with their name, type, and bytes beside the text fields; fails to load with `body` or `body_file`.
- **Every consumer:** a non-file value or a gone file fails the item before anything is sent.
- **Release:** in the Docker stack, a file comes in over one node and goes out over another, and the run files folder is empty once the run ends.

## Tasks

- [x] `RunFiles`: save from a stream, counting against a limit and deleting a partial file on failure; nodes can save files into the current run (`PurpleFlow.Node`, like `emit`).
- [x] `[workflow] max_file_size`: loading, and the webhook's per-file check.
- [x] HTTP `body_file`.
- [x] HTTP `form`.
- [x] HTTP `response_file`.
- [ ] SSH `stdout_file`.
- [ ] Postgres `bytea` writes.
- [ ] Postgres `files` reads.
- [ ] Check the whole path in the Docker release; update the docs (README, `samples/AGENTS.md`, the workflows skill, 000, 999, 190's log); mark this spec `implemented`.
