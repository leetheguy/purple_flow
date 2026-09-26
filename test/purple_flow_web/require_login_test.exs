defmodule PurpleFlowWeb.RequireLoginTest do
  use PurpleFlowWeb.ConnCase, async: false

  # Not async: mutates process env vars that the plug reads per-request.

  setup do
    System.put_env("PURPLEFLOW_ADMIN_USERNAME", "admin")
    System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "hunter2")

    on_exit(fn ->
      System.delete_env("PURPLEFLOW_ADMIN_USERNAME")
      System.delete_env("PURPLEFLOW_ADMIN_PASSWORD")
    end)
  end

  test "GET / requires basic auth", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert conn.status == 401
  end

  test "GET / succeeds with the right credentials", %{conn: conn} do
    conn = conn |> put_basic_auth("admin", "hunter2") |> get(~p"/")
    assert html_response(conn, 200)
  end

  test "GET /health needs no login and says only ok", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end

  test "GET /credentials requires basic auth", %{conn: conn} do
    conn = get(conn, ~p"/credentials")
    assert conn.status == 401
  end

  test "the wrong password is rejected", %{conn: conn} do
    conn = conn |> put_basic_auth("admin", "wrong") |> get(~p"/")
    assert conn.status == 401
  end

  test "webhooks don't require basic auth", %{conn: conn} do
    conn = get(conn, "/hooks/nonexistent-path")
    refute conn.status == 401
  end

  defp put_basic_auth(conn, username, password) do
    header = Base.encode64("#{username}:#{password}")
    Plug.Conn.put_req_header(conn, "authorization", "Basic #{header}")
  end
end
