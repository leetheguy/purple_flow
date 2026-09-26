defmodule PurpleFlowWeb.SessionController do
  @moduledoc """
  `/login` and `/logout`. A plain form post, not a LiveView or a browser
  popup, so password managers fill and save it. See `PurpleFlowWeb.Auth`.
  """

  use PurpleFlowWeb, :controller

  alias PurpleFlowWeb.Auth

  def new(conn, params) do
    return_to = Auth.safe_return_to(params["return_to"])

    if Auth.required?() and not Auth.signed_in?(conn) do
      render_form(conn, return_to, params["username"] || "", nil)
    else
      redirect(conn, to: return_to)
    end
  end

  def create(conn, params) do
    username = params["username"] || ""
    return_to = Auth.safe_return_to(params["return_to"])

    if Auth.valid_login?(username, params["password"]) do
      conn |> Auth.sign_in() |> redirect(to: return_to)
    else
      conn
      |> put_status(401)
      |> render_form(return_to, username, "That username and password don't match.")
    end
  end

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
