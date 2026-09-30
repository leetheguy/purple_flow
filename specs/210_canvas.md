# 210 — Canvas

Status: implemented
Created: 2026-09-30

A read-only picture of each workflow, so a person can see at a glance what it does without reading its TOML: boxes pointing at boxes, like a minimal UML diagram. Workflows are still written in files; this doesn't edit anything.

## Comments are what people read

- A workflow's **comment** is the `#` lines at the top of its `workflow.toml`, before the first line of anything else. A step's comment is the same, from the top of its node `.toml` (not its `.exs` script). Blank lines between comment lines are kept; `#` and one space after it are dropped. A file with no leading comment has none.
- The Workflows page shows each workflow's comment on its card, under its triggers.
- The agent guide (`samples/AGENTS.md`) and the workflows skill ask agents to always write both: the workflow's purpose at the top of `workflow.toml`, and one or two plain sentences at the top of every step file. The samples do.

## The page

`/workflows/:name/canvas`, opened by a **Canvas** button on each workflow's card on the Workflows page.

- **Top to bottom**, so it reads on a phone. A **Start** box comes first: the workflow's name, its comment, and its triggers (webhook path, cron schedule). Then one row per level: a step sits one row below the lowest step it comes `after`. Within a row, steps sit under the steps they come after (the average of where those are), then in file order.
- **Arrows** go from the bottom of a box to the top of each step that comes `after` it, and from Start to every first step. An arrow into a step with `when` is labeled with the route.
- **A box** has a top bar with an icon and the step's kind (HTTP, SSH, Postgres, Code, Batch, Workflow, Wait, Respond, No-op; any other node module shows its last name), and below it the step's name and comment. A Workflow step also shows the workflow it runs.
- **Clicking or tapping a box** goes somewhere else; nothing opens in place. A Workflow step whose `workflow` names a loaded workflow opens that workflow's canvas. Any other box, Start included, opens its file in the Files page's editor (`/files/<path>?edit`). Without a files service (outside Docker), those boxes aren't links.
- **Moving around:** drag with a finger or the mouse (right button or left) to pan; pinch or the mouse wheel to zoom, around the fingers or the pointer. A drag that ends on a box doesn't open it. In the upper right corner, small **zoom out**, **reset view**, and **zoom in** buttons. Reset (and the first view) fits the whole width, never bigger than actual size, with the top showing.
- The page follows reloads: edit a file and the canvas redraws, as the Workflows page does.

The server lays the boxes out; a colocated hook (`.Canvas`) draws the arrows by measuring where the boxes ended up, and handles pan and zoom. Nothing is saved: the view resets on every visit.

## Not included

Editing, dragging boxes, saving positions, collapsing, and live run status on the boxes. An arrow that skips rows is a plain curve and can pass behind boxes in between. A visual builder remains an idea in [999](999_todo.md).

## Tests

- Loader: the leading comment of `workflow.toml` and of node files, with blank lines, `\r\n`, several `#`, and none.
- Workflows page: a workflow's comment shows; the Canvas button opens its canvas.
- Canvas: rows in order, with kinds, names, comments, triggers, and the arrows (with a `when` label); a Workflow step links to the other canvas; other steps link to their file in Files only when there's a files service; the page follows a reload; an unknown workflow says so.
