defmodule PurpleFlow.StepTask do
  @moduledoc """
  One node execution, run in its own process. `PurpleFlow.Run` starts it
  under `PurpleFlow.StepSupervisor`, watches it, and gets back its result.

  The execution:

  1. fills in the config's `{{ }}` placeholders
  2. runs the node (which may hand over items early with
     `PurpleFlow.Node.emit/2`)
  3. makes the result JSON-shaped and redacts credentials from it

  It doesn't save anything or talk to anyone but the run: the run saves
  rows in batches and decides where items go. Timeouts are the run's job
  too; it kills the execution. See `specs/120_flow.md`.
  """

  alias PurpleFlow.{Redact, Template}

  @doc """
  Starts an execution for `run` (the run's pid). `args` has `:step`,
  `:input` (one item), and `:steps` (this item's path, as
  `%{"fetch" => %{"output" => ...}}`). Returns a `Task`; its reply is
  `%{status:, output:, route:, error:, input:}`.
  """
  def start(run, args) do
    Task.Supervisor.async_nolink(PurpleFlow.StepSupervisor, fn -> execute(run, args) end)
  end

  @doc false
  def execute(run, %{step: step, input: input, steps: steps}) do
    case Template.render(step.config, %{input: input, steps: steps}) do
      {:ok, config, secrets} ->
        Process.put(:purple_flow_emit, fn value, route -> emit(run, value, route, secrets) end)
        Process.put(:purple_flow_respond, &respond(run, &1))

        case call_node(step.module, input, config, steps) do
          {:ok, output, route} ->
            %{
              status: :ok,
              output: Redact.redact(output, secrets),
              route: route,
              error: nil,
              input: Redact.redact(input, secrets)
            }

          {:error, message} ->
            error(Redact.redact(message, secrets), Redact.redact(input, secrets))
        end

      {:error, message} ->
        error(message, input)
    end
  end

  defp error(message, input),
    do: %{status: :error, output: nil, route: nil, error: %{"message" => message}, input: input}

  # Hands one item to the run now. Waits while the run holds it back.
  defp emit(run, value, route, secrets) when is_binary(route) or is_nil(route) do
    case to_json(value) do
      {:ok, value} ->
        GenServer.call(run, {:emit, self(), Redact.redact(value, secrets), route}, :infinity)

      {:error, message} ->
        raise "emitted #{message}"
    end
  end

  # Answers the waiting webhook caller, if any. Not redacted: the reply is
  # what the workflow chose to send, like an HTTP node's request body.
  defp respond(run, reply) do
    case to_json(reply) do
      {:ok, reply} -> GenServer.call(run, {:respond, reply}, :infinity)
      {:error, message} -> raise "reply #{message}"
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
      {:error, message} -> {:error, "output " <> message}
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
      {:error, error} -> {:error, "isn't JSON: #{Exception.message(error)}"}
    end
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)
end
