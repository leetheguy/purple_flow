defmodule PurpleFlowWeb.HealthController do
  @moduledoc """
  `GET /health`: `200 ok` while the app is up. Outside the login, so
  Docker's healthcheck can reach it; it reveals nothing else.
  """

  use PurpleFlowWeb, :controller

  def show(conn, _params), do: text(conn, "ok")
end
