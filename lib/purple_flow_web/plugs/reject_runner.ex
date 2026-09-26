defmodule PurpleFlowWeb.Plugs.RejectRunner do
  @moduledoc """
  Refuses every request from the Code node runner's network
  (`config :purple_flow, :runner_subnet`, a CIDR like "10.250.250.0/24").

  The app and the runner share that network so the app can reach the
  runner, but a script must never reach the app back: not its webhooks, not
  its UI, not its LiveView socket. `PurpleFlowWeb.Endpoint` calls this before
  anything else, sockets included. See `specs/070_code_sandbox.md`.

  Without a configured subnet (dev and test, where the runner is in-VM),
  nothing is refused.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if from_runner?(conn.remote_ip) do
      conn |> send_resp(403, "") |> halt()
    else
      conn
    end
  end

  @doc "Whether `ip` is in the runner's subnet."
  def from_runner?(ip) do
    case Application.get_env(:purple_flow, :runner_subnet) do
      nil -> false
      subnet -> in_subnet?(ipv4(ip), parse(subnet))
    end
  end

  # An IPv4 client of a server listening on IPv6 shows up as ::ffff:a.b.c.d.
  defp ipv4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}

  defp ipv4(ip), do: ip

  defp parse(cidr) do
    [address, bits] = String.split(cidr, "/", parts: 2)
    {:ok, network} = :inet.parse_address(to_charlist(address))
    {network, String.to_integer(bits)}
  end

  defp in_subnet?({_, _, _, _} = ip, {{_, _, _, _} = network, bits}),
    do: prefix(ip, bits) == prefix(network, bits)

  defp in_subnet?(_ip, _subnet), do: false

  defp prefix({a, b, c, d}, bits) do
    <<prefix::bitstring-size(^bits), _::bitstring>> = <<a, b, c, d>>
    prefix
  end
end
