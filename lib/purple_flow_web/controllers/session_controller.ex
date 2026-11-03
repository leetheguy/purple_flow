defmodule PurpleFlowWeb.SessionController do
  @moduledoc """
  `/login` and `/logout`. A plain form post, not a LiveView or a browser
  popup, so password managers fill and save it. See `PurpleFlowWeb.Auth`.

  See [specs/080](specs/080_credentials.md).
  """

  use PurpleFlowWeb, :controller

  alias PurpleFlowWeb.Auth

  @doc "`GET /login`: the sign-in page."
  def new(conn, params) do
    return_to = Auth.safe_return_to(params["return_to"])

    if Auth.required?() and not Auth.signed_in?(conn) do
      render_form(conn, return_to, params["username"] || "", nil)
    else
      redirect(conn, to: return_to)
    end
  end

  @doc "`POST /login`: signs in, or counts a failure toward the lockout."
  def create(conn, params) do
    username = params["username"] || ""
    return_to = Auth.safe_return_to(params["return_to"])

    case Auth.check_login(conn, username, params["password"]) do
      :ok ->
        conn |> Auth.sign_in() |> redirect(to: return_to)

      :invalid ->
        conn
        |> put_status(401)
        |> render_form(return_to, username, "That username and password don't match.")

      :locked ->
        conn
        |> put_status(429)
        |> render_form(
          return_to,
          username,
          "Too many failed sign-ins from this address. Try again in a few hours."
        )
    end
  end

  @doc "`DELETE /logout`: signs out."
  def delete(conn, _params) do
    conn |> Auth.sign_out() |> redirect(to: ~p"/login")
  end

  defp render_form(conn, return_to, username, error) do
    form = Phoenix.Component.to_form(%{"username" => username, "return_to" => return_to})

    conn
    |> assign(:page_title, "Sign in")
    |> render(:new, form: form, error: error)
  end
end
