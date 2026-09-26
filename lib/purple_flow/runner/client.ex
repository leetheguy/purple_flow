defmodule PurpleFlow.Runner.Client do
  @moduledoc """
  Sends a Code node's script to the runner (`PurpleFlow.Runner.Server`) and
  waits for the result. See `specs/100_runner_container.md`.

  The runner's address is `config :purple_flow, :runner_address` (a
  `{host, port}`, set from `PURPLEFLOW_RUNNER_ADDRESS`). Without one, the
  runner started inside this VM is used.

  Waits as long as the script takes. `PurpleFlow.StepTask` enforces the
  step's timeout by killing the process this runs in, which closes the
  connection, which makes the runner kill the script.
  """

  @connect_timeout 5_000

  @doc "Returns `{:ok, output}`, `{:ok, output, route}`, or `{:error, message}`."
  def run(source, file, input, steps) do
    {host, port} = address()

    with {:ok, request} <- encode_request(source, file, input, steps),
         {:ok, socket} <- connect(host, port) do
      try do
        with :ok <- :gen_tcp.send(socket, request),
             {:ok, data} <- :gen_tcp.recv(socket, 0) do
          decode_response(data)
        else
          {:error, reason} -> {:error, "lost the Code runner: #{:inet.format_error(reason)}"}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp address do
    case Application.get_env(:purple_flow, :runner_address) do
      nil -> {~c"127.0.0.1", PurpleFlow.Runner.Server.port()}
      {host, port} -> {to_charlist(host), port}
    end
  end

  defp connect(host, port) do
    case :gen_tcp.connect(host, port, [:binary, packet: 4, active: false], @connect_timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        {:error, "can't reach the Code runner at #{host}:#{port}: #{:inet.format_error(reason)}"}
    end
  end

  defp encode_request(source, file, input, steps) do
    case Jason.encode(%{"source" => source, "file" => file, "input" => input, "steps" => steps}) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, "input isn't JSON: #{Exception.message(error)}"}
    end
  end

  defp decode_response(data) do
    case Jason.decode(data) do
      {:ok, %{"ok" => value, "route" => route}} when is_binary(route) -> {:ok, value, route}
      {:ok, %{"ok" => value}} -> {:ok, value}
      {:ok, %{"error" => message}} when is_binary(message) -> {:error, message}
      _ -> {:error, "the Code runner sent back something unexpected"}
    end
  end
end
