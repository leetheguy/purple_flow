defmodule PurpleFlow.Nodes.Respond do
  @moduledoc """
  Answers the webhook that started the run, now, while the run carries on.

      module = "PurpleFlow.Nodes.Respond"

      [config]
      status = 200                                  # default 200
      headers = { "x-request-id" = "{{ input.id }}" }  # optional
      body = { ok = true, id = "{{ input.id }}" }   # default: this step's input

  A text `body` is sent as is (`text/plain` unless `headers` sets a
  `content-type`); anything else is sent as JSON.

  It works with `respond = "result"` (the default), where the caller is
  waiting: the first Respond step to run answers, and the run goes on
  without the caller. Later Respond steps, and runs nobody is waiting on
  (`respond = "immediately"` or `"stream"`, cron, the Run button, the
  Workflow node), answer no one. A run that ends before any Respond step
  runs answers with its output, as usual.

  Either way the step hands its input on unchanged. See `specs/180_noop_wait_respond.md`.
  """

  @behaviour PurpleFlow.Node

  @impl true
  def prepare(config, _node_dir, _root) do
    with :ok <- check(config, "status", &status/1),
         :ok <- check(config, "headers", &headers/1) do
      {:ok, config}
    end
  end

  @impl true
  def execute(input, config) do
    with {:ok, status} <- status(Map.get(config, "status", 200)),
         {:ok, headers} <- headers(Map.get(config, "headers", %{})) do
      PurpleFlow.Node.respond(%{
        "status" => status,
        "headers" => headers,
        "body" => Map.get(config, "body", input)
      })

      {:ok, input}
    end
  end

  # A value with a placeholder can only be checked once it's filled in.
  defp check(config, key, parse) do
    case Map.fetch(config, key) do
      :error -> :ok
      {:ok, "{{" <> _} -> :ok
      {:ok, value} -> with {:ok, _} <- parse.(value), do: :ok
    end
  end

  defp status(n) when is_integer(n) and n in 100..599, do: {:ok, n}

  defp status(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n in 100..599 -> {:ok, n}
      _ -> status(nil)
    end
  end

  defp status(other),
    do: {:error, "Respond status must be an HTTP status, 100 to 599, not #{inspect(other)}"}

  # Header names are lowercased; values must be single-line text or numbers.
  defp headers(headers) when is_map(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      value = if is_number(value) or is_boolean(value), do: to_string(value), else: value

      if is_binary(value) and not String.contains?(value, ["\r", "\n"]) and
           not String.contains?(to_string(name), ["\r", "\n", ":", " "]) do
        {:cont, {:ok, Map.put(acc, String.downcase(to_string(name)), value)}}
      else
        {:halt,
         {:error,
          "Respond header #{inspect(name)} must be one line of text, not #{inspect(value)}"}}
      end
    end)
  end

  defp headers(other), do: {:error, "Respond headers must be a table, not #{inspect(other)}"}
end
