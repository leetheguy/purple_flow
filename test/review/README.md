# Independent review

A second opinion on a change from another AI, through
[OpenRouter](https://openrouter.ai). It's OP-PARAMS section 5's
independent review: a fresh reviewer, which didn't write the change,
checks it against its spec.

The reviewer only reads. The script sends it text and saves the text it
sends back; it has no tools and no access to the code. Claude checks each
finding against the code and fixes the real ones.

## Setup, once

```sh
cp test/review/.env.example test/review/.env
```

Fill in `OPENROUTER_API_KEY` (from openrouter.ai/keys) and `REVIEW_MODEL`
(a model's ID from openrouter.ai/models). Git ignores `.env`. Settings
already in the environment win over the file.

Your code goes to OpenRouter and to whichever provider serves the model.
OpenRouter's privacy settings can rule out providers that train on what
they're sent.

## Running a review

```sh
test/review/review.sh 297abe5..c135034 specs/260_file_transport.md
```

- The range is what to review (`git diff` takes it as given): usually
  `master..branch`, or the commits a spec landed in.
- The reviewer gets [instructions.md](instructions.md), `AGENTS.md`,
  `OP-PARAMS.md`, the spec, the diff, and the full text of every changed
  file.
- `--context FILE` (any number of times) adds a file the change didn't
  touch but relies on, like the module that calls the changed code.
- `--dry-run` sends nothing: it saves what would be sent and prints its
  size, to check it fits the model's context.
- The report goes to `test/review/reports/` (ignored by git), or `--out`.

## While it runs

The answer streams back, so you can see it working:

```
Reading the spec, the diff (297abe5..c135034), and the changed files…
35 changed files, 0 context files, and the diff: about 127,311 tokens
Sending to z-ai/… through OpenRouter.
The report is written to test/review/reports/c135034-z-ai-….md as it arrives. Press Ctrl-C twice to stop.
Writing the report: 1,240 words, 4:15 (thought 3,100 words first)
```

The last line updates every second: still waiting for the model, thinking
(reasoning models think before they write; the thinking isn't part of the
report), or writing, with the time so far and the words so far. When it's
done, it says how long it took, the tokens in and out, and the cost.

The report is written as it arrives, so stopping early, or an error from
OpenRouter partway, still leaves what came so far. Nothing arriving at
all for 5 minutes counts as a dead connection (OpenRouter sends a
keep-alive while the model works).

Then hand the report to Claude.
