defmodule PurpleFlow.StepTask do
  @moduledoc """
  Runs one node execution, start to finish, on its own.

  For each execution a task:

  1. broadcasts `step_started`
  2. fills in the config's `{{ }}` placeholders
  3. runs the node, giving up after the step's `timeout`
  4. redacts credentials, saves its record, broadcasts `step_finished`

  Tasks aren't linked to the run. They finish and save their records even if
  the run has already stopped.
  """

  require Logger

  alias PurpleFlow.{Redact, Runs, Template}

  @doc """
  Starts a task under `PurpleFlow.StepSupervisor`.

  `args` has `:run_id`, `:step`, `:item`, `:from_item`, `:input`, `:steps`
  (ancestor outputs), and `:instance` (which start of the step this is).
  """
  def start(args) do
    Task.Supervisor.start_child(PurpleFlow.StepSupervisor, fn -> run(args) end)
  end

  @doc false
  def run(%{run_id: run_id, step: step, item: item} = args) do
    started_at = DateTime.utc_now()
    PurpleFlow.broadcast(run_id, {:step_started, run_id, step.name, item})

    {result, secrets} =
      case Template.render(step.config, %{input: args.input, steps: args.steps}) do
        {:ok, config, secrets} -> {execute(step, args.input, config, args.steps), secrets}
        {:error, message} -> {{:error, message}, []}
      end

    {status, output, route, error} =
      case result do
        {:ok, output, route} ->
          {:ok, output, route, nil}

        {:error, message} ->
          {:error, nil, nil, %{"message" => message}}

        :timed_out ->
          {:timed_out, nil, nil, %{"message" => "timed out after #{div(step.timeout, 1000)}s"}}
      end

    input = Redact.redact(args.input, secrets)
    output = Redact.redact(output, secrets)
    error = Redact.redact(error, secrets)

    save(%{
      run_id: run_id,
      step: step.name,
      item: item,
      from_item: args.from_item,
      status: to_string(status),
      route: route,
      input: input,
      output: output,
      error: error,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    })

    PurpleFlow.broadcast(
      run_id,
      {:step_finished, run_id, step.name, item,
       %{instance: args.instance, status: status, output: output, route: route, error: error}}
    )
  end

  # Runs the node in its own process so it can be stopped if it takes too long.
  defp execute(step, input, config, steps) do
    inner =
      Task.Supervisor.async_nolink(PurpleFlow.StepSupervisor, fn ->
        call_node(step.module, input, config, steps)
      end)

    case Task.yield(inner, step.timeout) || Task.shutdown(inner, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "node crashed: #{Exception.format_exit(reason)}"}
      nil -> :timed_out
    end
  end

  defp call_node(module, input, config, steps) do
    result =
      if function_exported?(module, :execute, 3),
        do: module.execute(input, config, steps),
        else: module.execute(input, config)

    normalize(result)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, value -> {:error, Exception.format_banner(kind, value)}
  end

  # Every node result becomes {:ok, output, route} or {:error, message}.
  # Outputs are round-tripped through JSON so what's in memory matches what's saved.
  defp normalize({:ok, output}), do: normalize({:ok, output, nil})

  defp normalize({:ok, output, route}) when is_binary(route) or is_nil(route) do
    case to_json(output) do
      {:ok, output} -> {:ok, output, route}
      {:error, message} -> {:error, message}
    end
  end

  defp normalize({:error, reason}), do: {:error, message(reason)}
  defp normalize(other), do: {:error, "node returned something unexpected: #{inspect(other)}"}

  defp to_json(value) do
    with {:ok, text} <- Jason.encode(value) do
      Jason.decode(text)
    end
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, "output isn't JSON: #{Exception.message(error)}"}
    end
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)

  # If saving fails, still broadcast, so the run hears about it and doesn't wait forever.
  defp save(fields) do
    Runs.save_step(fields)
  rescue
    error -> Logger.error("couldn't save step #{fields.step}: #{Exception.message(error)}")
  end
end
