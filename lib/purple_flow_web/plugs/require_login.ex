defmodule PurpleFlowWeb.Plugs.RequireLogin do
  @moduledoc """
  HTTP Basic Auth for the whole browser UI (not `/hooks/*`, which can't
  supply a login — see `PurpleFlowWeb.Router`).

  Only enforced when `PURPLEFLOW_ADMIN_USERNAME` and `PURPLEFLOW_ADMIN_PASSWORD`
  are both set. In dev and test, where nothing sets them, the UI stays open.
  A real deployment (see `docker-compose.yml`) requires both, so this is
  effectively always on there.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case credentials() do
      {username, password} ->
        Plug.BasicAuth.basic_auth(conn, username: username, password: password)

      nil ->
        conn
    end
  end

  defp credentials do
    with username when is_binary(username) <- System.get_env("PURPLEFLOW_ADMIN_USERNAME"),
         password when is_binary(password) <- System.get_env("PURPLEFLOW_ADMIN_PASSWORD") do
      {username, password}
    else
      _ -> nil
    end
  end
end
