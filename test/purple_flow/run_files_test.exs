defmodule PurpleFlow.RunFilesTest do
  use ExUnit.Case, async: true

  alias PurpleFlow.{Id, RunFiles}

  test "save, find, and delete a run's files" do
    run_id = Id.generate()
    source = Path.join(System.tmp_dir!(), "pf_run_file_#{run_id}")
    File.write!(source, "hello")

    ref = RunFiles.save(run_id, source, "a.txt", "text/plain")
    assert %{"name" => "a.txt", "type" => "text/plain", "size" => 5, "file" => id} = ref
    assert {:ok, path} = RunFiles.path(ref)
    assert {:ok, ^path} = RunFiles.path(id)
    assert File.read!(path) == "hello"

    RunFiles.delete_run(run_id)
    assert {:error, "file " <> _} = RunFiles.path(ref)
  end

  test "anything but a file ID is refused, so a path can't leave the folder" do
    assert {:error, "not a file" <> _} = RunFiles.path("../../etc/passwd")
    assert {:error, "not a file" <> _} = RunFiles.path(%{"file" => "a/b"})
    assert {:error, "not a file" <> _} = RunFiles.path(42)
    assert :ok = RunFiles.delete_run("..")
  end

  describe "writing a file in pieces" do
    setup do
      run_id = Id.generate()
      on_exit(fn -> RunFiles.delete_run(run_id) end)
      %{run_id: run_id}
    end

    defp files_in(run_id) do
      case File.ls(Path.join(RunFiles.dir(), run_id)) do
        {:ok, names} -> names
        {:error, :enoent} -> []
      end
    end

    test "the pieces are saved whole, with the name, type, and size", %{run_id: run_id} do
      writer = RunFiles.open(run_id, "dump.sql", "application/sql", 0)
      {:ok, writer} = RunFiles.write(writer, "SELECT ")
      {:ok, writer} = RunFiles.write(writer, ["1", ";"])

      ref = RunFiles.close(writer)

      assert %{"name" => "dump.sql", "type" => "application/sql", "size" => 9} = ref
      assert String.starts_with?(ref["file"], run_id <> "/")
      assert {:ok, path} = RunFiles.path(ref)
      assert File.read!(path) == "SELECT 1;"
    end

    test "no type is application/octet-stream", %{run_id: run_id} do
      ref = run_id |> RunFiles.open("blob", nil, 0) |> RunFiles.close()
      assert %{"type" => "application/octet-stream", "size" => 0} = ref
    end

    test "a file exactly at the limit is saved", %{run_id: run_id} do
      {:ok, writer} = RunFiles.write(RunFiles.open(run_id, "a", nil, 5), "12345")
      assert %{"size" => 5} = RunFiles.close(writer)
    end

    test "going over the limit is an error, and the partial file is deleted",
         %{run_id: run_id} do
      {:ok, writer} = RunFiles.write(RunFiles.open(run_id, "big.bin", nil, 1), "1")

      assert {:error, message} = RunFiles.write(writer, "2")
      assert message == "file big.bin is over max_file_size (1 bytes)"
      assert files_in(run_id) == []
    end

    test "a limit of 0 means no limit", %{run_id: run_id} do
      {:ok, writer} =
        RunFiles.write(RunFiles.open(run_id, "a", nil, 0), :binary.copy("x", 100_000))

      assert %{"size" => 100_000} = RunFiles.close(writer)
    end

    test "discarding deletes the file", %{run_id: run_id} do
      {:ok, writer} = RunFiles.write(RunFiles.open(run_id, "a", nil, 0), "half")

      assert :ok = RunFiles.discard(writer)
      assert files_in(run_id) == []
    end
  end

  test "outside a run, a node's files go into a run of their own, with no limit" do
    assert {:ok, %{"ref" => ref, "bytes" => "abcd"}} =
             PurpleFlow.Test.FakeNode.execute(%{}, %{"save_file" => ["ab", "cd"]})

    [run_id, _] = String.split(ref["file"], "/")
    RunFiles.delete_run(run_id)
  end
end
