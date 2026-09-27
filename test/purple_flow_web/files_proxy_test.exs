defmodule PurpleFlowWeb.FilesProxyTest do
  use PurpleFlowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # Not async: sets the admin login and agent token in the environment, and
  # the files service's address in the app's config.

  alias PurpleFlowWeb.Plugs.FilesProxy

  setup do
    System.put_env("PURPLEFLOW_ADMIN_USERNAME", "admin")
    System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "hunter2")
    PurpleFlowWeb.LoginThrottle.reset()
    System.put_env("PURPLEFLOW_AGENT_TOKEN", "agent-token")
    Application.put_env(:purple_flow, :files_url, "http://files:5000")

    on_exit(fn ->
      System.delete_env("PURPLEFLOW_ADMIN_USERNAME")
      System.delete_env("PURPLEFLOW_ADMIN_PASSWORD")
      System.delete_env("PURPLEFLOW_AGENT_TOKEN")
      Application.delete_env(:purple_flow, :files_url)
    end)

    # A stand-in for dufs: sends back what it was sent.
    Req.Test.stub(FilesProxy, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if conn.request_path == "/fs/" and conn.method == "GET" do
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          200,
          ~s(<html><head></head><body><template id="index-data">x</template></body></html>)
        )
      else
        Req.Test.json(conn, %{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string,
          body: body,
          headers: Map.new(conn.req_headers)
        })
      end
    end)

    :ok
  end

  defp signed_in(conn) do
    conn
    |> post(~p"/login", %{"username" => "admin", "password" => "hunter2"})
    |> recycle()
  end

  @dufs_login "Basic " <> Base.encode64("purpleflow:agent-token")

  defp agent(conn), do: put_req_header(conn, "authorization", "Bearer agent-token")

  test "a signed-in browser gets through, without passing on its cookie", %{conn: conn} do
    sent = conn |> signed_in() |> get("/fs/hello/workflow.toml?view") |> json_response(200)
    assert sent["method"] == "GET"
    assert sent["path"] == "/fs/hello/workflow.toml"
    assert sent["query"] == "view"
    refute Map.has_key?(sent["headers"], "cookie")
    assert sent["headers"]["authorization"] == @dufs_login
  end

  test "an agent's token gets through, and dufs gets the app's own login instead",
       %{conn: conn} do
    sent =
      conn
      |> agent()
      |> put_req_header("content-type", "application/json")
      |> put("/fs/hello/data.json", ~s({"not": "parsed"}))
      |> json_response(200)

    assert sent["method"] == "PUT"
    # The body arrives exactly as sent, not parsed by the app.
    assert sent["body"] == ~s({"not": "parsed"})
    assert sent["headers"]["authorization"] == @dufs_login
  end

  test "WebDAV methods and headers pass through", %{conn: conn} do
    sent =
      conn
      |> agent()
      |> put_req_header("destination", "http://localhost/fs/hello/new.toml")
      |> dispatch(@endpoint, "MOVE", "/fs/hello/old.toml")
      |> json_response(200)

    assert sent["method"] == "MOVE"
    assert sent["headers"]["destination"] == "http://localhost/fs/hello/new.toml"
  end

  test "the admin login as Basic auth gets through, for WebDAV clients", %{conn: conn} do
    header = Base.encode64("admin:hunter2")

    conn =
      conn
      |> put_req_header("authorization", "Basic #{header}")
      |> dispatch(@endpoint, "PROPFIND", "/fs/")

    sent = json_response(conn, 200)
    assert sent["method"] == "PROPFIND"
    # Not the admin login: that stays in the app.
    assert sent["headers"]["authorization"] == @dufs_login
  end

  test "no login: a WebDAV client is asked for Basic auth", %{conn: conn} do
    conn = get(conn, "/fs/hello/workflow.toml")
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "no login: a browser is sent to sign in, never a popup", %{conn: conn} do
    conn = conn |> put_req_header("sec-fetch-mode", "navigate") |> get("/fs/hello/")
    assert redirected_to(conn) == "/login?return_to=%2Ffs%2Fhello%2F"
    assert get_resp_header(conn, "www-authenticate") == []

    conn = build_conn() |> put_req_header("sec-fetch-mode", "cors") |> get("/fs/hello/")
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == []
  end

  test "wrong credentials don't get through", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "Bearer nope") |> get("/fs/")
    assert conn.status == 401

    header = Base.encode64("admin:wrong")

    assert build_conn()
           |> put_req_header("authorization", "Basic #{header}")
           |> get("/fs/")
           |> Map.get(:status) == 401
  end

  test "a signed-in session doesn't get through from another site", %{conn: conn} do
    conn =
      conn
      |> signed_in()
      |> put_req_header("sec-fetch-site", "cross-site")
      |> delete("/fs/hello/workflow.toml")

    assert conn.status == 401
  end

  test "dufs's own pages get the app's theme", %{conn: conn} do
    html = conn |> signed_in() |> get("/fs/") |> response(200)
    assert html =~ ~s(<link rel="stylesheet" href="/dufs/theme.css">)
    assert html =~ ~s(<script src="/dufs/embed.js"></script></head>)
  end

  test "without a files service, /fs/ is a 404", %{conn: conn} do
    Application.delete_env(:purple_flow, :files_url)
    conn = conn |> agent() |> get("/fs/")
    assert conn.status == 404
  end

  test "the Files page embeds the folder being shown", %{conn: conn} do
    conn = signed_in(conn)

    {:ok, view, _html} = live(conn, "/files")
    assert has_element?(view, ~s(#files-frame[src="/fs/"]))

    {:ok, view, _html} = live(conn, "/files/hello/workflow.toml?edit")
    assert has_element?(view, ~s(#files-frame[src="/fs/hello/workflow.toml?edit"]))
  end

  test "the Files page says so when there's no files service", %{conn: conn} do
    Application.delete_env(:purple_flow, :files_url)
    {:ok, view, _html} = conn |> signed_in() |> live("/files")
    assert has_element?(view, "#files-unavailable")
    refute has_element?(view, "#files-frame")
  end
end
