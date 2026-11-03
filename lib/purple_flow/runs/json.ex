defmodule PurpleFlow.Runs.JSON do
  @moduledoc """
  A database column that holds any JSON value: a map, a list, a string, a
  number, `true`/`false`, or `nil`. (Ecto's built-in `:map` only takes maps,
  but a step's input or output can be a list or a plain value.)

  See [specs/050](specs/050_storage.md).
  """

  use Ecto.Type

  @impl true
  def type, do: :map
  @impl true
  def cast(value), do: {:ok, value}
  @impl true
  def load(value), do: {:ok, value}
  @impl true
  def dump(value), do: {:ok, value}

  # jsonb columns come back as-is, so skip Ecto's map checks.
  @impl true
  def embed_as(_format), do: :dump
end
