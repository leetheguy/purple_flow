defmodule PurpleFlow.Runs do
  @moduledoc """
  Reads and writes saved runs.

  Records are written as things happen, not at the end, so a crash never
  loses what already ran.
  """

  import Ecto.Query

  alias PurpleFlow.Repo
  alias PurpleFlow.Runs.{Run, StepRun}

  @doc "Saves a new run as `running`."
  def start_run(id, workflow, trigger, input) do
    Repo.insert!(%Run{
      id: id,
      workflow: workflow,
      trigger: trigger,
      status: "running",
      input: input,
      started_at: DateTime.utc_now()
    })
  end

  @doc "Marks a run `complete` (with its output) or `failed` (with its error)."
  def finish_run(id, status, fields) when status in ["complete", "failed"] do
    Repo.update_all(
      from(r in Run, where: r.id == ^id),
      set: [status: status, finished_at: DateTime.utc_now()] ++ fields
    )
  end

  @doc "Saves one node execution."
  def save_step(fields) do
    Repo.insert!(struct!(StepRun, fields))
  end

  @doc "Newest runs first. `workflow: nil` lists runs of every workflow."
  def list(workflow, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Run
    |> then(fn q -> if workflow, do: where(q, [r], r.workflow == ^workflow), else: q end)
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "A run plus all of its step rows, or `nil`."
  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Run{} = run <- Repo.get(Run, id) do
      steps =
        from(s in StepRun, where: s.run_id == ^id, order_by: [s.started_at, s.item, s.id])
        |> Repo.all()

      %{run: run, steps: steps}
    else
      _ -> nil
    end
  end

  @doc "The status of each workflow's most recent run, as `%{workflow => status}`."
  def last_statuses do
    from(r in Run,
      distinct: r.workflow,
      order_by: [r.workflow, desc: r.started_at],
      select: {r.workflow, r.status}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Called at boot. Any run still marked `running` belonged to an app that
  stopped, so it can never finish. Mark it `interrupted`.
  """
  def mark_interrupted do
    from(r in Run, where: r.status == "running")
    |> Repo.update_all(set: [status: "interrupted", finished_at: DateTime.utc_now()])

    :ok
  end
end
