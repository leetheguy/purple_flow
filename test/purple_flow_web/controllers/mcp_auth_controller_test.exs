defmodule PurpleFlowWeb.MCPAuthControllerTest do
  use PurpleFlowWeb.ConnCase, async: false

  # Not async: sets the admin login in the environment.

  alias PurpleFlow.MCPConnections
  alias PurpleFlowWeb.MCP.ClientDocument

  @client "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @redirect "https://claude.ai/api/mcp/auth_callback"
  @verifier String.duplicate("v", 43)
  @base "http://localhost:4000"

  setup do
    System.put_env("PURPLEFLOW_ADMIN_USERNAME", "admin")
    System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "hunter2")
    PurpleFlowWeb.LoginThrottle.reset()

    on_exit(fn ->
      System.delete_env("PURPLEFLOW_ADMIN_USERNAME")
      System.delete_env("PURPLEFLOW_ADMIN_PASSWORD")
    end)

    serve(%{"client_id" => @client, "client_name" => "Claude", "redirect_uris" => [@redirect]})
    :ok
  end

  defp serve(document), do: Req.Test.stub(ClientDocument, &Req.Test.json(&1, document))

  defp challenge, do: Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => @client,
        "redirect_uri" => @redirect,
        "code_challenge" => challenge(),
        "code_challenge_method" => "S256",
        "state" => "abc123",
        "scope" => "files",
        "resource" => @base <> "/mcp"
      },
      overrides
    )
  end

  defp signed_in(conn) do
    conn
    |> post(~p"/login", %{"username" => "admin", "password" => "hunter2"})
    |> recycle()
  end

  defp query(conn) do
    [location] = get_resp_header(conn, "location")
    uri = URI.parse(location)
    {"#{uri.scheme}://#{uri.host}#{uri.path}", URI.decode_query(uri.query || "")}
  end

  describe "the authorization server metadata" do
    test "is public and says where and how to sign in", %{conn: conn} do
      assert conn |> get("/.well-known/oauth-authorization-server") |> json_response(200) == %{
               "issuer" => @base,
               "authorization_endpoint" => @base <> "/oauth/authorize",
               "token_endpoint" => @base <> "/oauth/token",
               "response_types_supported" => ["code"],
               "grant_types_supported" => ["authorization_code", "refresh_token"],
               "code_challenge_methods_supported" => ["S256"],
               "token_endpoint_auth_methods_supported" => ["none"],
               "client_id_metadata_document_supported" => true,
               "authorization_response_iss_parameter_supported" => true,
               "scopes_supported" => ["files"]
             }
    end
  end

  describe "asking to connect" do
    test "someone not signed in is sent to sign in, and back to the same request", %{conn: conn} do
      conn = get(conn, ~p"/oauth/authorize?#{params()}")
      [location] = get_resp_header(conn, "location")
      %{"return_to" => return_to} = URI.decode_query(URI.parse(location).query)

      assert URI.parse(location).path == "/login"
      assert URI.parse(return_to).path == "/oauth/authorize"
      assert URI.decode_query(URI.parse(return_to).query) == params()
    end

    test "shows the app's name and where it will be sent back to", %{conn: conn} do
      html = conn |> signed_in() |> get(~p"/oauth/authorize?#{params()}") |> html_response(200)

      assert html =~ "Claude"
      assert html =~ "claude.ai"
      assert html =~ "Allow"
      assert html =~ "Deny"
    end

    test "an app whose document doesn't load is refused, with nothing sent back", %{conn: conn} do
      Req.Test.stub(ClientDocument, &Plug.Conn.send_resp(&1, 404, ""))

      conn = conn |> signed_in() |> get(~p"/oauth/authorize?#{params()}")

      assert html_response(conn, 400) =~ "answered 404"
      assert get_resp_header(conn, "location") == []
    end

    test "a bad request is refused, with nothing sent back", %{conn: conn} do
      conn = signed_in(conn)

      for {overrides, says} <- [
            {%{"redirect_uri" => "https://evil.example/cb"}, "redirect"},
            {%{"code_challenge" => nil}, "code_challenge"},
            {%{"code_challenge_method" => "plain"}, "S256"},
            {%{"response_type" => "token"}, "response_type"},
            {%{"resource" => "https://other.example/mcp"}, "resource"},
            {%{"resource" => [@base <> "/mcp"]}, "text"}
          ] do
        params = params(overrides) |> Map.reject(fn {_, v} -> is_nil(v) end)
        conn = get(conn, ~p"/oauth/authorize?#{params}")

        assert html_response(conn, 400) =~ says
        assert get_resp_header(conn, "location") == []
      end
    end

    test "a field sent as a list or a map is refused, not a crash", %{conn: conn} do
      conn = signed_in(conn)
      query = URI.encode_query(params()) <> "&state[x]=1"

      assert conn |> get("/oauth/authorize?" <> query) |> html_response(400) =~ "text"

      decided =
        post(
          conn,
          ~p"/oauth/authorize",
          Map.merge(params(), %{"state" => ["a"], "decision" => "allow"})
        )

      assert html_response(decided, 400) =~ "text"
      assert MCPConnections.list() == []
    end

    test "resource can be left out, or end in a slash", %{conn: conn} do
      conn = signed_in(conn)

      assert conn
             |> get(~p"/oauth/authorize?#{Map.delete(params(), "resource")}")
             |> html_response(200)

      assert conn
             |> get(~p"/oauth/authorize?#{params(%{"resource" => @base <> "/mcp/"})}")
             |> html_response(200)
    end
  end

  describe "deciding" do
    test "Allow sends a working code back, with the same state and iss", %{conn: conn} do
      conn =
        conn |> signed_in() |> post(~p"/oauth/authorize", Map.put(params(), "decision", "allow"))

      assert {@redirect, %{"code" => code, "state" => "abc123", "iss" => @base}} = query(conn)

      assert {:ok, _} =
               MCPConnections.exchange_code(%{
                 "code" => code,
                 "code_verifier" => @verifier,
                 "client_id" => @client,
                 "redirect_uri" => @redirect
               })

      assert [%{client_name: "Claude"}] = MCPConnections.list()
    end

    test "Deny sends access_denied back, and nothing is saved", %{conn: conn} do
      conn =
        conn |> signed_in() |> post(~p"/oauth/authorize", Map.put(params(), "decision", "deny"))

      assert {@redirect, %{"error" => "access_denied", "state" => "abc123", "iss" => @base}} =
               query(conn)

      assert PurpleFlow.Repo.aggregate(PurpleFlow.MCPConnections.Connection, :count) == 0
    end

    test "a decision on a bad request is refused the same way", %{conn: conn} do
      conn =
        conn
        |> signed_in()
        |> post(
          ~p"/oauth/authorize",
          params(%{"redirect_uri" => "https://evil.example/cb", "decision" => "allow"})
        )

      assert html_response(conn, 400) =~ "redirect"
      assert get_resp_header(conn, "location") == []
    end

    test "Allow without the page's CSRF token does nothing", %{conn: conn} do
      conn =
        conn
        |> signed_in()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

      assert_error_sent 403, fn ->
        post(conn, ~p"/oauth/authorize", Map.put(params(), "decision", "allow"))
      end

      assert MCPConnections.list() == []
    end
  end

  describe "trading for tokens" do
    defp allowed_code(conn) do
      conn =
        conn |> signed_in() |> post(~p"/oauth/authorize", Map.put(params(), "decision", "allow"))

      {_, %{"code" => code}} = query(conn)
      code
    end

    defp token_request(conn, form), do: post(conn, ~p"/oauth/token", form)

    defp code_form(code, overrides \\ %{}) do
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "code_verifier" => @verifier,
          "client_id" => @client,
          "redirect_uri" => @redirect
        },
        overrides
      )
    end

    test "the right code and verifier get tokens that work at /mcp", %{conn: conn} do
      code = allowed_code(conn)
      conn = token_request(build_conn(), code_form(code))
      body = json_response(conn, 200)

      assert %{"token_type" => "Bearer", "expires_in" => 3600, "scope" => "files"} = body
      assert is_binary(body["access_token"]) and is_binary(body["refresh_token"])
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      reply =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> body["access_token"])
        |> put_req_header("content-type", "application/json")
        |> post(~p"/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))
        |> json_response(200)

      assert reply["result"] == %{}
    end

    test "a wrong verifier, or a used code, is invalid_grant", %{conn: conn} do
      code = allowed_code(conn)

      wrong =
        token_request(
          build_conn(),
          code_form(code, %{"code_verifier" => String.duplicate("w", 43)})
        )

      assert json_response(wrong, 400) == %{"error" => "invalid_grant"}

      code = allowed_code(build_conn())
      assert build_conn() |> token_request(code_form(code)) |> json_response(200)
      used = token_request(build_conn(), code_form(code))
      assert json_response(used, 400) == %{"error" => "invalid_grant"}
    end

    test "a refresh token gets new tokens; the old one then fails", %{conn: conn} do
      code = allowed_code(conn)

      %{"refresh_token" => refresh} =
        build_conn() |> token_request(code_form(code)) |> json_response(200)

      form = %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh,
        "client_id" => @client
      }

      body = build_conn() |> token_request(form) |> json_response(200)

      assert %{"token_type" => "Bearer", "expires_in" => 3600, "scope" => "files"} = body
      assert body["refresh_token"] != refresh

      assert build_conn() |> token_request(form) |> json_response(400) == %{
               "error" => "invalid_grant"
             }
    end

    test "a missing field is invalid_request", %{conn: conn} do
      for form <- [
            %{},
            Map.delete(code_form("c"), "code"),
            Map.delete(code_form("c"), "code_verifier"),
            Map.delete(code_form("c"), "client_id"),
            Map.delete(code_form("c"), "redirect_uri"),
            %{"grant_type" => "refresh_token"}
          ] do
        assert conn |> token_request(form) |> json_response(400) == %{
                 "error" => "invalid_request"
               }
      end
    end

    test "an unknown grant type is unsupported_grant_type", %{conn: conn} do
      assert conn |> token_request(%{"grant_type" => "password"}) |> json_response(400) ==
               %{"error" => "unsupported_grant_type"}
    end
  end
end
