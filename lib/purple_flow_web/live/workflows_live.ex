defmodule PurpleFlowWeb.WorkflowsLive do
  @moduledoc """
  Home page: every loaded workflow, its triggers, its last run, and a Run
  button with a JSON input box. Also lists workflows that failed to load,
  and flags ones whose latest edit failed and are still running an older
  version. Workflows reload on their own (`PurpleFlow.Workflows`), and the
  page follows.
  """

  use PurpleFlowWeb, :live_view

  import PurpleFlowWeb.Live.Helpers

  alias PurpleFlow.{Runs, Workflows}

  @impl true
  def mount(_params, _session, socket) do
    # Refresh when any run starts or finishes, and when workflows reload.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PurpleFlow.PubSub, "runs")
      Phoenix.PubSub.subscribe(PurpleFlow.PubSub, Workflows.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Workflows")
     |> assign(:run_form, to_form(%{"input" => "{}"}))
     |> load()}
  end

  @impl true
  def handle_event("run", %{"workflow" => name, "input" => text}, socket) do
    with {:ok, input} <- decode(text),
         {:ok, run_id} <- PurpleFlow.run(name, input, trigger: "manual") do
      {:noreply, push_navigate(socket, to: ~p"/runs/#{run_id}")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info(_run_or_reload, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    %{folders: folders} = Workflows.status()
    {loaded, not_loaded} = Enum.split_with(folders, & &1.workflow)

    socket
    |> assign(:workflows, Enum.sort_by(loaded, & &1.workflow.name))
    |> assign(:not_loaded, not_loaded)
    |> assign(:statuses, Runs.last_statuses())
  end

  defp decode(""), do: {:ok, %{}}

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, "Input isn't valid JSON"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold">Workflows</h1>
        <p class="text-xs text-base-content/50">Edits to workflow files load on their own.</p>
      </div>

      <div
        :if={@not_loaded != []}
        id="load-errors"
        class="rounded-lg border border-red-500/40 bg-red-500/5 p-4 space-y-2"
      >
        <p class="font-medium text-red-600 dark:text-red-400">Some workflows didn't load</p>
        <div :for={entry <- @not_loaded} id={"load-error-#{entry.folder}"} class="text-sm">
          <p class="font-mono">{Path.relative_to_cwd(entry.path)}</p>
          <.problems problems={entry.problems} />
        </div>
      </div>

      <p :if={@workflows == []} class="text-base-content/60">
        No workflows yet. Add one under <code>{Workflows.dir()}/</code>; it loads within a couple of seconds.
      </p>

      <div id="workflows" class="grid gap-4">
        <div
          :for={%{workflow: wf} = entry <- @workflows}
          id={"workflow-#{wf.name}"}
          class={[
            "rounded-lg border p-4 space-y-3 transition-colors",
            if(entry.stale?, do: "border-amber-500/50", else: "border-base-300")
          ]}
        >
          <div class="flex items-start justify-between gap-4">
            <div class="space-y-1">
              <.link navigate={~p"/workflows/#{wf.name}"} class="font-semibold hover:underline">{wf.name}</.link>
              <p class="text-xs text-base-content/60 space-x-3">
                <span>{length(wf.steps)} steps</span>
                <span :if={wf.webhook}>webhook <code>/hooks/{wf.webhook}</code></span>
                <span :if={wf.cron}>cron <code>{wf.cron}</code></span>
              </p>
            </div>
            <.status_badge :if={@statuses[wf.name]} status={@statuses[wf.name]} />
          </div>

          <div
            :if={entry.stale?}
            id={"stale-#{wf.name}"}
            class="rounded-md bg-amber-500/10 px-3 py-2 text-sm"
          >
            <p class="font-medium text-amber-700 dark:text-amber-400">
              <.icon name="hero-exclamation-triangle-micro" class="size-4" />
              The latest edit didn't load. Still running the version from {timestamp(entry.loaded_at)}.
            </p>
            <.problems problems={entry.problems} />
          </div>

          <.form
            for={@run_form}
            id={"run-form-#{wf.name}"}
            phx-submit="run"
            class="flex gap-2 items-start"
          >
            <input type="hidden" name="workflow" value={wf.name} />
            <textarea
              name="input"
              id={"run-input-#{wf.name}"}
              rows="1"
              class="flex-1 font-mono text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5"
            >{@run_form[:input].value}</textarea>
            <button
              type="submit"
              class="px-3 py-1.5 rounded-md bg-violet-600 text-white text-sm hover:bg-violet-500 transition"
            >
              Run
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :problems, :list, required: true

  defp problems(assigns) do
    ~H"""
    <ul class="list-disc ml-5 text-base-content/70">
      <li :for={problem <- @problems}>{problem}</li>
    </ul>
    """
  end
end
