defmodule PurpleFlowWeb.MCPController do
  @moduledoc """
  `/mcp`: the MCP endpoint, so Claude and other MCP clients can reach the
  workflows folder (`PurpleFlowWeb.MCP.Server`, `PurpleFlowWeb.MCP.Tools`).
  And the protected resource metadata, which tells a client where to sign
  in. See [specs/270](specs/270_mcp_files.md).

  A request needs `Authorization: Bearer <token>`: an access token from
  signing in (`PurpleFlow.MCPConnections`), or `PURPLEFLOW_AGENT_TOKEN`.
  Without one, the answer is 401 with a `WWW-Authenticate` header pointing at the
  metadata ([RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)).
  """

  use PurpleFlowWeb, :controller

  alias PurpleFlow.MCPConnections
  alias PurpleFlowWeb.Auth
  alias PurpleFlowWeb.MCP.Server

  @doc "`POST /mcp`: one JSON-RPC message in, one answer out."
  def handle(conn, _params) do
    cond do
      foreign_origin?(conn) ->
        send_resp(conn, 403, "")

      not authorized?(conn) ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer resource_metadata="#{metadata_url()}"))
        |> send_resp(401, "")

      true ->
        case Server.handle(conn.body_params, mcp_headers(conn)) do
          {status, nil} -> send_resp(conn, status, "")
          {status, body} -> conn |> put_status(status) |> json(body)
        end
    end
  end

  @doc "`GET` or `DELETE /mcp`: 405. This server keeps no streams or sessions to open or close."
  def not_allowed(conn, _params) do
    conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
  end

  @doc "`GET /.well-known/oauth-protected-resource[/mcp]`: what `/mcp` is, and who signs clients in for it."
  def resource_metadata(conn, _params) do
    json(conn, %{
      "resource" => resource(),
      "authorization_servers" => [PurpleFlowWeb.Endpoint.url()],
      "scopes_supported" => ["files"],
      "bearer_methods_supported" => ["header"],
      "resource_name" => "PurpleFlow"
    })
  end

  @doc "This server's MCP address, `https://<host>/mcp`: what a person pastes into Claude."
  def resource, do: url(~p"/mcp")

  defp metadata_url, do: url(~p"/.well-known/oauth-protected-resource/mcp")

  defp authorized?(conn) do
    Auth.agent?(conn) or
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> match?({:ok, _}, MCPConnections.verify_access(token))
        _ -> false
      end
  end

  # MCP requires refusing a page on another site that tries to reach the
  # endpoint through a browser (DNS rebinding). Claude's own requests come
  # from its servers and send no Origin.
  defp foreign_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> false
      [origin | _] -> origin != PurpleFlowWeb.Endpoint.url()
    end
  end

  defp mcp_headers(conn) do
    for name <- ~w(mcp-protocol-version mcp-method mcp-name),
        [value | _] <- [get_req_header(conn, name)],
        into: %{},
        do: {name, value}
  end
end
