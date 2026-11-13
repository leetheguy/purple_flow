defmodule PurpleFlowWeb.MCP.ClientDocumentTest do
  use ExUnit.Case, async: true

  alias PurpleFlowWeb.MCP.ClientDocument

  @client "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @redirect "https://claude.ai/api/mcp/auth_callback"

  defp serve(fun) do
    test = self()

    Req.Test.stub(ClientDocument, fn conn ->
      send(test, {:fetched, conn.method, conn.host, conn.request_path})
      fun.(conn)
    end)
  end

  defp document(overrides \\ %{}) do
    Map.merge(
      %{"client_id" => @client, "client_name" => "Claude", "redirect_uris" => [@redirect]},
      overrides
    )
  end

  test "fetches the document and returns the app's name and redirect addresses" do
    serve(&Req.Test.json(&1, document()))

    assert ClientDocument.fetch(@client) == {:ok, %{name: "Claude", redirect_uris: [@redirect]}}
    assert_received {:fetched, "GET", "claude.ai", "/oauth/mcp-oauth-client-metadata"}
  end

  test "an app with no name is named after its host" do
    serve(&Req.Test.json(&1, Map.delete(document(), "client_name")))
    assert {:ok, %{name: "claude.ai"}} = ClientDocument.fetch(@client)

    serve(&Req.Test.json(&1, document(%{"client_name" => ""})))
    assert {:ok, %{name: "claude.ai"}} = ClientDocument.fetch(@client)
  end

  test "a client_id that isn't an https address is refused without fetching" do
    serve(&Req.Test.json(&1, document()))

    for client <- ["http://claude.ai/c", "claude", "https://", nil] do
      assert {:error, _} = ClientDocument.fetch(client)
    end

    refute_received {:fetched, _, _, _}
  end

  test "a document that names another client_id is refused" do
    serve(&Req.Test.json(&1, document(%{"client_id" => "https://evil.example/c"})))
    assert {:error, why} = ClientDocument.fetch(@client)
    assert why =~ "client_id"
  end

  test "a document without redirect addresses is refused" do
    for bad <- [nil, [], "https://claude.ai/cb", [7]] do
      serve(&Req.Test.json(&1, document(%{"redirect_uris" => bad})))
      assert {:error, _} = ClientDocument.fetch(@client)
    end
  end

  test "a redirect isn't followed" do
    serve(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.example/c")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, why} = ClientDocument.fetch(@client)
    assert why =~ "302"
    assert_received {:fetched, _, "claude.ai", _}
    refute_received {:fetched, _, "evil.example", _}
  end

  test "a document over 5 KB is refused" do
    serve(&Req.Test.json(&1, document(%{"padding" => String.duplicate("x", 5_200)})))
    assert {:error, why} = ClientDocument.fetch(@client)
    assert why =~ "5 KB"
  end

  test "a document of exactly 5 KB is fine" do
    body = Jason.encode!(document(%{"padding" => ""}))
    body = Jason.encode!(document(%{"padding" => String.duplicate("x", 5_120 - byte_size(body))}))
    assert byte_size(body) == 5_120

    serve(
      &(&1
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body))
    )

    assert {:ok, _} = ClientDocument.fetch(@client)
  end

  test "something that isn't JSON, or can't be reached, is refused" do
    serve(&Plug.Conn.send_resp(&1, 200, "<html>"))
    assert {:error, _} = ClientDocument.fetch(@client)

    serve(&Req.Test.transport_error(&1, :timeout))
    assert {:error, why} = ClientDocument.fetch(@client)
    assert why =~ "couldn't"
  end
end
