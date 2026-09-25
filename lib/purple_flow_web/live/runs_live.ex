defmodule PurpleFlowWeb.RunsLive do
  @moduledoc "One workflow's runs, newest first. New runs show up live."

  use PurpleFlowWeb, :live_view

  import PurpleFlowWeb.Live.Helpers

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(PurpleFlow.PubSub, "runs")

    {:ok, socket |> assign(:name, name) |> assign(:page_title, name) |> load()}
  end

  @impl true
  def handle_info(_run_message, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, :runs, PurpleFlow.Runs.list(socket.assigns.name))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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
        <.link
          :for={run <- @runs}
          id={"run-#{run.id}"}
          navigate={~p"/runs/#{run.id}"}
          class="flex items-center gap-4 px-4 py-2.5 text-sm hover:bg-base-200 transition"
        >
          <.status_badge status={run.status} />
          <span class="font-mono text-xs text-base-content/60">{run.id}</span>
          <span class="ml-auto text-base-content/70">{run.trigger}</span>
          <span class="w-40 text-right">{timestamp(run.started_at)}</span>
          <span class="w-16 text-right text-base-content/60">{duration(
            run.started_at,
            run.finished_at
          )}</span>
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
