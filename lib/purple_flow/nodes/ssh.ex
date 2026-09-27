defmodule PurpleFlow.Nodes.Ssh do
  @moduledoc """
  Runs a command on another machine over SSH, with Erlang's own `:ssh`.

      module = "PurpleFlow.Nodes.Ssh"

      [config]
      host = "server.example.com"
      port = 22                                 # default 22
      user = "deploy"
      private_key = "{{ creds.DEPLOY_SSH_KEY }}" # or: password = "{{ creds.DEPLOY_PASSWORD }}"
      host_key = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"  # optional
      command = "tail -n 100 /var/log/app.log"
      stdin = "{{ input.text }}"                # optional
      connect_timeout = 30                      # seconds to connect and log in; 0 = no limit
      stream = "lines"                          # optional: "lines" or "ndjson"

  Output is `{"stdout": ..., "stderr": ..., "exit_status": 0}`. A non-zero
  exit status is an error. No retries: a failure fails loud.

  `command` runs in the user's shell on the server, templates and all.

  `host_key` is the server's key fingerprint, as `ssh-keygen -lf` prints
  it; when set, any other key is refused before logging in. Without it,
  any key is accepted.

  With `stream`, the command's standard output is read as it arrives and
  each line in it is handed on right away (`PurpleFlow.Node.emit/2`), as
  text or decoded JSON. See `specs/170_ssh.md`.
  """

  @behaviour PurpleFlow.Node

  alias PurpleFlow.StreamParser

  @protocols ~w(lines ndjson)
  # Seconds to connect and log in, unless `connect_timeout` says otherwise.
  @connect_timeout 30
  # Most stderr kept for an error message while streaming.
  @stderr_limit 64_000

  @impl true
  def prepare(config, _node_dir, _root) do
    missing = Enum.reject(~w(host user command), &Map.has_key?(config, &1))

    cond do
      missing != [] ->
        {:error, "missing #{Enum.join(missing, ", ")}"}

      not Map.has_key?(config, "password") and not Map.has_key?(config, "private_key") ->
        {:error, "needs a password or a private_key"}

      config["stream"] not in [nil | @protocols] ->
        {:error, ~s(stream must be "lines" or "ndjson", not #{inspect(config["stream"])})}

      true ->
        {:ok, config}
    end
  end

  @impl true
  def execute(_input, config) do
    with {:ok, conn} <- connect(config) do
      try do
        run(conn, config)
      after
        :ssh.close(conn)
      end
    end
  end

  defp connect(config) do
    host = config |> Map.fetch!("host") |> to_string() |> String.to_charlist()
    timeout = connect_timeout(config)

    options =
      [
        user: config |> Map.fetch!("user") |> to_string() |> String.to_charlist(),
        user_interaction: false,
        save_accepted_host: false,
        connect_timeout: timeout,
        auth_methods: auth_methods(config),
        key_cb:
          {PurpleFlow.Nodes.Ssh.Keys,
           private_key: config["private_key"], host_key: config["host_key"]}
      ] ++ password(config["password"])

    case :ssh.connect(host, port(config["port"]), options, timeout) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "SSH connection to #{host} failed: #{reason(reason)}"}
    end
  end

  defp auth_methods(config) do
    methods =
      if(config["private_key"], do: ["publickey"], else: []) ++
        if(config["password"], do: ["password", "keyboard-interactive"], else: [])

    methods |> Enum.join(",") |> String.to_charlist()
  end

  defp password(nil), do: []
  defp password(password), do: [password: password |> to_string() |> String.to_charlist()]

  # In milliseconds, as `:ssh` wants it. 0 means no limit, like a step's `timeout`.
  defp connect_timeout(config) do
    case config |> Map.get("connect_timeout", @connect_timeout) |> number() do
      seconds when seconds == 0 -> :infinity
      seconds -> round(seconds * 1000)
    end
  end

  defp number(n) when is_number(n), do: n
  defp number(n) when is_binary(n), do: n |> Float.parse() |> elem(0)

  defp port(nil), do: 22
  defp port(port) when is_integer(port), do: port
  defp port(port) when is_binary(port), do: String.to_integer(port)

  # Opens a channel, runs the command, feeds it stdin, and reads until the
  # channel closes.
  defp run(conn, config) do
    command = config |> Map.fetch!("command") |> to_string()

    # If the connection itself goes away, reading stops instead of waiting forever.
    Process.monitor(conn)

    with {:ok, channel} <- :ssh_connection.session_channel(conn, :infinity),
         :success <-
           :ssh_connection.exec(conn, channel, String.to_charlist(command), :infinity) do
      if stdin = config["stdin"], do: :ok = :ssh_connection.send(conn, channel, stdin(stdin))
      :ok = :ssh_connection.send_eof(conn, channel)

      read(conn, channel, %{
        stream: config["stream"],
        parser: StreamParser.new(),
        stdout: [],
        stderr: [],
        stderr_size: 0,
        exit: nil
      })
    else
      :failure -> {:error, "the server refused to run the command"}
      {:error, reason} -> {:error, "SSH failed: #{reason(reason)}"}
    end
  end

  defp stdin(value) when is_binary(value), do: value
  defp stdin(value), do: Jason.encode!(value)

  defp read(conn, channel, state) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, type, data}} ->
        state = data(state, type, data)
        # Only now ask for more: a stream that's held back holds the server back.
        :ssh_connection.adjust_window(conn, channel, byte_size(data))
        read(conn, channel, state)

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        read(conn, channel, %{state | exit: {:status, status}})

      {:ssh_cm, ^conn, {:exit_signal, ^channel, signal, message, _language}} ->
        read(conn, channel, %{state | exit: {:signal, signal, message}})

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        read(conn, channel, state)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        finish(state)

      {:DOWN, _ref, :process, ^conn, reason} ->
        {:error, "SSH connection lost: #{reason(reason)}"}
    end
  end

  # Standard output (type 0) is kept, or streamed; standard error (type 1)
  # is kept, up to a limit when streaming.
  defp data(%{stream: nil} = state, 0, data), do: %{state | stdout: [state.stdout | data]}

  defp data(state, 0, data) do
    {items, parser} = StreamParser.parse(state.stream, state.parser, data)
    Enum.each(items, &PurpleFlow.Node.emit/1)
    %{state | parser: parser}
  end

  defp data(%{stream: nil} = state, 1, data), do: %{state | stderr: [state.stderr | data]}

  defp data(state, 1, data) do
    if state.stderr_size >= @stderr_limit,
      do: state,
      else: %{
        state
        | stderr: [state.stderr | data],
          stderr_size: state.stderr_size + byte_size(data)
      }
  end

  defp data(state, _type, _data), do: state

  defp finish(state) do
    stdout = IO.iodata_to_binary(state.stdout)
    stderr = IO.iodata_to_binary(state.stderr)

    case state.exit do
      {:status, 0} when state.stream == nil ->
        {:ok, %{"stdout" => stdout, "stderr" => stderr, "exit_status" => 0}}

      {:status, 0} ->
        Enum.each(StreamParser.finish(state.stream, state.parser), &PurpleFlow.Node.emit/1)
        {:ok, []}

      {:status, status} ->
        {:error, "exit status #{status}: #{preview(stderr, stdout)}"}

      {:signal, signal, message} ->
        {:error, "killed by signal #{signal}: #{preview(to_string(message), stderr)}"}

      nil ->
        {:error, "the command ended without an exit status: #{preview(stderr, stdout)}"}
    end
  end

  defp preview("", other), do: other |> String.trim() |> String.slice(0, 500)
  defp preview(text, _other), do: text |> String.trim() |> String.slice(0, 500)

  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason) when is_list(reason), do: to_string(reason)
  defp reason(:econnrefused), do: "connection refused"
  defp reason(:timeout), do: "timed out"
  defp reason(:nxdomain), do: "host not found"
  defp reason(reason), do: inspect(reason)
end
