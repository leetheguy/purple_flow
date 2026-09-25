defmodule PurpleFlow.Application do
  @moduledoc false
  # Starts everything, in order. Order matters: nothing should accept a
  # trigger until everything a run needs is already up.

  use Application

  @impl true
  def start(_type, _args) do
    PurpleFlow.Env.load()

    children =
      [
        PurpleFlowWeb.Telemetry,
        PurpleFlow.Repo,
        mark_interrupted_runs(),
        {DNSCluster, query: Application.get_env(:purple_flow, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PurpleFlow.PubSub},
        # Connection pools for the Postgres node, one per database URL.
        {Registry, keys: :unique, name: PurpleFlow.Nodes.Postgres.Pools},
        {DynamicSupervisor, name: PurpleFlow.Nodes.Postgres.PoolSupervisor},
        # Every node execution runs as a task under here.
        {Task.Supervisor, name: PurpleFlow.StepSupervisor},
        # One PurpleFlow.Run per run.
        {DynamicSupervisor, name: PurpleFlow.RunSupervisor},
        PurpleFlow.Scheduler,
        PurpleFlow.Workflows,
        # UI + webhooks, last.
        PurpleFlowWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: PurpleFlow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # At boot, runs left `running` by a stopped app are marked `interrupted`.
  # Skipped in tests, where the database is sandboxed per test.
  defp mark_interrupted_runs do
    if Application.get_env(:purple_flow, :mark_interrupted_on_boot, true) do
      Supervisor.child_spec({Task, &PurpleFlow.Runs.mark_interrupted/0},
        id: :mark_interrupted_runs
      )
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    PurpleFlowWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
