defmodule PurpleFlowWeb.LoginThrottleTest do
  use PurpleFlowWeb.ConnCase, async: false

  # Not async: sets the admin login in the environment, and lockouts are
  # shared by every test from 127.0.0.1.

  alias PurpleFlowWeb.LoginThrottle

  setup do
    System.put_env("PURPLEFLOW_ADMIN_USERNAME", "admin")
    System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "hunter2")
    LoginThrottle.reset()

    on_exit(fn ->
      System.delete_env("PURPLEFLOW_ADMIN_USERNAME")
      System.delete_env("PURPLEFLOW_ADMIN_PASSWORD")
      Application.delete_env(:purple_flow, :client_ip_header)
      LoginThrottle.reset()
    end)
  end

  defp sign_in(conn \\ build_conn(), password) do
    post(conn, ~p"/login", %{"username" => "admin", "password" => password})
  end

  test "3 failures lock the address out, even for the right password" do
    assert sign_in("wrong").status == 401
    assert sign_in("wrong").status == 401

    conn = sign_in("wrong")
    assert conn.status == 429
    assert html_response(conn, 429) =~ ~s(id="login-error")

    assert sign_in("hunter2").status == 429
  end

  test "a success clears the count" do
    sign_in("wrong")
    sign_in("wrong")
    assert redirected_to(sign_in("hunter2")) == "/"

    assert sign_in("wrong").status == 401
    assert sign_in("wrong").status == 401
  end

  test "other addresses aren't locked out" do
    for _ <- 1..3, do: sign_in("wrong")

    conn = %{build_conn() | remote_ip: {192, 0, 2, 7}}
    assert redirected_to(sign_in(conn, "hunter2")) == "/"
  end

  test "a lockout ends after 4 hours" do
    for _ <- 1..3, do: sign_in("wrong")
    now = System.monotonic_time(:millisecond)

    assert LoginThrottle.locked?("127.0.0.1", now + 4 * 60 * 60 * 1000 - 60_000)
    refute LoginThrottle.locked?("127.0.0.1", now + 4 * 60 * 60 * 1000 + 60_000)
  end

  test "Basic auth on /fs/ counts, and is locked out too" do
    Application.put_env(:purple_flow, :files_url, "http://files:5000")
    on_exit(fn -> Application.delete_env(:purple_flow, :files_url) end)
    Req.Test.stub(PurpleFlowWeb.Plugs.FilesProxy, &Plug.Conn.send_resp(&1, 200, "ok"))

    basic = fn password ->
      build_conn()
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:" <> password))
      |> get("/fs/")
    end

    for _ <- 1..3, do: assert(basic.("wrong").status == 401)
    assert basic.("hunter2").status == 401
    assert sign_in("hunter2").status == 429
  end

  test "behind a proxy, the configured header is the client's address" do
    Application.put_env(:purple_flow, :client_ip_header, "x-forwarded-for")

    via_proxy = fn client ->
      put_req_header(build_conn(), "x-forwarded-for", "203.0.113.9, #{client}")
    end

    for _ <- 1..3, do: sign_in(via_proxy.("198.51.100.1"), "wrong")

    assert sign_in(via_proxy.("198.51.100.1"), "hunter2").status == 429
    # Same proxy, different visitor: not locked out.
    assert redirected_to(sign_in(via_proxy.("198.51.100.2"), "hunter2")) == "/"
  end
end
