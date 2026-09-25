defmodule PurpleFlowWeb.WorkflowsLive do
  @moduledoc """
  Home page: every loaded workflow, its triggers, its last run, and a Run
  button with a JSON input box. Also lists workflows that failed to load.
  """

  use PurpleFlowWeb, :live_view

  import PurpleFlowWeb.Live.Helpers

  alias PurpleFlow.{Runs, Workflows}

  @impl true
  def mount(_params, _session, socket) do
    # Refresh "last run" statuses whenever any run starts or finishes.
    if connected?(socket), do: Phoenix.PubSub.subscribe(PurpleFlow.PubSub, "runs")

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

  def handle_event("reload", _params, socket) do
    Workflows.reload()
    {:noreply, socket |> load() |> put_flash(:info, "Workflows reloaded")}
  end

  @impl true
  def handle_info(_run_message, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    socket
    |> assign(:workflows, Workflows.list())
    |> assign(:errors, Workflows.errors())
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
        <button
          id="reload-button"
          phx-click="reload"
          class="text-sm px-3 py-1.5 rounded-md border border-base-300 hover:bg-base-200 transition"
        >
          <.icon name="hero-arrow-path-micro" class="size-4" /> Reload
        </button>
      </div>

      <div
        :if={@errors != []}
        id="load-errors"
        class="rounded-lg border border-red-500/40 bg-red-500/5 p-4 space-y-2"
      >
        <p class="font-medium text-red-600 dark:text-red-400">Some workflows didn't load</p>
        <div :for={{path, problems} <- @errors} class="text-sm">
          <p class="font-mono">{Path.relative_to_cwd(path)}</p>
          <ul class="list-disc ml-5 text-base-content/70">
            <li :for={problem <- problems}>{problem}</li>
          </ul>
        </div>
      </div>

      <p :if={@workflows == []} class="text-base-content/60">
        No workflows yet. Add one under <code>{Workflows.dir()}/</code> and hit Reload.
      </p>

      <div id="workflows" class="grid gap-4">
        <div
          :for={wf <- @workflows}
          id={"workflow-#{wf.name}"}
          class="rounded-lg border border-base-300 p-4 space-y-3"
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
end
