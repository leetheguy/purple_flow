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

  Either way, once the script is done, so is everything it started: each
  script gets its own group leader, which every process it spawns inherits,
  and `PurpleFlow.Runner.Reaper` kills every process under that leader. A
  script that starts a `Task` and returns doesn't leave it running.
  """

  use GenServer

  require Logger

  # Largest request accepted by default, in megabytes. A script's input and
  # steps ride along with it, so this is generous.
  @max_request_mb 64

  # How many connections can wait to be accepted. Every Code execution is a
  # connection, and thousands can start at once; the kernel's own default
  # of 5 drops the rest, which then retry after 1, 3, 7... seconds. The
  # kernel caps this at net.core.somaxconn (4096 on current Linux).
  @backlog 4096

  @doc """
  Starts the runner.

  Options: `:port` (`0` picks a free one), `:ip`, `:backlog`, and
  `:max_request`, the largest request in bytes (`0` is no limit; default
  from `config :purple_flow, :runner_max_request`, see `max_request/1`).
  `:name` starts another runner beside the main one, as tests do.
  """
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The port the main runner is listening on. Useful when it was started on port 0."
  def port, do: :persistent_term.get({__MODULE__, :port})

  @doc "The port the runner started with `name:` is listening on."
  def port(name), do: GenServer.call(name, :port)

  @doc """
  The largest request in bytes, from `PURPLEFLOW_RUNNER_MAX_REQUEST`
  (megabytes, a whole number; `0` is no limit; `nil` is the default, 64).
  Raises `ArgumentError` naming the variable for anything else.

      iex> PurpleFlow.Runner.Server.max_request("2")
      2_097_152
  """
  def max_request(nil), do: max_request(Integer.to_string(@max_request_mb))

  def max_request(value) do
    case Integer.parse(value) do
      {mb, ""} when mb >= 0 ->
        mb * 1024 * 1024

      _ ->
        raise ArgumentError,
              "PURPLEFLOW_RUNNER_MAX_REQUEST must be a whole number of megabytes (0 for no limit), got: #{inspect(value)}"
    end
  end

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    max_request =
      Keyword.get_lazy(opts, :max_request, fn ->
        max_request(Application.get_env(:purple_flow, :runner_max_request))
      end)

    {:ok, listen} =
      :gen_tcp.listen(Keyword.get(opts, :port, 0), [
        :binary,
        ip: ip,
        # Raw at first: serve/2 reads the 4-byte length itself, so it can
        # answer a request that's too big instead of dropping it.
        packet: :raw,
        active: false,
        reuseaddr: true,
        backlog: Keyword.get(opts, :backlog, @backlog)
      ])

    {:ok, port} = :inet.port(listen)

    if Keyword.get(opts, :name, __MODULE__) == __MODULE__,
      do: :persistent_term.put({__MODULE__, :port}, port)

    Logger.info("Code runner listening on #{:inet.ntoa(ip)}:#{port}")

    acceptor = spawn_link(fn -> accept_loop(listen, max_request) end)
    {:ok, %{listen: listen, acceptor: acceptor, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept_loop(listen, max_request) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(PurpleFlow.Runner.Connections, fn ->
            receive do
              {:socket, socket} -> serve(socket, max_request)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})

      # Out of file descriptors (the container's `nofile` limit): the
      # connection waits in the backlog until one frees up. Crashing here
      # would drop every waiting connection with it.
      {:error, reason} when reason in [:emfile, :enfile] ->
        Logger.warning("Code runner can't accept a connection (#{reason}); retrying")
        Process.sleep(50)
    end

    accept_loop(listen, max_request)
  end

  # Each request is a 4-byte length, then that many bytes of JSON. A request
  # over the limit is read and thrown away, so the app's send finishes, and
  # answered with an error that says how to raise the limit. (Letting
  # `gen_tcp` enforce the limit would close the socket with no answer.)
  defp serve(socket, max_request) do
    with {:ok, <<length::32>>} <- :gen_tcp.recv(socket, 4) do
      if max_request > 0 and length > max_request do
        discard(socket, length)
        :ok = :inet.setopts(socket, packet: 4)

        :gen_tcp.send(
          socket,
          error_response(
            "the script's input and steps are over the Code runner's limit of " <>
              "#{size(max_request)} (PURPLEFLOW_RUNNER_MAX_REQUEST, in MB; 0 is no limit)"
          )
        )
      else
        received = if length == 0, do: {:ok, ""}, else: :gen_tcp.recv(socket, length)
        :ok = :inet.setopts(socket, packet: 4)
        serve_request(socket, received)
      end
    end
  end

  defp discard(_socket, 0), do: :ok

  defp discard(socket, left) do
    case :gen_tcp.recv(socket, min(left, 1024 * 1024)) do
      {:ok, data} -> discard(socket, left - byte_size(data))
      {:error, _} -> :ok
    end
  end

  defp size(bytes) when bytes >= 1024 * 1024, do: "#{div(bytes, 1024 * 1024)} MB"
  defp size(bytes), do: "#{div(bytes, 1024)} KB"

  defp serve_request(socket, received) do
    with {:ok, data} <- received,
         {:ok, request} <- Jason.decode(data) do
      runner = self()
      leader = start_leader(Process.group_leader())

      {pid, ref} =
        spawn_monitor(fn ->
          Process.group_leader(self(), leader)
          send(runner, {:response, self(), evaluate(request)})
        end)

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
          :ok

        {:tcp, ^socket, _} ->
          :ok
      end

      kill_group(pid, leader)
    end

    :gen_tcp.close(socket)
  end

  # A script's own group leader. It passes the script's output (`IO.puts`,
  # `IO.inspect`) on to the runner's, and marks every process the script
  # starts, so they can all be found and killed.
  defp start_leader(parent), do: spawn(fn -> forward_io(parent) end)

  defp forward_io(parent) do
    receive do
      message -> send(parent, message)
    end

    forward_io(parent)
  end

  # The script and its leader now; what it started, at the Reaper's next
  # sweep. By pid too, in case the script hasn't taken its leader yet.
  defp kill_group(script, leader) do
    Process.exit(script, :kill)
    Process.exit(leader, :kill)
    PurpleFlow.Runner.Reaper.reap(leader)
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
