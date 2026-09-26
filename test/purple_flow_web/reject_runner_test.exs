defmodule PurpleFlowWeb.RejectRunnerTest do
  # config/test.exs sets the runner subnet to 10.250.250.0/24.
  use PurpleFlowWeb.ConnCase, async: true

  defp from(conn, ip), do: %{conn | remote_ip: ip}

  test "a request from the runner's network is refused, whatever it asks for", %{conn: conn} do
    for path <- ["/", "/hooks/echo", "/health", "/live/websocket", "/credentials"] do
      assert conn |> from({10, 250, 250, 7}) |> get(path) |> response(403) == ""
    end
  end

  test "an IPv4 address seen through an IPv6 listener is still refused", %{conn: conn} do
    # ::ffff:10.250.250.7
    ip = {0, 0, 0, 0, 0, 0xFFFF, 0x0AFA, 0xFA07}
    assert conn |> from(ip) |> get("/health") |> response(403)
  end

  test "a request from anywhere else goes through", %{conn: conn} do
    assert conn |> from({10, 250, 251, 7}) |> get("/health") |> response(200) == "ok"
    assert conn |> from({0, 0, 0, 0, 0, 0, 0, 1}) |> get("/health") |> response(200) == "ok"
  end
end
