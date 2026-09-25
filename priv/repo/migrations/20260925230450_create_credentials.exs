defmodule PurpleFlow.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials) do
      add :name, :text, null: false
      add :key, :binary
      add :description, :text, null: false, default: ""
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credentials, [:name])
  end
end
