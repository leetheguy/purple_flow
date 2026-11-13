defmodule PurpleFlow.MCPConnections.Connection do
  @moduledoc """
  An app a person allowed to reach `/mcp`, like Claude. It holds hashes of
  its current sign-in code, access token, and refresh token, never the
  values. See `PurpleFlow.MCPConnections` and [specs/270](specs/270_mcp_files.md).
  """

  use Ecto.Schema

  schema "mcp_connections" do
    field :client_id, :string
    field :client_name, :string
    field :redirect_uri, :string
    field :code_hash, :binary
    field :code_challenge, :string
    field :code_expires_at, :utc_datetime_usec
    field :access_hash, :binary
    field :access_expires_at, :utc_datetime_usec
    field :refresh_hash, :binary
    field :last_used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
