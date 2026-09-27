defmodule PurpleFlowWeb.RunsLive do
  @moduledoc """
  One workflow's runs, newest first. Runs show up and finish live, and a
  running one has a Kill button (see `specs/160_live_runs.md`).
  """

  use PurpleFlowWeb, :live_view

  import PurpleFlowWeb.Live.Helpers

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(PurpleFlow.PubSub, "runs")

    {:ok, socket |> assign(:name, name) |> assign(:page_title, name) |> load()}
  end

  @impl true
  def handle_event("kill", %{"id" => id}, socket) do
    socket =
      case PurpleFlow.kill(id) do
        :ok -> socket
        {:error, message} -> put_flash(socket, :error, message)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_run_message, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, :runs, PurpleFlow.Runs.list(socket.assigns.name))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:workflows}>
      <div>
        <.link navigate={~p"/"} class="text-sm text-base-content/60 hover:underline">← Workflows</.link>
        <h1 class="text-xl font-semibold">{@name}</h1>
      </div>

      <p :if={@runs == []} class="text-base-content/60">No runs yet.</p>

      <div
        :if={@runs != []}
        id="runs"
        class="rounded-lg border border-base-300 divide-y divide-base-300"
      >
        <div
          :for={run <- @runs}
          id={"run-#{run.id}"}
          class="flex items-center hover:bg-base-200 transition"
        >
          <.link
            navigate={~p"/runs/#{run.id}"}
            class="flex flex-1 min-w-0 items-center gap-4 px-4 py-2.5 text-sm"
          >
            <.status_badge status={run.status} />
            <span class="font-mono text-xs text-base-content/60 truncate">{run.id}</span>
            <span class="ml-auto text-base-content/70">{run.trigger}</span>
            <span class="w-40 text-right">{timestamp(run.started_at)}</span>
            <span class="w-16 text-right text-base-content/60">{duration(
              run.started_at,
              run.finished_at
            )}</span>
          </.link>
          <div class="w-20 pr-3 text-right">
            <button
              :if={run.status == "running"}
              id={"kill-#{run.id}"}
              phx-click="kill"
              phx-value-id={run.id}
              data-confirm="Kill this run? Running steps are stopped now."
              class="rounded-lg border border-red-500/40 px-2.5 py-0.5 text-xs font-medium text-red-600 hover:bg-red-500/10 active:scale-95 transition dark:text-red-400"
            >
              Kill
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
