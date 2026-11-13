defmodule PurpleFlow.MCPConnections do
  @moduledoc """
  Apps a person allowed to reach `/mcp`, and their sign-in codes and
  tokens. PurpleFlow is its own small OAuth server for this
  ([OAuth 2.1](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-13)
  with PKCE); the web side is `PurpleFlowWeb.MCPAuthController`. See
  [specs/270](specs/270_mcp_files.md).

  The flow: `allow/2` when a person clicks Allow, which gives a code;
  `exchange_code/2` trades it for an access token and a refresh token;
  `verify_access/2` checks an access token on each `/mcp` request;
  `refresh/2` swaps a refresh token for new ones. `disconnect/1` ends it.

  Codes and tokens are 32 random bytes, handed out once and stored only as
  SHA-256 hashes, so a copy of the database can't be used to connect. The
  functions that check times take `now`, so tests can set the clock.
  """

  import Ecto.Query

  alias PurpleFlow.MCPConnections.Connection
  alias PurpleFlow.Repo

  @code_seconds 60
  @access_seconds 3600

  @doc """
  Records an allowed app and returns `{:ok, code}`, its one-time sign-in
  code, good for 60 seconds. `attrs` has `client_id`, `client_name`,
  `redirect_uri`, and `code_challenge` (PKCE, S256). Also clears out codes
  from sign-ins that were never finished.
  """
  def allow(attrs, now \\ DateTime.utc_now()) do
    Repo.delete_all(
      from c in Connection, where: is_nil(c.access_hash) and c.code_expires_at < ^now
    )

    code = token()

    %Connection{
      client_id: attrs.client_id,
      client_name: attrs.client_name,
      redirect_uri: attrs.redirect_uri,
      code_challenge: attrs.code_challenge,
      code_hash: hash(code),
      code_expires_at: DateTime.add(now, @code_seconds)
    }
    |> Repo.insert!()

    {:ok, code}
  end

  @doc """
  Trades a code for tokens (`grant_type=authorization_code`). `params` are
  the token request's `code`, `code_verifier`, `client_id`, and
  `redirect_uri`, which must match the ones the code was made for. A code
  works once. The app's earlier connection, if any, is replaced. Returns
  `{:ok, tokens}` (`access_token`, `refresh_token`,
  `expires_in`) or `{:error, :invalid_grant}`.
  """
  def exchange_code(params, now \\ DateTime.utc_now()) do
    with code when is_binary(code) <- params["code"],
         # Taking the code clears it in the same statement, so two requests
         # with one code can't both get tokens.
         {1, [connection]} <-
           Repo.update_all(
             from(c in Connection, where: c.code_hash == ^hash(code), select: c),
             set: [code_hash: nil]
           ),
         true <- DateTime.compare(now, connection.code_expires_at) != :gt,
         true <- params["client_id"] == connection.client_id,
         true <- params["redirect_uri"] == connection.redirect_uri,
         true <- pkce?(params["code_verifier"], connection.code_challenge) do
      # An app connecting again throws its old tokens away, so its earlier
      # connection goes: one row per app, and no old token left working.
      Repo.delete_all(
        from c in Connection,
          where:
            c.client_id == ^connection.client_id and c.id != ^connection.id and
              not is_nil(c.access_hash)
      )

      {:ok, issue(connection, now)}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  @doc """
  Swaps a refresh token for a new access token and refresh token
  (`grant_type=refresh_token`); the old ones stop working. A `client_id`,
  when given, must be the app's. Returns `{:ok, tokens}` or
  `{:error, :invalid_grant}`.
  """
  def refresh(params, now \\ DateTime.utc_now()) do
    with token when is_binary(token) <- params["refresh_token"],
         %Connection{} = connection <- Repo.get_by(Connection, refresh_hash: hash(token)),
         true <- params["client_id"] in [nil, connection.client_id] do
      {:ok, issue(connection, now)}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  @doc """
  The connection an access token belongs to, as `{:ok, connection}`, or
  `:error` when it's unknown or expired. Records when the app was last used.
  """
  def verify_access(token, now \\ DateTime.utc_now()) when is_binary(token) do
    with %Connection{} = connection <- Repo.get_by(Connection, access_hash: hash(token)),
         :gt <- DateTime.compare(connection.access_expires_at, now) do
      {:ok, connection |> Ecto.Changeset.change(last_used_at: now) |> Repo.update!()}
    else
      _ -> :error
    end
  end

  @doc "Every app that finished signing in, oldest first."
  def list do
    Repo.all(from c in Connection, where: not is_nil(c.access_hash), order_by: c.id)
  end

  @doc "Removes an app; its tokens stop working at once. `:ok` even if it was already gone."
  def disconnect(id) do
    Repo.delete_all(from c in Connection, where: c.id == ^id)
    :ok
  end

  defp issue(connection, now) do
    access = token()
    refresh = token()

    connection
    |> Ecto.Changeset.change(
      access_hash: hash(access),
      access_expires_at: DateTime.add(now, @access_seconds),
      refresh_hash: hash(refresh)
    )
    |> Repo.update!()

    %{access_token: access, refresh_token: refresh, expires_in: @access_seconds}
  end

  # PKCE (RFC 7636): the challenge is the verifier's SHA-256, base64url.
  defp pkce?(verifier, challenge) when is_binary(verifier) do
    Plug.Crypto.secure_compare(
      Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
      challenge
    )
  end

  defp pkce?(_verifier, _challenge), do: false

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp hash(value), do: :crypto.hash(:sha256, value)
end
