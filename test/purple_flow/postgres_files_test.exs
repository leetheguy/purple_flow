defmodule PurpleFlow.PostgresFilesTest do
  # Files to and from Postgres bytea: specs/260_file_transport.md.
  use ExUnit.Case, async: true

  alias PurpleFlow.{Id, RunFiles}
  alias PurpleFlow.Nodes.Postgres

  setup do
    config = PurpleFlow.Repo.config()

    url =
      "postgres://#{config[:username]}:#{config[:password]}@#{config[:hostname]}:#{config[:port] || 5432}/#{config[:database]}"

    run_id = Id.generate()
    PurpleFlow.Node.put_files(run_id, 0)
    on_exit(fn -> RunFiles.delete_run(run_id) end)
    %{url: url, run_id: run_id}
  end

  defp run_file(run_id, bytes) do
    {:ok, writer} = RunFiles.write(RunFiles.open(run_id, "a.bin", nil, 0), bytes)
    RunFiles.close(writer)
  end

  defp files_in(run_id) do
    case File.ls(Path.join(RunFiles.dir(), run_id)) do
      {:ok, names} -> names
      {:error, :enoent} -> []
    end
  end

  defp bytes_of(ref) do
    {:ok, path} = RunFiles.path(ref)
    File.read!(path)
  end

  describe "writing" do
    test "a file reference param is sent as the file's bytes", %{url: url, run_id: run_id} do
      bytes = :crypto.strong_rand_bytes(100_000)
      ref = run_file(run_id, bytes)

      assert {:ok, [%{"same" => true, "n" => 100_000}]} =
               Postgres.execute(nil, %{
                 "database_url" => url,
                 "query" => "SELECT $1::bytea = decode($2, 'hex') AS same, length($1) AS n",
                 "params" => [ref, Base.encode16(bytes)]
               })
    end

    test "a file that's gone fails before connecting", %{run_id: run_id} do
      gone = run_file(run_id, "x")
      RunFiles.delete_run(run_id)

      assert {:error, "file " <> _} =
               Postgres.execute(nil, %{
                 "database_url" => "postgres://u@nohost.invalid/db",
                 "query" => "SELECT $1",
                 "params" => [gone]
               })
    end
  end

  describe "reading" do
    test "a bytea column in files becomes a reference to its bytes; NULL stays null",
         %{url: url, run_id: run_id} do
      bytes = :crypto.strong_rand_bytes(50_000)

      assert {:ok, [row]} =
               Postgres.execute(nil, %{
                 "database_url" => url,
                 "query" =>
                   "SELECT decode($1, 'hex') AS data, NULL::bytea AS empty, 'x' AS label",
                 "params" => [Base.encode16(bytes)],
                 "files" => ["data", "empty"]
               })

      assert %{"data" => ref, "empty" => nil, "label" => "x"} = row

      assert %{"name" => "data", "type" => "application/octet-stream", "size" => 50_000} =
               ref

      assert String.starts_with?(ref["file"], run_id <> "/")
      assert bytes_of(ref) == bytes
    end

    test "each row's file is its own", %{url: url} do
      assert {:ok, rows} =
               Postgres.execute(nil, %{
                 "database_url" => url,
                 "query" =>
                   "SELECT n, decode(repeat('ab', n), 'hex') AS data FROM generate_series(1, 3) n",
                 "files" => ["data"]
               })

      assert Enum.map(rows, &bytes_of(&1["data"])) == [
               <<0xAB>>,
               <<0xAB, 0xAB>>,
               <<0xAB, 0xAB, 0xAB>>
             ]
    end

    test "a column in files that isn't bytea, or isn't in the result, fails", %{url: url} do
      config = %{"database_url" => url, "query" => "SELECT 'x' AS label"}

      assert {:error, "files column label isn't bytea"} =
               Postgres.execute(nil, Map.put(config, "files", ["label"]))

      assert {:error, "files column data isn't in the result"} =
               Postgres.execute(nil, Map.put(config, "files", ["data"]))
    end

    test "a value over max_file_size fails, and no row's file is left",
         %{url: url, run_id: run_id} do
      PurpleFlow.Node.put_files(run_id, 2)

      assert {:error, "file data is over max_file_size (2 bytes)"} =
               Postgres.execute(nil, %{
                 "database_url" => url,
                 "query" =>
                   "SELECT decode(repeat('ab', n), 'hex') AS data FROM generate_series(1, 3) n",
                 "files" => ["data"]
               })

      assert files_in(run_id) == []
    end

    test "a failed file in a row also removes that row's files saved before it",
         %{url: url, run_id: run_id} do
      PurpleFlow.Node.put_files(run_id, 2)

      assert {:error, "file big is over max_file_size (2 bytes)"} =
               Postgres.execute(nil, %{
                 "database_url" => url,
                 "query" => "SELECT '\\xab'::bytea AS small, '\\xababab'::bytea AS big",
                 "files" => ["small", "big"]
               })

      assert files_in(run_id) == []
    end

    test "files must be a list of column names" do
      for bad <- ["data", [1], [""]] do
        assert {:error, "files must be a list of column names, not " <> _} =
                 Postgres.prepare(%{"files" => bad}, ".", ".")
      end

      assert {:ok, _} = Postgres.prepare(%{"files" => ["data"]}, ".", ".")
    end
  end
end
