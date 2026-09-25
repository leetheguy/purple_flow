defmodule PurpleFlow.Workflows do
  @moduledoc """
  Holds every loaded workflow in memory.

  Reads the `workflows/` folder at boot. `reload/0` reads it again (after a
  `git pull`, say) and re-registers cron jobs. Workflows with problems are
  logged and skipped; `errors/0` lists them.
  """

  use GenServer
  require Logger

  alias PurpleFlow.Workflow.Loader

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "All loaded workflows, sorted by name."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "`{:ok, workflow}` or `{:error, message}`."
  def fetch(name) do
    case GenServer.call(__MODULE__, {:get, name}) do
      nil -> {:error, "no workflow named #{inspect(name)}"}
      workflow -> {:ok, workflow}
    end
  end

  @doc "The workflow whose webhook path is `path`, or `nil`."
  def find_webhook(path), do: GenServer.call(__MODULE__, {:webhook, path})

  @doc "Workflows that didn't load, as `[{path, [problem]}]`."
  def errors, do: GenServer.call(__MODULE__, :errors)

  @doc "Reads the workflows folder again."
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "The folder workflows are read from."
  def dir, do: Application.get_env(:purple_flow, :workflows_dir, "workflows")

  @impl true
  def init(:ok), do: {:ok, load()}

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.workflows |> Map.values() |> Enum.sort_by(& &1.name), state}
  end

  def handle_call({:get, name}, _from, state), do: {:reply, state.workflows[name], state}

  def handle_call({:webhook, path}, _from, state) do
    {:reply, Enum.find(Map.values(state.workflows), &(&1.webhook == path)), state}
  end

  def handle_call(:errors, _from, state), do: {:reply, state.errors, state}
  def handle_call(:reload, _from, _state), do: {:reply, :ok, load()}

  defp load do
    {workflows, errors} = Loader.load_all(dir())

    for {path, problems} <- errors do
      Logger.error(
        "workflow #{Path.relative_to_cwd(path)} not loaded:\n  - " <>
          Enum.join(problems, "\n  - ")
      )
    end

    register_cron(workflows)
    %{workflows: workflows, errors: errors}
  end

  defp register_cron(workflows) do
    PurpleFlow.Scheduler.delete_all_jobs()

    for {name, %{cron: schedule}} <- workflows, schedule do
      PurpleFlow.Scheduler.new_job()
      |> Quantum.Job.set_name(String.to_atom("workflow:" <> name))
      |> Quantum.Job.set_schedule(Crontab.CronExpression.Parser.parse!(schedule))
      |> Quantum.Job.set_task(fn ->
        PurpleFlow.run(name, %{"scheduled_at" => DateTime.to_iso8601(DateTime.utc_now())},
          trigger: "cron"
        )
      end)
      |> PurpleFlow.Scheduler.add_job()
    end
  end
end
