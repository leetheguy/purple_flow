defmodule PurpleFlow.Nodes.Batch do
  @moduledoc """
  Gathers items and hands them on as one: `{"items": [...]}`.

      module = "PurpleFlow.Nodes.Batch"

      [config]
      size = 100      # hand on a batch once it has this many items
      wait = 2000     # optional: or once the oldest has waited this many ms

  The run handles Batch steps itself: items collect in the step's batch
  instead of each starting an execution, and a batch goes when it's full,
  when `wait` runs out, or when nothing more can reach it. This module
  only checks the config and shapes the output. See `specs/140_batch.md`.
  """

  @behaviour PurpleFlow.Node

  @impl true
  def prepare(config, _node_dir, _root) do
    with :ok <- check(config, "size", true),
         :ok <- check(config, "wait", false) do
      {:ok, config}
    end
  end

  @impl true
  def execute(items, _config) when is_list(items), do: {:ok, %{"items" => items}}

  defp check(config, key, required?) do
    case Map.fetch(config, key) do
      {:ok, n} when is_integer(n) and n >= 1 ->
        :ok

      :error when not required? ->
        :ok

      :error ->
        {:error, "Batch needs `#{key}`, a whole number, 1 or more"}

      {:ok, other} ->
        {:error, "Batch #{key} must be a whole number, 1 or more, not #{inspect(other)}"}
    end
  end
end
