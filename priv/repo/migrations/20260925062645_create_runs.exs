defmodule PurpleFlow.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    # One row per workflow run.
    create table(:runs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workflow, :text, null: false
      add :trigger, :text, null: false
      add :status, :text, null: false
      add :input, :jsonb
      add :output, :jsonb
      add :error, :jsonb
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
    end

    create index(:runs, [:workflow, :started_at])
    create index(:runs, [:status])

    # One row per node execution. A step that ran over 10 items has 10 rows.
    create table(:step_runs) do
      add :run_id, references(:runs, type: :uuid, on_delete: :delete_all), null: false
      add :step, :text, null: false
      add :item, :integer
      add :from_item, :integer
      add :status, :text, null: false
      add :route, :text
      add :input, :jsonb
      add :output, :jsonb
      add :error, :jsonb
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec, null: false
    end

    create index(:step_runs, [:run_id])
  end
end
