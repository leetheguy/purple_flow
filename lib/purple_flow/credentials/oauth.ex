defmodule PurpleFlow.Credentials.OAuth do
  @moduledoc """
  OAuth credentials: connecting one, and handing out a working access token.

  A workflow never sees any of this. `PurpleFlow.Credentials.get/1` calls
  `access_token/1` for an OAuth credential, which returns the saved token
  if it's still good, or renews it first. See `specs/200_oauth_credentials.md`.

  The flow is OAuth 2's authorization code with PKCE (a one-time secret
  that proves the app that asked is the app that finishes) and refresh
  tokens (a long-lived token that gets new short-lived ones).
  """

  alias PurpleFlow.Credentials.{Cipher, Credential}
  alias PurpleFlow.Repo

  # Google's, since that's the common case. Any provider works by changing them.
  @defaults %{
    "auth_url" => "https://accounts.google.com/o/oauth2/v2/auth",
    "token_url" => "https://oauth2.googleapis.com/token"
  }

  # A token with less than this many seconds left is renewed first.
  @margin 60

  @doc "Google's authorize and token addresses, for filling in the form."
  def defaults, do: @defaults

  @doc """
  A working access token for an OAuth credential that's connected, or
  `{:error, message}` if it can't be renewed.
  """
  @spec access_token(%Credential{}) :: String.t() | {:error, String.t()}
  def access_token(%Credential{} = cred) do
    case fresh_token(cred) do
      nil ->
        # One renewal at a time per credential. Whoever waited re-reads it:
        # the one before may have renewed it already.
        :global.trans({{__MODULE__, cred.id}, self()}, fn ->
          cred = Repo.get!(Credential, cred.id)
          fresh_token(cred) || renew(cred)
        end)

      token ->
        token
    end
  end

  defp fresh_token(cred) do
    case tokens(cred) do
      %{"access_token" => token, "expires_at" => nil} ->
        token

      %{"access_token" => token, "expires_at" => at} ->
        if at - System.system_time(:second) > @margin, do: token

      _ ->
        nil
    end
  end

  defp renew(cred) do
    case tokens(cred) do
      %{"refresh_token" => refresh} when is_binary(refresh) ->
        params = [grant_type: "refresh_token", refresh_token: refresh] ++ client(cred)

        case post(cred, params) do
          {:ok, body} ->
            tokens = save_tokens(cred, body)
            tokens["access_token"]

          {:rejected, why} ->
            reconnect(cred, why)

          {:error, why} ->
            {:error, "credential #{cred.name} couldn't be renewed: #{why}"}
        end

      _ ->
        reconnect(cred, "no refresh token was given")
    end
  end

  # The provider said no: mark it, so the page shows it needs reconnecting.
  defp reconnect(cred, why) do
    cred |> Ecto.Changeset.change(oauth_error: why) |> Repo.update!()
    {:error, "credential #{cred.name} needs reconnecting at /credentials (#{why})"}
  end

  @doc """
  Where to send the browser to connect: the provider's "allow this?" page.
  `verifier` is the PKCE secret kept in the session until the callback.
  """
  def authorize_url(%Credential{} = cred, redirect_uri, state, verifier) do
    settings = settings(cred)

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => settings["client_id"],
        "redirect_uri" => redirect_uri,
        "scope" => settings["scopes"] || "",
        "state" => state,
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        "code_challenge_method" => "S256",
        # Google hands out a refresh token only with these; others ignore them.
        "access_type" => "offline",
        "prompt" => "consent"
      })

    settings["auth_url"] <>
      if(String.contains?(settings["auth_url"], "?"), do: "&", else: "?") <> query
  end

  @doc """
  Finishes connecting: trades the `code` the provider sent back for tokens
  and saves them. `{:ok, credential}` or `{:error, message}`.
  """
  def connect(%Credential{} = cred, code, redirect_uri, verifier) do
    params =
      [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: verifier
      ] ++ client(cred)

    case post(cred, params) do
      {:ok, body} ->
        save_tokens(cred, body)
        {:ok, Repo.get!(Credential, cred.id)}

      {_rejected_or_error, why} ->
        {:error, why}
    end
  end

  # New tokens replace the old; a refresh token the provider didn't resend
  # is kept. Saving doesn't announce a change, so workflows don't reload.
  defp save_tokens(cred, body) do
    old = tokens(cred) || %{}

    tokens = %{
      "access_token" => body["access_token"],
      "refresh_token" => body["refresh_token"] || old["refresh_token"],
      "expires_at" =>
        if(is_integer(body["expires_in"]),
          do: System.system_time(:second) + body["expires_in"]
        )
    }

    cred
    |> Ecto.Changeset.change(key: Cipher.encrypt(Jason.encode!(tokens)), oauth_error: nil)
    |> Repo.update!()

    tokens
  end

  defp post(cred, params) do
    options =
      [form: params, retry: false] ++ Application.get_env(:purple_flow, :oauth_req_options, [])

    case Req.post(settings(cred)["token_url"], options) do
      {:ok, %{status: status, body: %{"access_token" => token} = body}}
      when status in 200..299 and is_binary(token) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in 400..499 ->
        {:rejected, describe(body, status)}

      {:ok, %{status: status, body: body}} ->
        {:error, describe(body, status)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp describe(%{"error_description" => text}, _status) when is_binary(text), do: text
  defp describe(%{"error" => text}, _status) when is_binary(text), do: text
  defp describe(_body, status), do: "HTTP #{status}"

  defp client(cred) do
    [client_id: settings(cred)["client_id"], client_secret: client_secret(cred)]
  end

  defp client_secret(%Credential{client_secret: nil}), do: ""
  defp client_secret(%Credential{client_secret: secret}), do: Cipher.decrypt(secret)

  defp settings(cred), do: Map.merge(@defaults, cred.oauth || %{}, fn _k, d, v -> v || d end)

  defp tokens(%Credential{key: nil}), do: nil
  defp tokens(%Credential{key: key}), do: key |> Cipher.decrypt() |> Jason.decode!()
end
