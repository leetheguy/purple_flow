defmodule PurpleFlowWeb.MCPAuthController do
  @moduledoc """
  The OAuth side of `/mcp`: PurpleFlow signs in MCP apps like Claude
  itself, for the one person who signs in at `/login`. See
  [specs/270](specs/270_mcp_files.md).

  - `metadata`: the authorization server's public description
    ([RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414)).
  - `authorize`: behind the sign-in, the page asking whether to allow the
    app, after checking the request and the app's document
    (`PurpleFlowWeb.MCP.ClientDocument`).
  - `decide`: Allow or Deny from that page. Allow records the app
    (`PurpleFlow.MCPConnections`) and sends it back a code.
  - `token`: the app trades that code, or later a refresh token, for an
    access token to use at `/mcp`.

  A request that fails a check gets a page saying why and nothing sent
  back, since its redirect address can't be trusted.
  """

  use PurpleFlowWeb, :controller

  alias PurpleFlow.MCPConnections
  alias PurpleFlowWeb.MCP.ClientDocument
  alias PurpleFlowWeb.MCPController

  @doc "`GET /.well-known/oauth-authorization-server`: where and how apps sign in."
  def metadata(conn, _params) do
    json(conn, %{
      "issuer" => issuer(),
      "authorization_endpoint" => url(~p"/oauth/authorize"),
      "token_endpoint" => url(~p"/oauth/token"),
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "client_id_metadata_document_supported" => true,
      "authorization_response_iss_parameter_supported" => true,
      "scopes_supported" => ["files"]
    })
  end

  @doc "`GET /oauth/authorize`: asks the signed-in person whether to allow the app."
  def authorize(conn, params) do
    case check(params) do
      {:ok, app} ->
        conn
        |> assign(:page_title, "Allow #{app.name}?")
        |> render(:consent, app: app, params: Map.take(params, fields()))

      {:error, why} ->
        refuse(conn, why)
    end
  end

  @doc "`POST /oauth/authorize`: the person's answer. Sends the browser back to the app."
  def decide(conn, %{"decision" => decision} = params) do
    case check(params) do
      {:ok, app} when decision == "allow" ->
        {:ok, code} =
          MCPConnections.allow(%{
            client_id: params["client_id"],
            client_name: app.name,
            redirect_uri: params["redirect_uri"],
            code_challenge: params["code_challenge"]
          })

        back(conn, params, %{"code" => code})

      {:ok, _app} ->
        back(conn, params, %{"error" => "access_denied"})

      {:error, why} ->
        refuse(conn, why)
    end
  end

  def decide(conn, _params), do: refuse(conn, "the form had no answer")

  @doc """
  `POST /oauth/token`: trades a code (`grant_type=authorization_code`) or a
  refresh token (`grant_type=refresh_token`) for new tokens, form-encoded.
  No client secret: an app proves itself with PKCE. Errors are RFC 6749's.
  """
  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    if Enum.all?(~w(code code_verifier client_id redirect_uri), &present?(params[&1])),
      do: tokens(conn, MCPConnections.exchange_code(params)),
      else: token_error(conn, "invalid_request")
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    if present?(params["refresh_token"]),
      do: tokens(conn, MCPConnections.refresh(params)),
      else: token_error(conn, "invalid_request")
  end

  def token(conn, %{"grant_type" => grant}) when is_binary(grant),
    do: token_error(conn, "unsupported_grant_type")

  def token(conn, _params), do: token_error(conn, "invalid_request")

  defp tokens(conn, {:ok, tokens}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      "access_token" => tokens.access_token,
      "token_type" => "Bearer",
      "expires_in" => tokens.expires_in,
      "refresh_token" => tokens.refresh_token,
      "scope" => "files"
    })
  end

  defp tokens(conn, {:error, :invalid_grant}), do: token_error(conn, "invalid_grant")

  defp token_error(conn, error) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(400)
    |> json(%{"error" => error})
  end

  @doc "This server's issuer: the site's own address, as in `iss` and the metadata."
  def issuer, do: PurpleFlowWeb.Endpoint.url()

  defp fields,
    do:
      ~w(response_type client_id redirect_uri code_challenge code_challenge_method state scope resource)

  # The cheap checks first; the app's document is fetched last.
  defp check(params) do
    with :ok <- expect(params["response_type"] == "code", "response_type must be code"),
         :ok <- expect(present?(params["code_challenge"]), "the request has no code_challenge"),
         :ok <-
           expect(params["code_challenge_method"] == "S256", "code_challenge_method must be S256"),
         :ok <-
           expect(resource?(params["resource"]), "resource must be #{MCPController.resource()}"),
         {:ok, app} <- ClientDocument.fetch(params["client_id"]),
         :ok <-
           expect(
             params["redirect_uri"] in app.redirect_uris,
             "the redirect address isn't one the app lists"
           ) do
      {:ok, Map.put(app, :redirect_host, URI.parse(params["redirect_uri"]).host)}
    end
  end

  defp expect(true, _why), do: :ok
  defp expect(_, why), do: {:error, why}

  defp present?(value), do: is_binary(value) and value != ""

  defp resource?(nil), do: true

  defp resource?(resource) when is_binary(resource),
    do: String.trim_trailing(resource, "/") == MCPController.resource()

  defp resource?(_), do: false

  defp back(conn, params, answer) do
    answer = Map.put(answer, "iss", issuer())
    answer = if params["state"], do: Map.put(answer, "state", params["state"]), else: answer
    uri = URI.parse(params["redirect_uri"])
    query = Map.merge(URI.decode_query(uri.query || ""), answer)

    redirect(conn, external: URI.to_string(%{uri | query: URI.encode_query(query)}))
  end

  defp refuse(conn, why) do
    conn
    |> put_status(400)
    |> assign(:page_title, "Can't connect")
    |> render(:refused, why: why)
  end
end
