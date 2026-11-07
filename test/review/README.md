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

Then hand the report to Claude.
