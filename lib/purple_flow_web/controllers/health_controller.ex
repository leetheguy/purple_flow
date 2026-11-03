defmodule PurpleFlowWeb.HealthController do
  @moduledoc """
  `GET /health`: `200 ok` while the app is up. Outside the login, so
  Docker's health check and the app's own watchdog can reach it; it reveals
  nothing else.

  See [specs/250](specs/250_watchdog.md).
  """

  use PurpleFlowWeb, :controller

  @doc "`GET /health`: `200 ok`."
  def show(conn, _params), do: text(conn, "ok")
end
