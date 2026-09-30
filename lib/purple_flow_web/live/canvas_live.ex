defmodule PurpleFlowWeb.CanvasLive do
  @moduledoc """
  `/workflows/:name/canvas`: a read-only picture of a workflow. One box per
  step, top to bottom, with an arrow from each step to the steps that come
  `after` it. A box says what kind of step it is and shows the step's name
  and the comment at the top of its node file. Clicking a box opens its node
  file on the Files page, or, for a Workflow step, the other workflow's
  canvas. The start box at the top is the workflow itself: its triggers and
  the comment at the top of `workflow.toml`.

  The server lays the boxes out in rows (a step goes one row below the
  lowest step it comes after); the `.Canvas` hook draws the arrows between
  them, and pans and zooms. See `specs/210_canvas.md`.
  """

  use PurpleFlowWeb, :live_view

  alias PurpleFlow.{Workflow, Workflows}

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(PurpleFlow.PubSub, Workflows.topic())

    {:ok,
     socket
     |> assign(:name, name)
     |> assign(:page_title, name)
     |> assign(:files?, Application.get_env(:purple_flow, :files_url) != nil)
     |> load()}
  end

  @impl true
  def handle_info(_reload, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    case Workflows.fetch(socket.assigns.name) do
      {:ok, workflow} ->
        socket
        |> assign(:workflow, workflow)
        |> assign(:rows, rows(workflow.steps))
        |> assign(:edges, edges(workflow))

      {:error, _} ->
        assign(socket, :workflow, nil)
    end
  end

  # -- layout --

  # Steps in rows: a step goes one row below the lowest step it comes after.
  # Within a row, steps sit under the steps they come after (the average of
  # where those are), then in file order.
  defp rows(steps) do
    by_name = Map.new(steps, &{&1.name, &1})
    order = steps |> Enum.with_index() |> Map.new(fn {step, i} -> {step.name, i} end)

    depths =
      Enum.reduce(steps, %{}, fn step, memo -> step.name |> depth(by_name, memo) |> elem(1) end)

    steps
    |> Enum.group_by(&depths[&1.name])
    |> Enum.sort_by(fn {depth, _} -> depth end)
    |> Enum.map_reduce(%{}, fn {_depth, row}, placed ->
      row =
        Enum.sort_by(row, fn step ->
          spots = for name <- step.after, Map.has_key?(placed, name), do: placed[name]
          spot = if spots == [], do: 0.5, else: Enum.sum(spots) / length(spots)
          {spot, order[step.name]}
        end)

      count = length(row)

      placed =
        row
        |> Enum.with_index()
        |> Enum.reduce(placed, fn {step, i}, placed ->
          Map.put(placed, step.name, (i + 0.5) / count)
        end)

      {row, placed}
    end)
    |> elem(0)
  end

  defp depth(name, by_name, memo) do
    case memo do
      %{^name => depth} ->
        {depth, memo}

      _ ->
        {depths, memo} = Enum.map_reduce(by_name[name].after, memo, &depth(&1, by_name, &2))
        depth = if depths == [], do: 0, else: Enum.max(depths) + 1
        {depth, Map.put(memo, name, depth)}
    end
  end

  # `[from, to, label]` for each arrow. The start box is `""`, which no step
  # can be named.
  defp edges(workflow) do
    from_start = for step <- Workflow.first_steps(workflow), do: ["", step.name, nil]

    between =
      for step <- workflow.steps, from <- step.after, do: [from, step.name, step.when]

    from_start ++ between
  end

  # -- what a box shows --

  @kinds %{
    PurpleFlow.Nodes.Http => {"HTTP", "hero-globe-alt-micro"},
    PurpleFlow.Nodes.Ssh => {"SSH", "hero-command-line-micro"},
    PurpleFlow.Nodes.Postgres => {"Postgres", "hero-circle-stack-micro"},
    PurpleFlow.Nodes.Code => {"Code", "hero-code-bracket-micro"},
    PurpleFlow.Nodes.Batch => {"Batch", "hero-square-3-stack-3d-micro"},
    PurpleFlow.Nodes.Workflow => {"Workflow", "hero-rectangle-group-micro"},
    PurpleFlow.Nodes.Wait => {"Wait", "hero-clock-micro"},
    PurpleFlow.Nodes.Respond => {"Respond", "hero-arrow-uturn-left-micro"},
    PurpleFlow.Nodes.Noop => {"No-op", "hero-arrow-long-down-micro"}
  }

  defp kind(module) do
    Map.get_lazy(@kinds, module, fn ->
      {module |> Module.split() |> List.last(), "hero-cube-micro"}
    end)
  end

  # The workflow a Workflow step runs, as written.
  defp sub_workflow(%{module: PurpleFlow.Nodes.Workflow, config: %{"workflow" => name}})
       when is_binary(name),
       do: name

  defp sub_workflow(_step), do: nil

  # Where clicking a step goes: the other workflow's canvas for a Workflow
  # step that names a loaded workflow, otherwise its node file in Files.
  defp step_href(step, files?) do
    target = sub_workflow(step)

    cond do
      target && match?({:ok, _}, Workflows.fetch(target)) ->
        ~p"/workflows/#{target}/canvas"

      files? ->
        file_href(step.node_path)

      true ->
        nil
    end
  end

  # A file on the Files page, opened in its editor.
  defp file_href(path) do
    relative = Path.relative_to(path, Path.expand(Workflows.dir()))
    ~p"/files/#{Path.split(relative)}" <> "?edit"
  end

  defp triggers(workflow) do
    [
      workflow.webhook && {"hero-link-micro", "/hooks/#{workflow.webhook}"},
      workflow.cron && {"hero-clock-micro", workflow.cron}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp dom_id(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:workflows} full>
      <div class="flex items-center gap-3 border-b border-base-300 px-4 py-2.5">
        <.link
          navigate={~p"/"}
          id="canvas-back"
          class="text-sm text-base-content/60 hover:text-base-content transition"
        >
          ← Workflows
        </.link>
        <h1 class="font-semibold truncate">{@name}</h1>
        <.link
          :if={@workflow}
          navigate={~p"/workflows/#{@name}"}
          id="canvas-runs"
          class="ml-auto shrink-0 inline-flex items-center gap-1.5 rounded-md border border-base-300 px-2 py-1 text-xs text-base-content/70 transition hover:border-violet-500/50 hover:bg-violet-500/5 hover:text-violet-700 dark:hover:text-violet-300"
        >
          <.icon name="hero-queue-list-micro" class="size-4" /> Runs
        </.link>
      </div>

      <div :if={!@workflow} id="canvas-missing" class="px-4 py-16 text-center text-base-content/60">
        No workflow named “{@name}” is loaded.
      </div>

      <div
        :if={@workflow}
        id="canvas"
        phx-hook=".Canvas"
        data-edges={Jason.encode!(@edges)}
        class="relative flex-1 overflow-hidden touch-none select-none bg-base-200 cursor-grab data-[panning]:cursor-grabbing"
        style="background-image: radial-gradient(color-mix(in oklab, var(--color-base-content) 14%, transparent) 1px, transparent 1px); background-size: 20px 20px;"
      >
        <div data-world class="absolute left-0 top-0 origin-top-left">
          <svg
            id="canvas-edges"
            phx-update="ignore"
            data-edges-svg
            class="absolute left-0 top-0 overflow-visible pointer-events-none text-base-content/35"
          ></svg>
          <div class="relative flex flex-col items-center gap-14 p-8 w-max">
            <div class="flex justify-center">
              <.box
                id="canvas-start"
                node=""
                href={@files? && file_href(Path.join(@workflow.dir, "workflow.toml"))}
                kind="Start"
                icon="hero-bolt-micro"
                name={@workflow.name}
                comment={@workflow.comment}
                start
              >
                <div :if={triggers(@workflow) != []} class="flex flex-wrap gap-1.5 pt-1">
                  <span
                    :for={{icon, text} <- triggers(@workflow)}
                    class="inline-flex items-center gap-1 rounded bg-base-200 px-1.5 py-0.5 font-mono text-[11px] text-base-content/70"
                  >
                    <.icon name={icon} class="size-3" />{text}
                  </span>
                </div>
              </.box>
            </div>
            <div :for={row <- @rows} class="flex items-start justify-center gap-8">
              <.box
                :for={step <- row}
                id={"canvas-step-#{dom_id(step.name)}"}
                node={step.name}
                href={step_href(step, @files?)}
                kind={kind(step.module) |> elem(0)}
                icon={kind(step.module) |> elem(1)}
                name={step.name}
                comment={step.comment}
              >
                <span
                  :if={sub_workflow(step)}
                  class="inline-flex items-center gap-1 rounded bg-base-200 px-1.5 py-0.5 font-mono text-[11px] text-base-content/70"
                >
                  <.icon name="hero-arrow-turn-down-right-micro" class="size-3" />{sub_workflow(step)}
                </span>
              </.box>
            </div>
          </div>
        </div>

        <div
          data-controls
          class="absolute right-3 top-3 flex divide-x divide-base-300 overflow-hidden rounded-lg border border-base-300 bg-base-100/90 shadow-sm backdrop-blur"
        >
          <button
            :for={
              {action, icon, label} <- [
                {"out", "hero-minus-micro", "Zoom out"},
                {"reset", "hero-arrows-pointing-in-micro", "Reset view"},
                {"in", "hero-plus-micro", "Zoom in"}
              ]
            }
            type="button"
            id={"canvas-zoom-#{action}"}
            data-zoom={action}
            title={label}
            aria-label={label}
            class="grid size-8 place-items-center text-base-content/70 transition hover:bg-violet-500/10 hover:text-violet-700 dark:hover:text-violet-300"
          >
            <.icon name={icon} class="size-4" />
          </button>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Canvas">
        // Pans (drag with a finger, or with the right or left mouse button),
        // zooms (pinch, wheel, or the buttons), and draws the arrows between
        // the boxes the server laid out.
        const MIN = 0.1, MAX = 3, STEP = 1.25, SVG = "http://www.w3.org/2000/svg"

        export default {
          mounted() {
            this.world = this.el.querySelector("[data-world]")
            this.view = {x: 0, y: 0, scale: 1}
            this.pointers = new Map()
            this.moved = false

            this.el.addEventListener("pointerdown", e => this.down(e))
            this.el.addEventListener("pointermove", e => this.move(e))
            for (const type of ["pointerup", "pointercancel"]) {
              this.el.addEventListener(type, e => this.up(e))
            }
            this.el.addEventListener("contextmenu", e => e.preventDefault())
            this.el.addEventListener("dragstart", e => e.preventDefault())
            this.el.addEventListener("wheel", e => {
              e.preventDefault()
              const r = this.el.getBoundingClientRect()
              this.zoomAt(this.view.scale * Math.exp(-e.deltaY * 0.0015), e.clientX - r.left, e.clientY - r.top)
            }, {passive: false})
            // A drag that ends on a box isn't a click on it.
            this.el.addEventListener("click", e => {
              if (this.suppressClick) {
                e.preventDefault()
                e.stopPropagation()
                this.suppressClick = false
              }
            }, true)
            this.el.querySelectorAll("[data-zoom]").forEach(button => {
              button.addEventListener("click", () => {
                const zoom = button.dataset.zoom
                if (zoom === "reset") return this.reset()
                const r = this.el.getBoundingClientRect()
                const factor = zoom === "in" ? STEP : 1 / STEP
                this.zoomAt(this.view.scale * factor, r.width / 2, r.height / 2)
              })
            })

            // Boxes change size as fonts load, and when the workflow reloads.
            this.resize = new ResizeObserver(() => this.draw())
            this.resize.observe(this.world)
            this.draw()
            this.reset()
          },

          updated() {
            this.world = this.el.querySelector("[data-world]")
            this.resize.disconnect()
            this.resize.observe(this.world)
            this.apply()
            this.draw()
          },

          destroyed() {
            this.resize && this.resize.disconnect()
          },

          down(e) {
            if (e.target.closest("[data-controls]")) return
            this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
            if (this.pointers.size === 1) {
              this.start = {x: e.clientX, y: e.clientY}
              this.moved = false
            } else {
              this.pinch = this.pinchState()
            }
          },

          move(e) {
            const last = this.pointers.get(e.pointerId)
            if (!last) return
            const now = {x: e.clientX, y: e.clientY}
            this.pointers.set(e.pointerId, now)

            if (this.pointers.size === 1) {
              if (!this.moved && Math.hypot(now.x - this.start.x, now.y - this.start.y) < 5) return
              if (!this.moved) {
                this.moved = true
                this.el.setPointerCapture(e.pointerId)
                this.el.dataset.panning = ""
              }
              this.view.x += now.x - last.x
              this.view.y += now.y - last.y
              this.apply()
            } else if (this.pinch) {
              this.moved = true
              const {mid, dist} = this.pinchState()
              const p = this.pinch
              const scale = clamp(p.scale * dist / p.dist)
              // Keep the point that was under the fingers under them.
              const wx = (p.mid.x - p.x) / p.scale, wy = (p.mid.y - p.y) / p.scale
              this.view = {scale, x: mid.x - wx * scale, y: mid.y - wy * scale}
              this.apply()
            }
          },

          up(e) {
            if (!this.pointers.delete(e.pointerId)) return
            if (this.pointers.size === 1) this.pinch = null
            if (this.pointers.size >= 2) this.pinch = this.pinchState()
            if (this.pointers.size === 0) {
              delete this.el.dataset.panning
              if (this.moved) this.suppressClick = true
              // Only a click that follows this pointerup can be the drag's.
              setTimeout(() => this.suppressClick = false, 0)
            }
          },

          pinchState() {
            const r = this.el.getBoundingClientRect()
            const [a, b] = [...this.pointers.values()]
            return {
              mid: {x: (a.x + b.x) / 2 - r.left, y: (a.y + b.y) / 2 - r.top},
              dist: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)),
              x: this.view.x, y: this.view.y, scale: this.view.scale,
            }
          },

          zoomAt(scale, px, py) {
            scale = clamp(scale)
            const {x, y, scale: old} = this.view
            this.view = {scale, x: px - (px - x) * scale / old, y: py - (py - y) * scale / old}
            this.apply()
          },

          // The whole width fits (never bigger than actual size), top first,
          // clear of the zoom buttons.
          reset() {
            const width = this.world.offsetWidth
            const box = this.el.getBoundingClientRect()
            const scale = clamp(Math.min(1, box.width / Math.max(width, 1)))
            this.view = {scale, x: (box.width - width * scale) / 2, y: 16}
            this.apply()
          },

          apply() {
            const {x, y, scale} = this.view
            this.world.style.transform = `translate(${x}px, ${y}px) scale(${scale})`
            this.el.style.backgroundPosition = `${x}px ${y}px`
            this.el.style.backgroundSize = `${20 * scale}px ${20 * scale}px`
          },

          // One arrow per edge, bottom middle of a box to top middle of the next.
          draw() {
            const svg = this.el.querySelector("[data-edges-svg]")
            const edges = JSON.parse(this.el.dataset.edges || "[]")
            const origin = this.world.getBoundingClientRect()
            const scale = this.view.scale
            const box = name => {
              const node = this.world.querySelector(`[data-node="${CSS.escape(name)}"]`)
              if (!node) return null
              const r = node.getBoundingClientRect()
              return {
                x: (r.left - origin.left) / scale, y: (r.top - origin.top) / scale,
                w: r.width / scale, h: r.height / scale,
              }
            }

            svg.setAttribute("width", this.world.offsetWidth)
            svg.setAttribute("height", this.world.offsetHeight)
            svg.replaceChildren()
            const defs = el("defs")
            const marker = el("marker", {
              id: "canvas-arrow", viewBox: "0 0 10 10", refX: 9, refY: 5,
              markerWidth: 7, markerHeight: 7, orient: "auto-start-reverse",
            })
            marker.appendChild(el("path", {d: "M 0 0 L 10 5 L 0 10 z", fill: "currentColor"}))
            defs.appendChild(marker)
            svg.appendChild(defs)

            for (const [from, to, label] of edges) {
              const a = box(from), b = box(to)
              if (!a || !b) continue
              const x1 = a.x + a.w / 2, y1 = a.y + a.h
              const x2 = b.x + b.w / 2, y2 = b.y - 1
              const bend = Math.max(24, (y2 - y1) / 2)
              svg.appendChild(el("path", {
                d: `M ${x1} ${y1} C ${x1} ${y1 + bend}, ${x2} ${y2 - bend}, ${x2} ${y2}`,
                fill: "none", stroke: "currentColor", "stroke-width": 1.5,
                "marker-end": "url(#canvas-arrow)",
              }))
              if (label) {
                const text = el("text", {
                  x: (x1 + x2) / 2, y: (y1 + y2) / 2, "text-anchor": "middle",
                  "dominant-baseline": "central", "font-size": 11,
                  class: "fill-violet-700 dark:fill-violet-300 font-mono",
                })
                text.textContent = label
                svg.appendChild(text)
                const t = text.getBBox()
                const pill = el("rect", {
                  x: t.x - 6, y: t.y - 2, width: t.width + 12, height: t.height + 4, rx: 8,
                  class: "fill-base-100 stroke-violet-500/40",
                })
                svg.insertBefore(pill, text)
              }
            }
          },
        }

        function clamp(scale) { return Math.min(MAX, Math.max(MIN, scale)) }

        function el(tag, attrs = {}) {
          const node = document.createElementNS(SVG, tag)
          for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v)
          return node
        }
      </script>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :node, :string, required: true, doc: "what the hook's edges call this box"
  attr :href, :any, default: nil
  attr :kind, :string, required: true
  attr :icon, :string, required: true
  attr :name, :string, required: true
  attr :comment, :string, default: nil
  attr :start, :boolean, default: false
  slot :inner_block

  defp box(assigns) do
    assigns =
      assign(assigns, :class, [
        "block w-64 overflow-hidden rounded-lg border bg-base-100 text-left shadow-sm transition",
        if(assigns.start, do: "border-violet-500/60", else: "border-base-300"),
        assigns.href && "hover:border-violet-500/70 hover:shadow-md hover:shadow-violet-500/10"
      ])

    ~H"""
    <.link
      :if={@href}
      navigate={@href}
      id={@id}
      data-node={@node}
      draggable="false"
      class={@class}
    >
      <.box_body {assigns} />
    </.link>
    <div :if={!@href} id={@id} data-node={@node} class={@class}>
      <.box_body {assigns} />
    </div>
    """
  end

  defp box_body(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-1.5 border-b px-3 py-1.5 text-xs font-medium",
      if(@start,
        do: "border-violet-500/30 bg-violet-600 text-white",
        else: "border-base-300 bg-violet-500/10 text-violet-700 dark:text-violet-300"
      )
    ]}>
      <.icon name={@icon} class="size-4" />
      <span data-kind>{@kind}</span>
    </div>
    <div class="space-y-1 px-3 py-2">
      <p class="font-semibold text-sm break-words">{@name}</p>
      <p
        :if={@comment}
        data-comment
        class="whitespace-pre-line break-words text-xs text-base-content/65"
        phx-no-format
      >{@comment}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
