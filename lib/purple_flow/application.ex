defmodule PurpleFlow.Application do
  @moduledoc false
  # Starts everything, in order. Order matters: nothing should accept a
  # trigger until everything a run needs is already up.
  #
  # The same release also runs as the Code node runner (PURPLEFLOW_ROLE=runner,
  # see specs/100_runner_container.md), which starts nothing but the runner.

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:purple_flow, :role, :app) do
        :runner -> runner_children()
        :app -> app_children()
      end

    opts = [strategy: :one_for_one, name: PurpleFlow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp runner_children do
    [
      {Task.Supervisor, name: PurpleFlow.Runner.Connections},
      {PurpleFlow.Runner.Server,
       ip: {0, 0, 0, 0}, port: Application.fetch_env!(:purple_flow, :runner_port)}
    ]
  end

  defp app_children do
    [
      PurpleFlowWeb.Telemetry,
      PurpleFlow.Repo,
      mark_interrupted_runs(),
      {DNSCluster, query: Application.get_env(:purple_flow, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PurpleFlow.PubSub},
      # Connection pools for the Postgres node, one per database URL.
      {Registry, keys: :unique, name: PurpleFlow.Nodes.Postgres.Pools},
      {DynamicSupervisor, name: PurpleFlow.Nodes.Postgres.PoolSupervisor},
      in_vm_runner(),
      # Every node execution runs as a task under here.
      {Task.Supervisor, name: PurpleFlow.StepSupervisor},
      # One PurpleFlow.Run per run.
      {DynamicSupervisor, name: PurpleFlow.RunSupervisor},
      PurpleFlow.Scheduler,
      PurpleFlow.Workflows,
      # UI + webhooks, last.
      PurpleFlowWeb.Endpoint
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # Without a separate runner to send Code node scripts to, run one in this
  # VM: same protocol, no isolation. Releases refuse to boot without one
  # (config/runtime.exs), so this is only ever dev and test.
  defp in_vm_runner do
    if Application.get_env(:purple_flow, :runner_address) == nil do
      Logger.warning(
        "No PURPLEFLOW_RUNNER_ADDRESS: Code node scripts run inside this VM, " <>
          "with the same access as the app itself. Fine for dev and test only."
      )

      [
        {Task.Supervisor, name: PurpleFlow.Runner.Connections},
        PurpleFlow.Runner.Server
      ]
    end
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
