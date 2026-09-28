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
end
