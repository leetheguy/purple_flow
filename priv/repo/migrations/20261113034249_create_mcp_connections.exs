defmodule PurpleFlow.Repo.Migrations.CreateMcpConnections do
  use Ecto.Migration

  # Apps allowed to reach /mcp: specs/270_mcp_files.md. Codes and tokens
  # are stored only as SHA-256 hashes.
  def change do
    create table(:mcp_connections) do
      add :client_id, :text, null: false
      add :client_name, :text, null: false
      add :redirect_uri, :text, null: false
      add :code_hash, :binary
      add :code_challenge, :text
      add :code_expires_at, :utc_datetime_usec
      add :access_hash, :binary
      add :access_expires_at, :utc_datetime_usec
      add :refresh_hash, :binary
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_connections, [:code_hash])
    create unique_index(:mcp_connections, [:access_hash])
    create unique_index(:mcp_connections, [:refresh_hash])
  end
end
