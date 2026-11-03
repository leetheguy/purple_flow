defmodule PurpleFlow.Nodes.Postgres do
  @moduledoc """
  Runs a Postgres query.

      module = "PurpleFlow.Nodes.Postgres"

      [config]
      database_url = "{{ creds.SHOP_DB_URL }}"
      query = "SELECT id, email FROM users WHERE created_at > $1::text::timestamptz"
      params = ["{{ input.since }}"]

  Values always go in `params` (`$1`, `$2`, ...), never pasted into `query`.
  That's what prevents SQL injection. Params arrive as JSON values (text,
  numbers), so cast text to other types in SQL, like `$1::text::timestamptz`.

  Output is a list of rows as maps, so the next step runs once per row.

  Connections are pooled, so a step running 1,000 items at once doesn't open
  1,000 connections. Two optional settings shape the pool:

    * `pool_size` — connections in the pool, 1 or more. Default `10`.
    * `idle_timeout` — seconds with no queries before the pool closes its
      connections; the next query opens them again. `0` keeps them open.
      Default `60`.

  Steps that share a `database_url` and both settings share one pool (see
  `PurpleFlow.Nodes.Postgres.Pool`). See [specs/020](specs/020_nodes.md) and its log.
  """

  @behaviour PurpleFlow.Node

  alias PurpleFlow.Nodes.Postgres.Pool

  @pool_size 10
  @idle_timeout 60

  @doc """
  Checks the pool settings when the workflow loads: `pool_size` must be a
  whole number of at least 1, and `idle_timeout` one of at least 0. Returns
  the config unchanged, or `{:error, message}` naming the setting.
  """
  @impl true
  def prepare(config, _node_dir, _root) do
    with :ok <- whole_number(config, "pool_size", 1),
         :ok <- whole_number(config, "idle_timeout", 0) do
      {:ok, config}
    end
  end

  defp whole_number(config, key, min) do
    case Map.fetch(config, key) do
      :error ->
        :ok

      {:ok, n} when is_integer(n) and n >= min ->
        :ok

      {:ok, other} ->
        {:error, "#{key} must be a whole number of at least #{min}, got #{inspect(other)}"}
    end
  end

  @impl true
  def execute(_input, config) do
    with {:ok, pool} <- pool(Map.fetch!(config, "database_url"), settings(config)),
         {:ok, result} <-
           Pool.run(pool, fn conn ->
             Postgrex.query(conn, Map.fetch!(config, "query"), Map.get(config, "params", []))
           end) do
      {:ok, rows(result)}
    else
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rows(%Postgrex.Result{columns: nil}), do: []

  defp rows(%Postgrex.Result{columns: columns, rows: rows}) do
    for row <- rows do
      columns |> Enum.zip(Enum.map(row, &json_value/1)) |> Map.new()
    end
  end

  # Postgres returns a few types that aren't JSON as-is.
  # UUIDs come back as 16 raw bytes; other raw bytes become base64 text.
  defp json_value(<<_::128>> = value) do
    if String.printable?(value), do: value, else: Ecto.UUID.load!(value)
  end

  defp json_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode64(value)
  end

  defp json_value(value), do: value

  # The pool's size, and how long it waits idle in milliseconds
  # (`:infinity` for `idle_timeout = 0`).
  defp settings(config) do
    size = Map.get(config, "pool_size", @pool_size)

    idle_ms =
      case Map.get(config, "idle_timeout", @idle_timeout) do
        0 -> :infinity
        seconds -> seconds * 1000
      end

    {size, idle_ms}
  end

  # Finds the pool for this URL and settings, starting it the first time.
  # The pool itself only holds connections while queries are using it.
  # (`Registry` is Elixir's built-in name lookup for processes.)
  defp pool(url, {size, idle_ms}) do
    key = {url, size, idle_ms}
    name = {:via, Registry, {PurpleFlow.Nodes.Postgres.Pools, key}}

    case Registry.lookup(PurpleFlow.Nodes.Postgres.Pools, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        with {:ok, options} <- parse_url(url) do
          spec = {Pool, name: name, idle_ms: idle_ms, postgrex: [pool_size: size] ++ options}

          case DynamicSupervisor.start_child(PurpleFlow.Nodes.Postgres.PoolSupervisor, spec) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
          end
        end
    end
  end

  # "postgres://user:pass@host:5432/dbname" -> Postgrex options
  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: "/" <> database} = uri
      when scheme in ["postgres", "postgresql"] and is_binary(host) and database != "" ->
        {username, password} =
          case String.split(uri.userinfo || "", ":", parts: 2) do
            [""] -> {nil, nil}
            [user] -> {URI.decode(user), nil}
            [user, pass] -> {URI.decode(user), URI.decode(pass)}
          end

        options =
          [
            hostname: host,
            port: uri.port || 5432,
            database: database,
            username: username,
            password: password
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        {:ok, options}

      _ ->
        {:error, "database_url should look like postgres://user:pass@host:5432/dbname"}
    end
  end
end
