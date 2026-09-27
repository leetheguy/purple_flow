defmodule PurpleFlow.Test.SshServer.Channel do
  @moduledoc "One session on the test SSH server. See `PurpleFlow.Test.SshServer`."

  @behaviour :ssh_server_channel

  @impl true
  def init([handler, test]),
    do: {:ok, %{handler: handler, test: test, command: nil, stdin: [], channel: nil}}

  @impl true
  def handle_msg({:ssh_channel_up, channel, _conn}, state), do: {:ok, %{state | channel: channel}}
  def handle_msg(_message, state), do: {:ok, state}

  @impl true
  def handle_ssh_msg({:ssh_cm, conn, {:exec, channel, want_reply, command}}, state) do
    :ssh_connection.reply_request(conn, want_reply, :success, channel)
    {:ok, %{state | command: to_string(command)}}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:data, _channel, 0, data}}, state),
    do: {:ok, %{state | stdin: [state.stdin | data]}}

  # The client is done sending: run the command.
  def handle_ssh_msg({:ssh_cm, conn, {:eof, channel}}, state) do
    actions = state.handler.(state.command, IO.iodata_to_binary(state.stdin))
    Enum.each(actions, &act(conn, channel, &1, state.test))
    if {:hang} in actions, do: {:ok, state}, else: done(conn, channel, actions, state)
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:closed, channel}}, state), do: {:stop, channel, state}
  def handle_ssh_msg(_message, state), do: {:ok, state}

  defp done(conn, channel, actions, state) do
    unless Enum.any?(actions, &match?({:signal, _}, &1)) do
      status = Enum.find_value(actions, 0, fn a -> match?({:exit, _}, a) && elem(a, 1) end)
      :ssh_connection.exit_status(conn, channel, status)
    end

    :ssh_connection.send_eof(conn, channel)
    {:stop, channel, state}
  end

  @impl true
  def terminate(_reason, state) do
    send(state.test, {:ssh_channel_closed, state.command})
    :ok
  end

  defp act(conn, channel, {:out, data}, _test), do: :ssh_connection.send(conn, channel, 0, data)
  defp act(conn, channel, {:err, data}, _test), do: :ssh_connection.send(conn, channel, 1, data)
  defp act(_conn, _channel, {:sleep, ms}, _test), do: Process.sleep(ms)
  defp act(_conn, _channel, {:exit, _status}, _test), do: :ok
  defp act(_conn, _channel, {:hang}, _test), do: :ok

  defp act(_conn, _channel, {:wait}, test) do
    send(test, {:waiting, self()})
    receive do: (:go -> :ok)
  end

  defp act(conn, channel, {:signal, name}, _test) do
    # :ssh_connection has no call for this; it's the same request by hand.
    :ssh_connection_handler.request(
      conn,
      channel,
      ~c"exit-signal",
      false,
      <<byte_size(name)::32, name::binary, 0, 0::32, 0::32>>,
      0
    )
  end
end
