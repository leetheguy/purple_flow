defmodule PurpleFlow.Nodes.Postgres do
  @moduledoc """
  Runs a Postgres query.

      module = "PurpleFlow.Nodes.Postgres"

      [config]
      database_url = "{{ env.SHOP_DB_URL }}"
      query = "SELECT id, email FROM users WHERE created_at > $1::text::timestamptz"
      params = ["{{ input.since }}"]

  Values always go in `params` (`$1`, `$2`, ...), never pasted into `query`.
  That's what prevents SQL injection. Params arrive as JSON values (text,
  numbers), so cast text to other types in SQL, like `$1::text::timestamptz`.

  Output is a list of rows as maps, so the next step runs once per row.

  Connections are pooled: one pool per `database_url`, 10 connections each,
  so a step running 1,000 items at once doesn't open 1,000 connections.
  """

  @behaviour PurpleFlow.Node

  @pool_size 10

  @impl true
  def execute(_input, config) do
    with {:ok, pool} <- pool(Map.fetch!(config, "database_url")),
         {:ok, result} <-
           Postgrex.query(pool, Map.fetch!(config, "query"), Map.get(config, "params", [])) do
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

  # Finds the pool for this URL, starting it the first time.
  # (`Registry` is Elixir's built-in name lookup for processes.)
  defp pool(url) do
    name = {:via, Registry, {PurpleFlow.Nodes.Postgres.Pools, url}}

    case Registry.lookup(PurpleFlow.Nodes.Postgres.Pools, url) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        with {:ok, options} <- parse_url(url) do
          spec = {Postgrex, [name: name, pool_size: @pool_size] ++ options}

          case DynamicSupervisor.start_child(PurpleFlow.Nodes.Postgres.PoolSupervisor, spec) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, reason} -> {:error, "couldn't connect: #{inspect(reason)}"}
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
