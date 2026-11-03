defmodule PurpleFlow.Repo do
  @moduledoc """
  The app's connection to its own Postgres database, through Ecto (Elixir's
  database library). Runs, executions, and credentials live there; see
  [specs/050](specs/050_storage.md). The Postgres node doesn't use it: it
  opens its own connections to the databases workflows name.
  """

  use Ecto.Repo,
    otp_app: :purple_flow,
    adapter: Ecto.Adapters.Postgres
end
