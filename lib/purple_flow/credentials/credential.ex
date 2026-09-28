defmodule PurpleFlow.Credentials.Credential do
  @moduledoc """
  A named secret, referenced from a workflow as `{{ creds.NAME }}`.

  `type` is `"text"` (a plain value in `key`) or `"oauth"`: `oauth` holds
  its settings, `client_secret` is encrypted, and `key` holds its tokens,
  encrypted, once connected. See `specs/200_oauth_credentials.md`.
  """

  use Ecto.Schema

  schema "credentials" do
    field :name, :string
    field :type, :string, default: "text"
    field :key, :binary
    field :description, :string, default: ""
    field :oauth, :map
    field :client_secret, :binary
    field :oauth_error, :string
    field :archived_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
