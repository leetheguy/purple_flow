defmodule PurpleFlow.Runs.StepRun do
  @moduledoc "A saved node execution. The task that ran the node writes it."

  use Ecto.Schema

  schema "step_runs" do
    field :run_id, :binary_id
    field :step, :string
    field :item, :integer
    field :from_item, :integer
    field :status, :string
    field :route, :string
    field :input, PurpleFlow.Runs.JSON
    field :output, PurpleFlow.Runs.JSON
    field :error, PurpleFlow.Runs.JSON
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
  end
end
