defmodule PurpleFlow.Runs.JSON do
  @moduledoc """
  A database column that holds any JSON value: a map, a list, a string, a
  number, `true`/`false`, or `nil`. (Ecto's built-in `:map` only takes maps,
  but a step's input or output can be a list or a plain value.)
  """

  use Ecto.Type

  def type, do: :map
  def cast(value), do: {:ok, value}
  def load(value), do: {:ok, value}
  def dump(value), do: {:ok, value}

  # jsonb columns come back as-is, so skip Ecto's map checks.
  def embed_as(_format), do: :dump
end
