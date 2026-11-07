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

  Files move both ways as `bytea` (see [specs/260](specs/260_file_transport.md)):

    * a param that's a file reference (`PurpleFlow.RunFiles.ref?/1`) is
      sent as the file's bytes, so `"{{ input.body.doc }}"` fills a `bytea`
      column;
    * `files = ["data"]` names `bytea` columns to save as files in the run
      (`PurpleFlow.Node.open_file/2`), each named after its column; the row
      holds the reference instead of the bytes, and `NULL` stays `null`.

  Postgres sends a value whole, so each such file is in memory while the
  step runs. `max_file_size` limits the ones read.

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
         :ok <- whole_number(config, "idle_timeout", 0),
         :ok <- file_columns(config) do
      {:ok, config}
    end
  end

  defp file_columns(%{"files" => columns} = config) do
    if is_list(columns) and Enum.all?(columns, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, "files must be a list of column names, not #{inspect(config["files"])}"}
  end

  defp file_columns(_config), do: :ok

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
    files = Map.get(config, "files", [])

    with :ok <- file_columns(config),
         {:ok, params} <- params(Map.get(config, "params", [])),
         {:ok, pool} <- pool(Map.fetch!(config, "database_url"), settings(config)),
         {:ok, oids, result} <- query(pool, Map.fetch!(config, "query"), params, files) do
      rows(result, oids, files)
    else
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A file reference goes as the file's bytes. Checked before connecting.
  defp params(params) do
    Enum.reduce_while(params, {:ok, []}, fn param, {:ok, acc} ->
      if PurpleFlow.RunFiles.ref?(param) do
        case PurpleFlow.RunFiles.path(param) do
          {:ok, path} -> {:cont, {:ok, [File.read!(path) | acc]}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, [param | acc]}}
      end
    end)
    |> case do
      {:ok, params} -> {:ok, Enum.reverse(params)}
      error -> error
    end
  end

  # With `files`, the query is prepared first, to learn its columns' types.
  defp query(pool, query, params, []) do
    Pool.run(pool, fn conn ->
      with {:ok, result} <- Postgrex.query(conn, query, params), do: {:ok, nil, result}
    end)
  end

  defp query(pool, query, params, _files) do
    Pool.run(pool, fn conn ->
      with {:ok, prepared, result} <- Postgrex.prepare_execute(conn, "", query, params),
           do: {:ok, prepared.result_oids, result}
    end)
  end

  # Postgres's type ID for bytea.
  @bytea 17

  defp rows(%Postgrex.Result{columns: nil}, _oids, _files), do: {:ok, []}

  defp rows(%Postgrex.Result{columns: columns, rows: rows}, oids, files) do
    with :ok <- check_file_columns(columns, oids, files) do
      rows
      |> Enum.reduce_while({:ok, [], []}, fn row, {:ok, acc, saved} ->
        case row(columns, row, files) do
          {:ok, map, refs} -> {:cont, {:ok, [map | acc], refs ++ saved}}
          {:error, message, refs} -> {:halt, {:error, message, refs ++ saved}}
        end
      end)
      |> case do
        {:ok, rows, _saved} ->
          {:ok, Enum.reverse(rows)}

        # One failed file means no output, so the ones saved are no use.
        {:error, message, saved} ->
          Enum.each(saved, &PurpleFlow.RunFiles.delete/1)
          {:error, message}
      end
    end
  end

  defp check_file_columns(columns, oids, files) do
    types = Map.new(Enum.zip(columns, oids || []))

    Enum.find_value(files, :ok, fn column ->
      case Map.fetch(types, column) do
        {:ok, @bytea} -> nil
        {:ok, _other} -> {:error, "files column #{column} isn't bytea"}
        :error -> {:error, "files column #{column} isn't in the result"}
      end
    end)
  end

  defp row(columns, row, files) do
    Enum.zip(columns, row)
    |> Enum.reduce_while({:ok, %{}, []}, fn {column, value}, {:ok, map, refs} ->
      cond do
        column not in files ->
          {:cont, {:ok, Map.put(map, column, json_value(value)), refs}}

        value == nil ->
          {:cont, {:ok, Map.put(map, column, nil), refs}}

        true ->
          case save(column, value) do
            {:ok, ref} -> {:cont, {:ok, Map.put(map, column, ref), [ref | refs]}}
            {:error, message} -> {:halt, {:error, message, refs}}
          end
      end
    end)
  end

  defp save(column, bytes) do
    with {:ok, writer} <- PurpleFlow.RunFiles.write(PurpleFlow.Node.open_file(column, nil), bytes),
         do: {:ok, PurpleFlow.RunFiles.close(writer)}
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
