defmodule PurpleFlowWeb.WorkflowsLive do
  @moduledoc """
  Home page: every loaded workflow, its triggers, its last run, and a Run
  button with a JSON box for the request body. A manual run's input has the
  same shape as a webhook's: `%{"body" => ..., "query" => %{}, "headers" => %{}}`. Also lists workflows that failed to load,
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
     |> assign(:search, "")
     |> assign(:files?, Application.get_env(:purple_flow, :files_url) != nil)
     |> load()}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, socket |> assign(:search, query) |> load()}
  end

  def handle_event("run", %{"workflow" => name, "input" => text}, socket) do
    with {:ok, body} <- decode(text),
         {:ok, run_id} <- PurpleFlow.run(name, manual_input(body), trigger: "manual") do
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
    |> assign(:any_workflows?, loaded != [])
    |> assign(
      :workflows,
      loaded
      |> Enum.filter(&matches?(&1, socket.assigns.search))
      |> Enum.sort_by(& &1.workflow.name)
    )
    |> assign(:not_loaded, not_loaded)
    |> assign(:statuses, Runs.last_statuses())
  end

  # By name, folder, webhook path, or cron schedule, ignoring case.
  defp matches?(_entry, ""), do: true

  defp matches?(%{workflow: wf, folder: folder}, query) do
    query = String.downcase(String.trim(query))

    [wf.name, folder, wf.webhook, wf.cron]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), query))
  end

  # Shaped like a webhook's input, so a workflow reads input["body"] either way.
  defp manual_input(body), do: %{"body" => body, "query" => %{}, "headers" => %{}}

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
    <Layouts.app flash={@flash} active={:workflows}>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-xl font-semibold">Workflows</h1>
        <div :if={@any_workflows?} class="relative w-full sm:w-72">
          <.icon
            name="hero-magnifying-glass-micro"
            class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-base-content/40 pointer-events-none"
          />
          <input
            type="search"
            name="q"
            id="workflows-search"
            value={@search}
            placeholder="Search workflows"
            autocomplete="off"
            phx-keyup="search"
            phx-debounce="150"
            class="w-full rounded-md border border-base-300 bg-base-100 pl-8 pr-3 py-1.5 text-sm outline-none transition focus:border-violet-500 focus:ring-4 focus:ring-violet-500/15"
          />
        </div>
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

      <p :if={@any_workflows? and @workflows == []} id="no-matches" class="text-base-content/60">
        No workflows match “{@search}”.
      </p>

      <p :if={!@any_workflows?} class="text-base-content/60">
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
            <div class="flex items-center gap-2">
              <.status_badge :if={@statuses[wf.name]} status={@statuses[wf.name]} />
              <.link
                :if={@files?}
                navigate={~p"/files/#{entry.folder}" <> "/"}
                id={"files-#{wf.name}"}
                title="Open this workflow's files"
                class="inline-flex items-center gap-1.5 rounded-md border border-base-300 px-2 py-1 text-xs text-base-content/70 transition hover:border-violet-500/50 hover:bg-violet-500/5 hover:text-violet-700 dark:hover:text-violet-300"
              >
                <.icon name="hero-folder-open-micro" class="size-4" /> Files
              </.link>
            </div>
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
              aria-label="Request body (JSON)"
              title={
                ~s(The request body, as JSON. Steps get it as input["body"], the same as from a webhook.)
              }
              class="flex-1 font-mono text-sm rounded-md border border-base-300 bg-base-100 px-2 py-1.5 outline-none transition focus:border-violet-500 focus:ring-4 focus:ring-violet-500/15"
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
