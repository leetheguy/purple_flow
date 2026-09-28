defmodule PurpleFlow.Nodes.Wait do
  @moduledoc """
  Waits, then hands its input on unchanged.

      module = "PurpleFlow.Nodes.Wait"

      [config]
      ms = 5000                          # wait this many milliseconds
      # or:
      until = "2026-10-01T09:00:00Z"     # wait until this time (ISO 8601, with an offset)

  Exactly one of `ms` or `until`. Both take templates (`ms =
  "{{ input.retry_after_ms }}"`). A time already past doesn't wait.

  Each item waits on its own, so with the step's default `concurrency`
  many items wait at once. The step's `timeout` covers the wait, and Kill
  stops it. A wait lives in memory: a restart marks the run `interrupted`,
  like any other.
  """

  @behaviour PurpleFlow.Node

  @impl true
  def prepare(config, _node_dir, _root) do
    case {Map.has_key?(config, "ms"), Map.has_key?(config, "until")} do
      {true, true} -> {:error, "Wait takes `ms` or `until`, not both"}
      {false, false} -> {:error, "Wait needs `ms` (milliseconds) or `until` (a time)"}
      {true, false} -> check(config["ms"], &ms/1, config)
      {false, true} -> check(config["until"], &until/1, config)
    end
  end

  @impl true
  def execute(input, config) do
    wait =
      case config do
        %{"ms" => value} -> ms(value)
        %{"until" => value} -> until(value)
      end

    with {:ok, ms} <- wait do
      Process.sleep(ms)
      {:ok, input}
    end
  end

  # A value with a placeholder can only be checked once it's filled in.
  defp check(value, parse, config) do
    if is_binary(value) and value =~ "{{" do
      {:ok, config}
    else
      with {:ok, _ms} <- parse.(value), do: {:ok, config}
    end
  end

  defp ms(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp ms(n) when is_float(n) and n >= 0, do: {:ok, round(n)}

  defp ms(text) when is_binary(text) do
    case Float.parse(String.trim(text)) do
      {n, ""} -> ms(n)
      _ -> ms(nil)
    end
  end

  defp ms(other), do: {:error, "Wait ms must be a number, 0 or more, not #{inspect(other)}"}

  defp until(%DateTime{} = time),
    do: {:ok, max(DateTime.diff(time, DateTime.utc_now(), :millisecond), 0)}

  defp until(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _offset} -> until(time)
      {:error, _} -> until(nil)
    end
  end

  defp until(other),
    do: {:error, "Wait until must be a time like \"2026-10-01T09:00:00Z\", not #{inspect(other)}"}
end
