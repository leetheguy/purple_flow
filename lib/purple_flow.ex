defmodule PurpleFlow do
  @moduledoc """
  A barebones n8n on Elixir/OTP. This module is the front door: every trigger
  (webhook, cron, the UI's Run button, IEx) ends up calling `run/3`.

      PurpleFlow.run("sync_records", %{"since" => "2026-01-01"})
      #=> {:ok, "0192..."}
  """

  alias PurpleFlow.{Id, Runs, Workflows}

  @doc """
  Starts a run of the named workflow and returns its ID right away, without
  waiting for it to finish.

  Options: `trigger:` (saved with the run; defaults to `"manual"`).
  """
  @spec run(String.t(), term(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(workflow_name, input, opts \\ []) do
    with {:ok, workflow} <- Workflows.fetch(workflow_name) do
      start_run(workflow, input, opts)
    end
  end

  @doc "Same as `run/3`, but takes an already-loaded `PurpleFlow.Workflow`."
  def start_run(%PurpleFlow.Workflow{} = workflow, input, opts \\ []) do
    with {:ok, input} <- to_json(input) do
      id = Keyword.get(opts, :id) || Id.generate()

      args = %{
        id: id,
        workflow: workflow,
        input: input,
        trigger: Keyword.get(opts, :trigger, "manual")
      }

      case DynamicSupervisor.start_child(PurpleFlow.RunSupervisor, {PurpleFlow.Run, args}) do
        {:ok, _pid} -> {:ok, id}
        {:error, reason} -> {:error, "couldn't start the run: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Starts a run and waits for it to finish. Returns `{:ok, output}` or
  `{:error, message}`. Used by the Workflow node.
  """
  def run_and_wait(workflow_name, input, opts \\ []) do
    id = Id.generate()

    # Subscribe *before* starting, so the "finished" message can't be missed.
    Phoenix.PubSub.subscribe(PurpleFlow.PubSub, topic(id))

    try do
      with {:ok, ^id} <- run(workflow_name, input, Keyword.put(opts, :id, id)) do
        receive do
          {:run_finished, ^id, "complete"} ->
            {:ok, Runs.get(id).run.output}

          {:run_finished, ^id, _failed} ->
            {:error, "workflow #{workflow_name} failed: #{Runs.get(id).run.error["message"]}"}
        end
      end
    after
      Phoenix.PubSub.unsubscribe(PurpleFlow.PubSub, topic(id))
    end
  end

  @doc "The PubSub topic for one run's messages."
  def topic(run_id), do: "run:" <> run_id

  @doc """
  Sends a message to everyone listening to a run (the run itself, the UI).
  With `runs: true` it also goes to the `"runs"` topic, for run lists.
  """
  def broadcast(run_id, message, opts \\ []) do
    Phoenix.PubSub.broadcast(PurpleFlow.PubSub, topic(run_id), message)
    if opts[:runs], do: Phoenix.PubSub.broadcast(PurpleFlow.PubSub, "runs", message)
    :ok
  end

  defp to_json(value) do
    with {:ok, text} <- Jason.encode(value),
         {:ok, value} <- Jason.decode(text) do
      {:ok, value}
    else
      _ -> {:error, "input isn't JSON"}
    end
  end
end
