defmodule PurpleFlowWeb.MCPControllerTest do
  use PurpleFlowWeb.ConnCase, async: false

  # Not async: sets the agent token in the environment and the files
  # service's address in the app's config.

  alias PurpleFlowWeb.Plugs.FilesProxy

  @modern "2026-07-28"

  setup do
    System.put_env("PURPLEFLOW_AGENT_TOKEN", "agent-token")
    Application.put_env(:purple_flow, :files_url, "http://files:5000")

    on_exit(fn ->
      System.delete_env("PURPLEFLOW_AGENT_TOKEN")
      Application.delete_env(:purple_flow, :files_url)
    end)

    test = self()

    Req.Test.stub(FilesProxy, fn conn ->
      send(test, {:dufs, conn.method, conn.request_path})
      Req.Test.json(conn, %{"paths" => []})
    end)

    :ok
  end

  defp agent(conn), do: put_req_header(conn, "authorization", "Bearer agent-token")

  defp post_rpc(conn, message, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post(~p"/mcp", Jason.encode!(message))
  end

  # An older-generation request: no version in _meta.
  defp legacy(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  # A newer-generation request, and the headers that go with it.
  defp modern(method, params \\ %{}) do
    meta = %{"io.modelcontextprotocol/protocolVersion" => @modern}

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp modern_headers(method, name \\ nil) do
    [{"mcp-protocol-version", @modern}, {"mcp-method", method}] ++
      if(name, do: [{"mcp-name", name}], else: [])
  end

  describe "signing in" do
    test "without a token is 401 with a challenge naming the resource metadata, and dufs gets nothing",
         %{conn: conn} do
      conn =
        post_rpc(conn, legacy("tools/call", %{"name" => "list", "arguments" => %{"path" => ""}}))

      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="http://localhost:4000/.well-known/oauth-protected-resource/mcp")
             ]

      refute_received {:dufs, _, _}
    end

    test "a wrong token is 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer nope")
        |> post_rpc(legacy("ping"))

      assert conn.status == 401
    end

    test "the agent token gets through", %{conn: conn} do
      assert %{"result" => %{}} =
               conn |> agent() |> post_rpc(legacy("ping")) |> json_response(200)
    end
  end

  describe "the older generation" do
    test "initialize answers with the version asked for, when it's one this server speaks",
         %{conn: conn} do
      body =
        conn
        |> agent()
        |> post_rpc(legacy("initialize", %{"protocolVersion" => "2025-06-18"}))
        |> json_response(200)

      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["capabilities"] == %{"tools" => %{}}
      assert body["result"]["serverInfo"]["name"] == "PurpleFlow"
    end

    test "initialize with a version it doesn't speak answers with 2025-11-25, and no session",
         %{conn: conn} do
      conn =
        conn |> agent() |> post_rpc(legacy("initialize", %{"protocolVersion" => "2024-11-05"}))

      assert json_response(conn, 200)["result"]["protocolVersion"] == "2025-11-25"
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "a notification is 202 with no body", %{conn: conn} do
      conn =
        conn
        |> agent()
        |> post_rpc(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "tools/list lists the tools", %{conn: conn} do
      body = conn |> agent() |> post_rpc(legacy("tools/list")) |> json_response(200)
      assert length(body["result"]["tools"]) == 11
    end

    test "tools/call runs the tool against dufs", %{conn: conn} do
      body =
        conn
        |> agent()
        |> post_rpc(
          legacy("tools/call", %{"name" => "list", "arguments" => %{"path" => "hello"}})
        )
        |> json_response(200)

      assert body["result"]["structuredContent"] == %{"entries" => []}
      assert_received {:dufs, "GET", "/fs/hello/"}
    end

    test "an unknown method is -32601, with 200", %{conn: conn} do
      body = conn |> agent() |> post_rpc(legacy("resources/list")) |> json_response(200)
      assert body["error"]["code"] == -32601
    end
  end

  describe "the newer generation" do
    test "server/discover lists the versions and the tools capability", %{conn: conn} do
      body =
        conn
        |> agent()
        |> post_rpc(modern("server/discover"), modern_headers("server/discover"))
        |> json_response(200)

      assert body["result"]["supportedVersions"] == ["2026-07-28", "2025-11-25", "2025-06-18"]
      assert body["result"]["capabilities"] == %{"tools" => %{}}
      assert body["result"]["resultType"] == "complete"
      assert body["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "PurpleFlow"
      assert body["result"]["ttlMs"] == 3_600_000
      assert body["result"]["cacheScope"] == "private"
    end

    test "tools/list lists the tools, with how long to cache them", %{conn: conn} do
      result =
        conn
        |> agent()
        |> post_rpc(modern("tools/list"), modern_headers("tools/list"))
        |> json_response(200)
        |> Map.fetch!("result")

      assert length(result["tools"]) == 11
      assert result["resultType"] == "complete"
      assert result["ttlMs"] == 3_600_000
      assert result["cacheScope"] == "private"
    end

    test "tools/call runs the tool", %{conn: conn} do
      params = %{"name" => "list", "arguments" => %{"path" => ""}}

      result =
        conn
        |> agent()
        |> post_rpc(modern("tools/call", params), modern_headers("tools/call", "list"))
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["structuredContent"] == %{"entries" => []}
      assert result["resultType"] == "complete"
      assert_received {:dufs, "GET", "/fs/"}
    end

    test "a tool name sent in base64 is decoded before it's compared", %{conn: conn} do
      params = %{"name" => "list", "arguments" => %{"path" => ""}}
      headers = modern_headers("tools/call", "=?base64?" <> Base.encode64("list") <> "?=")

      assert %{"result" => _} =
               conn
               |> agent()
               |> post_rpc(modern("tools/call", params), headers)
               |> json_response(200)
    end

    test "a missing or mismatched header is 400 with -32020, and nothing runs", %{conn: conn} do
      params = %{"name" => "list", "arguments" => %{"path" => ""}}

      for headers <- [
            [],
            [
              {"mcp-protocol-version", "2025-11-25"},
              {"mcp-method", "tools/call"},
              {"mcp-name", "list"}
            ],
            [
              {"mcp-protocol-version", @modern},
              {"mcp-method", "tools/list"},
              {"mcp-name", "list"}
            ],
            [{"mcp-protocol-version", @modern}, {"mcp-method", "tools/call"}],
            [
              {"mcp-protocol-version", @modern},
              {"mcp-method", "tools/call"},
              {"mcp-name", "delete"}
            ]
          ] do
        body =
          conn |> agent() |> post_rpc(modern("tools/call", params), headers) |> json_response(400)

        assert body["error"]["code"] == -32020
      end

      refute_received {:dufs, _, _}
    end

    test "a version this server doesn't speak is 400 with -32022 and the supported list",
         %{conn: conn} do
      message =
        put_in(
          modern("tools/list")["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
          "1900-01-01"
        )

      headers = [{"mcp-protocol-version", "1900-01-01"}, {"mcp-method", "tools/list"}]
      body = conn |> agent() |> post_rpc(message, headers) |> json_response(400)

      assert body["error"]["code"] == -32022

      assert body["error"]["data"] == %{
               "supported" => ["2026-07-28", "2025-11-25", "2025-06-18"],
               "requested" => "1900-01-01"
             }
    end

    test "an unknown method is 404 with -32601", %{conn: conn} do
      body =
        conn
        |> agent()
        |> post_rpc(modern("resources/list"), modern_headers("resources/list"))
        |> json_response(404)

      assert body["error"]["code"] == -32601
    end
  end

  describe "bad calls" do
    test "an unknown tool or a missing argument is -32602", %{conn: conn} do
      for params <- [
            %{"name" => "rm_rf", "arguments" => %{}},
            %{"name" => "write", "arguments" => %{"path" => "a"}}
          ] do
        body = conn |> agent() |> post_rpc(legacy("tools/call", params)) |> json_response(200)
        assert body["error"]["code"] == -32602
      end
    end

    test "a newer-generation call to an unknown tool is -32602, with 200", %{conn: conn} do
      params = %{"name" => "rm_rf", "arguments" => %{}}

      body =
        conn
        |> agent()
        |> post_rpc(modern("tools/call", params), modern_headers("tools/call", "rm_rf"))
        |> json_response(200)

      assert body["error"]["code"] == -32602
    end

    test "a tool call without a name is -32602", %{conn: conn} do
      body = conn |> agent() |> post_rpc(legacy("tools/call", %{})) |> json_response(200)
      assert body["error"]["code"] == -32602
    end

    test "a body that isn't JSON-RPC is 400 with -32600", %{conn: conn} do
      for message <- [%{"hello" => "there"}, [legacy("ping"), legacy("ping")]] do
        body = conn |> agent() |> post_rpc(message) |> json_response(400)
        assert body["error"]["code"] == -32600
      end
    end

    test "GET and DELETE are 405", %{conn: conn} do
      assert conn |> agent() |> get(~p"/mcp") |> response(405)
      assert conn |> agent() |> delete(~p"/mcp") |> response(405)
    end

    test "an Origin from another site is 403; this site's own is fine", %{conn: conn} do
      refused =
        conn
        |> agent()
        |> put_req_header("origin", "https://evil.example")
        |> post_rpc(legacy("ping"))

      assert refused.status == 403

      allowed =
        build_conn()
        |> agent()
        |> put_req_header("origin", "http://localhost:4000")
        |> post_rpc(legacy("ping"))

      assert allowed.status == 200
    end
  end

  describe "the protected resource metadata" do
    test "is public, and names this site's /mcp and its authorization server", %{conn: conn} do
      for path <- [
            "/.well-known/oauth-protected-resource/mcp",
            "/.well-known/oauth-protected-resource"
          ] do
        assert build_conn() |> get(path) |> json_response(200) == %{
                 "resource" => "http://localhost:4000/mcp",
                 "authorization_servers" => ["http://localhost:4000"],
                 "scopes_supported" => ["files"],
                 "bearer_methods_supported" => ["header"],
                 "resource_name" => "PurpleFlow"
               }
      end

      _ = conn
    end
  end
end
