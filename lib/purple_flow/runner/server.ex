defmodule PurpleFlow.Runner.Server do
  @moduledoc """
  The Code node runner: accepts a script and its `input`/`steps` over TCP,
  evaluates it, and sends back the result. See `specs/100_runner_container.md`.

  In Docker this runs alone in the `runner` container, which has no secrets,
  no database, and no network except the app's connections to it. Outside
  Docker (dev and `mix test`) the app starts it inside its own VM on
  localhost, so the protocol is the same but nothing is isolated.

  ## Protocol

  One request per connection, both ways as a 4-byte big-endian length
  followed by that many bytes of JSON.

  - Request: `{"source": "...", "file": "...", "input": ..., "steps": ...}`
  - Response: `{"ok": value}`, `{"ok": value, "route": "name"}`, or
    `{"error": "message"}`

  Each connection gets its own process, and each script its own process
  under that. If the connection closes before the script finishes (the app
  gave up on the step), the script's process is killed.
  """

  use GenServer

  require Logger

  # Largest request accepted, in bytes. A script's input and steps ride
  # along with it, so this is generous.
  @max_request 64 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The port it's listening on. Useful when it was started on port 0."
  def port, do: :persistent_term.get({__MODULE__, :port})

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    {:ok, listen} =
      :gen_tcp.listen(Keyword.get(opts, :port, 0), [
        :binary,
        ip: ip,
        packet: 4,
        packet_size: @max_request,
        active: false,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)
    :persistent_term.put({__MODULE__, :port}, port)
    Logger.info("Code runner listening on #{:inet.ntoa(ip)}:#{port}")

    acceptor = spawn_link(fn -> accept_loop(listen) end)
    {:ok, %{listen: listen, acceptor: acceptor}}
  end

  defp accept_loop(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)

    {:ok, pid} =
      Task.Supervisor.start_child(PurpleFlow.Runner.Connections, fn ->
        receive do
          {:socket, socket} -> serve(socket)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:socket, socket})
    accept_loop(listen)
  end

  defp serve(socket) do
    with {:ok, data} <- :gen_tcp.recv(socket, 0),
         {:ok, request} <- Jason.decode(data) do
      runner = self()
      {pid, ref} = spawn_monitor(fn -> send(runner, {:response, self(), evaluate(request)}) end)
      # From here on, the connection closing arrives as a message.
      :ok = :inet.setopts(socket, active: :once)

      receive do
        {:response, ^pid, response} ->
          Process.demonitor(ref, [:flush])
          :gen_tcp.send(socket, response)

        {:DOWN, ^ref, :process, ^pid, reason} ->
          :gen_tcp.send(
            socket,
            error_response("script crashed: #{Exception.format_exit(reason)}")
          )

        {:tcp_closed, ^socket} ->
          Process.exit(pid, :kill)

        {:tcp, ^socket, _} ->
          Process.exit(pid, :kill)
      end
    end

    :gen_tcp.close(socket)
  end

  # Runs in the script's own process. Returns the encoded response.
  defp evaluate(%{"source" => source, "file" => file} = request) when is_binary(source) do
    binding = [input: request["input"], steps: request["steps"]]

    result =
      try do
        {result, _bindings} = Code.eval_string(source, binding, file: file)
        result
      rescue
        error -> {:error, Exception.message(error)}
      catch
        kind, value -> {:error, Exception.format_banner(kind, value)}
      end

    encode(result)
  end

  defp evaluate(_request), do: error_response("bad request")

  defp encode({:ok, value}), do: encode_ok(%{"ok" => value})
  defp encode({:ok, value, nil}), do: encode_ok(%{"ok" => value})

  defp encode({:ok, value, route}) when is_binary(route),
    do: encode_ok(%{"ok" => value, "route" => route})

  defp encode({:error, reason}), do: error_response(message(reason))

  defp encode({:ok, _, _} = other),
    do: error_response("node returned something unexpected: #{inspect(other)}")

  defp encode(value), do: encode_ok(%{"ok" => value})

  defp encode_ok(response) do
    case Jason.encode(response) do
      {:ok, json} -> json
      {:error, error} -> error_response("output isn't JSON: #{Exception.message(error)}")
    end
  end

  defp error_response(message), do: Jason.encode!(%{"error" => message})

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)
end
