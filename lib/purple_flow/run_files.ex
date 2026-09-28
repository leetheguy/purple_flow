defmodule PurpleFlow.RunFiles do
  @moduledoc """
  Files a run carries, like uploads sent to a webhook. The bytes live on
  disk, in the run files folder (`PURPLEFLOW_RUN_FILES_DIR`, a volume of
  its own), and items carry only a reference to them:

      %{"file" => "<run id>/<file id>", "name" => "invoice.pdf",
        "type" => "application/pdf", "size" => 48213}

  So a file never ends up in a run's saved records, only its reference.
  A run's files are deleted when the run ends, and leftovers from runs cut
  off by a restart are deleted at boot. See `specs/190_run_files.md`.
  """

  alias PurpleFlow.Id

  # A file ID is "<run id>/<file id>", both UUIDs, so it can't point anywhere else.
  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @file_id Regex.compile!("\\A#{@uuid}/#{@uuid}\\z")
  @run_id Regex.compile!("\\A#{@uuid}\\z")

  @doc "The run files folder."
  def dir, do: Application.get_env(:purple_flow, :run_files_dir, "run_files")

  @doc """
  Copies the file at `source` into `run_id`'s files and returns its
  reference. `name` and `type` are the file's name and media type.
  """
  def save(run_id, source, name, type) do
    id = run_id <> "/" <> Id.generate()
    dest = Path.join(dir(), id)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(source, dest)

    %{
      "file" => id,
      "name" => name,
      "type" => type || "application/octet-stream",
      "size" => File.stat!(dest).size
    }
  end

  @doc """
  Where a file's bytes are, from its reference (or its bare `"file"` ID).
  An error if it isn't a file reference or the file is gone.
  """
  @spec path(term()) :: {:ok, String.t()} | {:error, String.t()}
  def path(%{"file" => id}), do: path(id)

  def path(id) when is_binary(id) do
    path = Path.join(dir(), id)

    cond do
      not Regex.match?(@file_id, id) -> not_a_file(id)
      File.regular?(path) -> {:ok, path}
      true -> {:error, "file #{id} is gone (a run's files last until the run ends)"}
    end
  end

  def path(other), do: not_a_file(other)

  defp not_a_file(value),
    do:
      {:error, "not a file: #{inspect(value)} (expected a file reference like input.body.upload)"}

  @doc "Deletes all of a run's files."
  def delete_run(run_id) do
    if Regex.match?(@run_id, run_id), do: File.rm_rf(Path.join(dir(), run_id))
    :ok
  end

  @doc "Deletes every run's files. At boot, when no run is running."
  def sweep do
    case File.ls(dir()) do
      {:ok, entries} -> Enum.each(entries, &File.rm_rf(Path.join(dir(), &1)))
      {:error, _} -> :ok
    end
  end
end
