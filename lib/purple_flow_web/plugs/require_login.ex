defmodule PurpleFlowWeb.Plugs.RequireLogin do
  @moduledoc """
  Sends anyone who isn't signed in to `/login`, remembering where they were
  going. Covers the whole browser UI (not `/hooks/*`, which can't sign in —
  see `PurpleFlowWeb.Router`). See `PurpleFlowWeb.Auth`.

  Needs the session fetched first.
  """

  @behaviour Plug

  import Plug.Conn

  alias PurpleFlowWeb.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Auth.signed_in?(conn) do
      conn
    else
      conn
      |> Phoenix.Controller.redirect(to: login_path(conn))
      |> halt()
    end
  end

  @doc "`/login`, returning to `conn`'s page afterwards if it's a GET."
  def login_path(%{method: "GET"} = conn) do
    here =
      conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

    if here == "/", do: "/login", else: "/login?" <> URI.encode_query(%{"return_to" => here})
  end

  def login_path(_conn), do: "/login"
end
