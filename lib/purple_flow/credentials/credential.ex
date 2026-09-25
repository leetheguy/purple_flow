defmodule PurpleFlow.Credentials.Credential do
  @moduledoc "A named secret, referenced from a workflow as `{{ creds.NAME }}`."

  use Ecto.Schema

  schema "credentials" do
    field :name, :string
    field :key, :binary
    field :description, :string, default: ""
    field :archived_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
