defmodule PurpleFlow.Repo do
  use Ecto.Repo,
    otp_app: :purple_flow,
    adapter: Ecto.Adapters.Postgres
end
