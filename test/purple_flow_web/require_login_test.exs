defmodule PurpleFlowWeb.RequireLoginTest do
  use PurpleFlowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # Not async: mutates process env vars that the plug reads per-request.

  setup do
    System.put_env("PURPLEFLOW_ADMIN_USERNAME", "admin")
    System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "hunter2")
    PurpleFlowWeb.LoginThrottle.reset()

    on_exit(fn ->
      System.delete_env("PURPLEFLOW_ADMIN_USERNAME")
      System.delete_env("PURPLEFLOW_ADMIN_PASSWORD")
    end)
  end

  test "GET / sends you to the sign-in page", %{conn: conn} do
    assert conn |> get(~p"/") |> redirected_to() == "/login"
  end

  test "another page sends you to sign in, then back to it", %{conn: conn} do
    assert conn |> get(~p"/credentials") |> redirected_to() == "/login?return_to=%2Fcredentials"
  end

  test "the sign-in page is a real form, not a popup", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ ~s(id="login-form")
    refute get_resp_header(conn, "www-authenticate") != []
    html = html_response(conn, 200)
    assert html =~ ~s(autocomplete="username")
    assert html =~ ~s(autocomplete="current-password")
  end

  test "signing in covers the UI", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "hunter2"})
    assert redirected_to(conn) == "/"

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Workflows"
  end

  test "signing in returns you to where you were going", %{conn: conn} do
    conn =
      post(conn, ~p"/login", %{
        "username" => "admin",
        "password" => "hunter2",
        "return_to" => "/credentials"
      })

    assert redirected_to(conn) == "/credentials"
  end

  test "return_to never leaves the site", %{conn: conn} do
    for target <- ["//evil.example", "https://evil.example", "/\\evil.example", "evil"] do
      conn =
        post(conn, ~p"/login", %{
          "username" => "admin",
          "password" => "hunter2",
          "return_to" => target
        })

      assert redirected_to(conn) == "/"
    end
  end

  test "the wrong password is rejected", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "wrong"})
    assert html_response(conn, 401) =~ ~s(id="login-error")

    conn = conn |> recycle() |> get(~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "Basic auth no longer gets into the UI", %{conn: conn} do
    header = Base.encode64("admin:hunter2")
    conn = conn |> put_req_header("authorization", "Basic #{header}") |> get(~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "signing out ends the session", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "hunter2"})
    conn = conn |> recycle() |> delete(~p"/logout")
    assert redirected_to(conn) == "/login"

    conn = conn |> recycle() |> get(~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "changing the password signs everyone out", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "hunter2"})
    System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "new-password")

    conn = conn |> recycle() |> get(~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "a LiveView won't mount without a signed-in session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, ~p"/credentials")

    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "hunter2"})
    assert {:ok, _view, _html} = conn |> recycle() |> live(~p"/credentials")
  end

  test "signed in, the sign-in page sends you on", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"username" => "admin", "password" => "hunter2"})
    assert conn |> recycle() |> get(~p"/login") |> redirected_to() == "/"
  end

  test "GET /health needs no login and says only ok", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end

  test "webhooks don't require a login", %{conn: conn} do
    conn = get(conn, "/hooks/nonexistent-path")
    assert conn.status == 404
  end
end
