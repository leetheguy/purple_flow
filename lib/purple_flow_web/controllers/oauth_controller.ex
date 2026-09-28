defmodule PurpleFlowWeb.OAuthController do
  @moduledoc """
  Connecting an OAuth credential, behind the sign-in.

  `connect` sends the browser to the provider's "allow this?" page, keeping
  a random `state` and a PKCE verifier in the session. The provider sends
  the browser back to `callback`, which checks `state`, trades the code for
  tokens, and returns to `/credentials`. See `specs/200_oauth_credentials.md`.
  """

  use PurpleFlowWeb, :controller

  alias PurpleFlow.Credentials
  alias PurpleFlow.Credentials.OAuth

  @doc "This site's callback address, for the provider's client settings."
  def callback_url, do: url(~p"/credentials/oauth/callback")

  def connect(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %{type: "oauth"} = cred <- Credentials.fetch(id) do
      state = random()
      verifier = random()

      conn
      |> put_session(:oauth_connect, %{"id" => cred.id, "state" => state, "verifier" => verifier})
      |> redirect(external: OAuth.authorize_url(cred, callback_url(), state, verifier))
    else
      _ -> back(conn, :error, "There's no OAuth credential to connect there.")
    end
  end

  def callback(conn, params) do
    pending = get_session(conn, :oauth_connect)
    conn = delete_session(conn, :oauth_connect)

    case finish(pending, params) do
      {:ok, cred} -> back(conn, :info, "#{cred.name} connected")
      {:error, why} -> back(conn, :error, "Couldn't connect: #{why}")
    end
  end

  defp finish(%{"id" => id, "state" => state, "verifier" => verifier}, params) do
    cred = Credentials.fetch(id)

    cond do
      not (is_binary(params["state"]) and Plug.Crypto.secure_compare(params["state"], state)) ->
        {:error, "the reply didn't match this sign-in. Try Reconnect again."}

      is_binary(params["error"]) ->
        {:error, params["error_description"] || params["error"]}

      cred == nil ->
        {:error, "the credential is gone"}

      not is_binary(params["code"]) ->
        {:error, "the provider sent no code"}

      true ->
        OAuth.connect(cred, params["code"], callback_url(), verifier)
    end
  end

  defp finish(_pending, _params),
    do: {:error, "no connection was started from this browser. Try Reconnect again."}

  defp back(conn, kind, message),
    do: conn |> put_flash(kind, message) |> redirect(to: ~p"/credentials")

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
