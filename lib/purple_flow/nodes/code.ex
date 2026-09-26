defmodule PurpleFlow.Nodes.Code do
  @moduledoc """
  Runs an Elixir script file.

      # is_big.toml
      module = "PurpleFlow.Nodes.Code"

      [config]
      file = "is_big.exs"

      # is_big.exs
      if input["amount"] > 1000 do
        {:ok, input, "big"}
      else
        {:ok, input, "small"}
      end

  The script can use two variables:

  - `input`: this node's input
  - `steps`: earlier outputs, like `steps["fetch"]["output"]`

  Return `{:ok, _}`, `{:ok, _, "route"}`, or `{:error, _}`, or just a plain
  value, which becomes `{:ok, value}`.

  The file is read and checked when the workflow loads, so a syntax error
  shows up then, not mid-run.

  The script runs in the runner (`PurpleFlow.Runner.Server`), which in
  Docker is its own container with no secrets, no database, and no network
  beyond answering this app, so it can't reach credentials or other state
  it wasn't handed as `input`/`steps`. See `specs/070_code_sandbox.md`.
  """

  alias PurpleFlow.Runner.Client

  @behaviour PurpleFlow.Node

  @impl true
  def prepare(config, node_dir) do
    with {:ok, file} <- fetch_file(config),
         path = Path.expand(file, node_dir),
         {:ok, source} <- read(path),
         :ok <- parse(source, path) do
      # Stored as a tuple so the template filler leaves the source alone.
      {:ok, Map.put(config, "code", {:source, source, path})}
    end
  end

  @impl true
  def execute(input, config, steps) do
    {:source, source, path} = Map.fetch!(config, "code")
    Client.run(source, path, input, steps)
  end

  defp fetch_file(%{"file" => file}) when is_binary(file), do: {:ok, file}
  defp fetch_file(_), do: {:error, "Code node needs `file` in its [config]"}

  defp read(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, _} -> {:error, "can't read #{Path.relative_to_cwd(path)}"}
    end
  end

  defp parse(source, path) do
    case Code.string_to_quoted(source, file: path) do
      {:ok, _quoted} ->
        :ok

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: meta[:line], else: meta
        {:error, "#{Path.relative_to_cwd(path)} line #{line}: #{format(message)}#{token}"}
    end
  end

  defp format({a, b}), do: "#{a}#{b}"
  defp format(message), do: to_string(message)
end
