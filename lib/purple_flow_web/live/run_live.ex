defmodule PurpleFlowWeb.RunLive do
  @moduledoc """
  One run, step by step, like n8n's execution view.

  One row per step, in workflow order, showing ok / total executions and,
  while the run is going, what's queued and running. Click a row to see its
  input and output; a step that ran more than once expands into one row
  per execution. Dots: green all ok, yellow some not, red none ok (or it
  ended the run), blue busy, gray didn't run. See `specs/160_live_runs.md`.

  While the run is going, it updates from the run's `run_progress`
  messages, and a Kill button stops it.
  """

  use PurpleFlowWeb, :live_view

  import PurpleFlowWeb.Live.Helpers

  alias PurpleFlow.{Runs, Workflow, Workflows}

  # Reload rows from the database at most this often.
  @refresh_ms 250

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Runs.get(id) do
      nil ->
        {:ok, socket |> assign(:run, nil) |> assign(:page_title, "Run not found")}

      %{run: run} = data ->
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(PurpleFlow.PubSub, PurpleFlow.topic(run.id))

        workflow =
          case Workflows.fetch(run.workflow) do
            {:ok, workflow} -> workflow
            {:error, _} -> nil
          end

        {:ok,
         socket
         |> assign(:page_title, run.workflow)
         |> assign(:workflow, workflow)
         |> assign(:progress, %{})
         |> assign(:expanded, MapSet.new())
         |> assign(:refresh_scheduled, false)
         |> assign_data(data)}
    end
  end

  @impl true
  def handle_event("toggle", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if key in expanded, do: MapSet.delete(expanded, key), else: MapSet.put(expanded, key)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("kill", _params, socket) do
    socket =
      case PurpleFlow.kill(socket.assigns.run.id) do
        :ok -> socket
        {:error, message} -> put_flash(socket, :error, message)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_progress, _, progress}, socket) do
    socket = assign(socket, :progress, progress)
    names = socket.assigns.step_names
    names = names ++ (progress |> Map.keys() |> Enum.sort() |> Kernel.--(names))
    {:noreply, socket |> assign(:step_names, names) |> schedule_refresh()}
  end

  # The final state shows right away: it's one message, never a flood.
  def handle_info({:run_finished, _, _}, socket) do
    socket = assign(socket, :progress, %{})
    {:noreply, assign_data(socket, Runs.get(socket.assigns.run.id))}
  end

  def handle_info(:refresh, socket) do
    socket = assign(socket, :refresh_scheduled, false)
    {:noreply, assign_data(socket, Runs.get(socket.assigns.run.id))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_refresh(%{assigns: %{refresh_scheduled: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    assign(socket, :refresh_scheduled, true)
  end

  defp assign_data(socket, %{run: run, steps: rows}) do
    socket
    |> assign(:run, run)
    |> assign(:rows_by_step, Enum.group_by(rows, & &1.step))
    |> assign(:step_names, step_names(socket.assigns.workflow, rows))
  end

  # Workflow order, plus any saved steps the (possibly edited) workflow no longer has.
  defp step_names(workflow, rows) do
    listed = if workflow, do: Enum.map(workflow.steps, & &1.name), else: []
    listed ++ (rows |> Enum.map(& &1.step) |> Enum.uniq() |> Kernel.--(listed))
  end

  # -- per-step summary --

  # Executions that succeeded, didn't, and items that overflowed its queue.
  defp tally(rows) do
    Enum.reduce(rows, %{ok: 0, failed: 0, overflow: 0}, fn row, tally ->
      key =
        case row.status do
          "ok" -> :ok
          "overflow" -> :overflow
          _ -> :failed
        end

      Map.update!(tally, key, &(&1 + 1))
    end)
  end

  defp step_status(name, rows, progress, run) do
    %{ok: ok, failed: failed, overflow: overflow} = tally(rows)
    busy = progress[name] && progress[name].queued + progress[name].running > 0

    cond do
      busy -> "running"
      rows == [] -> "didn't run"
      ok == 0 or (run.error && run.error["step"] == name) -> "failed"
      failed > 0 or overflow > 0 -> "partial"
      true -> "ok"
    end
  end

  defp multiple?(rows), do: length(rows) > 1

  attr :name, :string, required: true
  attr :rows, :list, required: true
  attr :progress, :any, required: true

  defp counters(assigns) do
    assigns = assign(assigns, :tally, tally(assigns.rows))

    ~H"""
    <span
      :if={@rows != []}
      id={"step-#{@name}-counts"}
      class="text-base-content/70 tabular-nums"
      title="succeeded / executions"
    >
      {@tally.ok}/{@tally.ok + @tally.failed}
    </span>
    <span :if={@tally.overflow > 0} class="text-xs text-amber-600 dark:text-amber-400">
      {@tally.overflow} overflowed
    </span>
    <span :if={@progress} id={"step-#{@name}-live"} class="text-xs text-base-content/60 tabular-nums">
      queue {@progress.queued} · running {@progress.running}/{@progress.concurrency}
    </span>
    """
  end

  defp step_duration([]), do: nil

  defp step_duration(rows) do
    duration(
      rows |> Enum.map(& &1.started_at) |> Enum.min(DateTime),
      rows |> Enum.map(& &1.finished_at) |> Enum.max(DateTime)
    )
  end

  defp after_text(nil, _name), do: nil

  defp after_text(workflow, name) do
    case Workflow.step(workflow, name) do
      %{after: [], when: nil} -> nil
      %{after: after_, when: nil} -> "after " <> Enum.join(after_, ", ")
      %{after: after_, when: route} -> "after #{Enum.join(after_, ", ")} when #{route}"
      nil -> nil
    end
  end

  @impl true
  def render(%{run: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:workflows}>
      <p id="not-found">Run not found.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:workflows}>
      <div class="space-y-1">
        <.link
          navigate={~p"/workflows/#{@run.workflow}"}
          class="text-sm text-base-content/60 hover:underline"
        >
          ← {@run.workflow}
        </.link>
        <div class="flex items-center gap-3">
          <h1 class="text-xl font-semibold">Run</h1>
          <.status_badge id="run-status" status={@run.status} />
          <button
            :if={@run.status == "running"}
            id="kill-run"
            phx-click="kill"
            data-confirm="Kill this run? Running steps are stopped now."
            class="ml-auto rounded-lg border border-red-500/40 px-3 py-1 text-sm font-medium text-red-600 hover:bg-red-500/10 active:scale-95 transition dark:text-red-400"
          >
            Kill
          </button>
        </div>
        <p class="text-xs text-base-content/60 space-x-3">
          <span class="font-mono">{@run.id}</span>
          <span>{@run.trigger}</span>
          <span>{timestamp(@run.started_at)}</span>
          <span :if={@run.finished_at}>{duration(@run.started_at, @run.finished_at)}</span>
        </p>
      </div>

      <div
        :if={@run.error}
        id="run-error"
        class="rounded-lg border border-red-500/40 bg-red-500/5 p-3 text-sm"
      >
        <span class="font-medium">Failed at {@run.error["step"]}<span :if={@run.error["item"]}> item {@run.error["item"]}</span>:</span>
        {@run.error["message"]}
      </div>

      <p
        :if={@run.status == "killed"}
        id="run-killed"
        class="rounded-lg border border-base-300 bg-base-200/60 p-3 text-sm text-base-content/70"
      >
        Killed. Steps that were running are marked killed.
      </p>

      <div id="steps" class="rounded-lg border border-base-300 divide-y divide-base-300">
        <.data_block
          key="trigger-input"
          label="trigger input"
          value={@run.input}
          expanded={@expanded}
        />

        <div :for={name <- @step_names} id={"step-#{name}"}>
          <% rows = Map.get(@rows_by_step, name, []) %>
          <% status = step_status(name, rows, @progress, @run) %>
          <button
            phx-click="toggle"
            phx-value-key={"step:" <> name}
            disabled={rows == []}
            class="w-full flex items-center gap-3 px-4 py-2.5 text-left text-sm hover:bg-base-200 disabled:hover:bg-transparent transition"
          >
            <span
              id={"step-#{name}-dot"}
              data-status={status}
              class={["size-2.5 rounded-full shrink-0", dot_class(status)]}
            ></span>
            <span class={["font-medium", status == "didn't run" && "text-base-content/40"]}>{name}</span>
            <.counters name={name} rows={rows} progress={@progress[name]} />
            <span class="text-xs text-base-content/40">{after_text(@workflow, name)}</span>
            <span class="ml-auto text-xs text-base-content/60">{step_duration(rows)}</span>
          </button>

          <div :if={("step:" <> name) in @expanded} class="px-4 pb-3">
            <%= if multiple?(rows) do %>
              <div class="border-l-2 border-base-300 ml-1 pl-3 divide-y divide-base-300/60">
                <div :for={row <- Enum.sort_by(rows, & &1.item)} id={"step-#{name}-item-#{row.item}"}>
                  <button
                    phx-click="toggle"
                    phx-value-key={"item:#{name}:#{row.item}"}
                    class="w-full flex items-center gap-3 py-1.5 text-left text-sm hover:bg-base-200 transition"
                  >
                    <span class={["size-2 rounded-full", dot_class(row.status)]}></span>
                    <span>{if row.status == "overflow", do: "overflowed", else: "##{row.item}"}</span>
                    <span :if={row.from_item != nil} class="text-xs text-base-content/40">from #{row.from_item}</span>
                    <span :if={row.route} class="text-xs text-base-content/60">→ {row.route}</span>
                    <span class="ml-auto text-xs text-base-content/60">{duration(
                      row.started_at,
                      row.finished_at
                    )}</span>
                  </button>
                  <.row_detail :if={"item:#{name}:#{row.item}" in @expanded} row={row} />
                </div>
              </div>
            <% else %>
              <.row_detail :for={row <- rows} row={row} />
            <% end %>
          </div>
        </div>

        <.data_block
          :if={@run.output != nil}
          key="run-output"
          label="run output"
          value={@run.output}
          expanded={@expanded}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :expanded, :any, required: true

  defp data_block(assigns) do
    ~H"""
    <div id={@key}>
      <button
        phx-click="toggle"
        phx-value-key={@key}
        class="w-full flex items-center gap-3 px-4 py-2.5 text-left text-sm text-base-content/60 hover:bg-base-200 transition"
      >
        <.icon name="hero-code-bracket-micro" class="size-4" /> {@label}
      </button>
      <pre
        :if={@key in @expanded}
        class="mx-4 mb-3 p-3 rounded-md bg-base-200 text-xs overflow-x-auto"
      >{pretty(@value)}</pre>
    </div>
    """
  end

  attr :row, :any, required: true

  defp row_detail(assigns) do
    ~H"""
    <div class="grid gap-2 md:grid-cols-2 py-2 text-xs">
      <div>
        <p class="mb-1 text-base-content/60">input</p>
        <pre class="p-3 rounded-md bg-base-200 overflow-x-auto max-h-96">{pretty(@row.input)}</pre>
      </div>
      <div>
        <p class="mb-1 text-base-content/60">
          {if @row.status == "ok", do: "output", else: "error"}<span :if={@row.route}> (route: {@row.route})</span>
        </p>
        <pre class={[
          "p-3 rounded-md overflow-x-auto max-h-96",
          if(@row.status == "ok",
            do: "bg-base-200",
            else: "bg-red-500/10 text-red-700 dark:text-red-300"
          )
        ]}>{if @row.status == "ok", do: pretty(@row.output), else: @row.error["message"]}</pre>
      </div>
    </div>
    """
  end

  defp dot_class(status) when status in ["ok", "complete"], do: "bg-emerald-500"
  defp dot_class(status) when status in ["failed", "error", "timed_out"], do: "bg-red-500"
  defp dot_class(status) when status in ["partial", "overflow"], do: "bg-amber-500"
  defp dot_class("running"), do: "bg-sky-500 animate-pulse"
  defp dot_class(_), do: "bg-base-300"
end
