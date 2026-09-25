defmodule PurpleFlow.Runs.Run do
  @moduledoc "A saved workflow run. The `PurpleFlow.Run` process writes it."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runs" do
    field :workflow, :string
    field :trigger, :string
    field :status, :string
    field :input, PurpleFlow.Runs.JSON
    field :output, PurpleFlow.Runs.JSON
    field :error, PurpleFlow.Runs.JSON
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
  end
end
