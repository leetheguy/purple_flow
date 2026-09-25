defmodule PurpleFlowWeb.RunLive do
  @moduledoc """
  One run, step by step, like n8n's execution view.

  One row per step, in workflow order. Click a row to see its input and
  output. A step that ran per item expands into one row per item. Colors:
  green ok, red failed, blue running, gray didn't run.

  While the run is going, rows update live from the run's broadcasts.
  """

  use PurpleFlowWeb, :live_view

  import PurpleFlowWeb.Live.Helpers

  alias PurpleFlow.{Runs, Workflow, Workflows}

  # Many items can finish at once; refresh at most this often.
  @refresh_ms 200

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
         |> assign(:running, %{})
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

  @impl true
  def handle_info({:step_started, _, step, _item}, socket) do
    {:noreply, update(socket, :running, &Map.update(&1, step, 1, fn n -> n + 1 end))}
  end

  def handle_info({:step_finished, _, step, _item, _result}, socket) do
    socket = update(socket, :running, &Map.update(&1, step, 0, fn n -> max(n - 1, 0) end))
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:run_finished, _, _}, socket), do: {:noreply, schedule_refresh(socket)}

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

  defp step_status(rows, running) do
    cond do
      Enum.any?(rows, &(&1.status != "ok")) -> "failed"
      running > 0 -> "running"
      rows != [] -> "ok"
      true -> "didn't run"
    end
  end

  defp per_item?(rows), do: Enum.any?(rows, &(&1.item != nil))

  defp summary(rows) do
    ok = Enum.count(rows, &(&1.status == "ok"))
    failed = length(rows) - ok
    if failed > 0, do: "×#{length(rows)} — #{ok} ok, #{failed} failed", else: "×#{length(rows)}"
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
    <Layouts.app flash={@flash}>
      <p id="not-found">Run not found.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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

      <div id="steps" class="rounded-lg border border-base-300 divide-y divide-base-300">
        <.data_block
          key="trigger-input"
          label="trigger input"
          value={@run.input}
          expanded={@expanded}
        />

        <div :for={name <- @step_names} id={"step-#{name}"}>
          <% rows = Map.get(@rows_by_step, name, []) %>
          <% status = step_status(rows, Map.get(@running, name, 0)) %>
          <button
            phx-click="toggle"
            phx-value-key={"step:" <> name}
            disabled={rows == []}
            class="w-full flex items-center gap-3 px-4 py-2.5 text-left text-sm hover:bg-base-200 disabled:hover:bg-transparent transition"
          >
            <span class={["size-2.5 rounded-full shrink-0", dot_class(status)]}></span>
            <span class={["font-medium", status == "didn't run" && "text-base-content/40"]}>{name}</span>
            <span :if={per_item?(rows)} class="text-base-content/60">{summary(rows)}</span>
            <span class="text-xs text-base-content/40">{after_text(@workflow, name)}</span>
            <span class="ml-auto text-xs text-base-content/60">{step_duration(rows)}</span>
          </button>

          <div :if={("step:" <> name) in @expanded} class="px-4 pb-3">
            <%= if per_item?(rows) do %>
              <div class="border-l-2 border-base-300 ml-1 pl-3 divide-y divide-base-300/60">
                <div :for={row <- Enum.sort_by(rows, & &1.item)} id={"step-#{name}-item-#{row.item}"}>
                  <button
                    phx-click="toggle"
                    phx-value-key={"item:#{name}:#{row.item}"}
                    class="w-full flex items-center gap-3 py-1.5 text-left text-sm hover:bg-base-200 transition"
                  >
                    <span class={["size-2 rounded-full", dot_class(row.status)]}></span>
                    <span>item {row.item}</span>
                    <span :if={row.from_item != nil} class="text-xs text-base-content/40">from item {row.from_item}</span>
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
  defp dot_class("running"), do: "bg-sky-500 animate-pulse"
  defp dot_class(_), do: "bg-base-300"
end
