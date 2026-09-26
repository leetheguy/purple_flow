defmodule PurpleFlow.Workflow.Paths do
  @moduledoc """
  Keeps every file a workflow names inside the workflows folder.

  A step's `node = "..."` and a Code node's `file = "..."` are relative to
  the file that names them. Without a check, `"../../etc/passwd"`, an
  absolute path, or a symlink pointing out would make the app read a file
  outside the workflows folder, in the container that holds the secrets.
  See `specs/090_workflow_files.md`.
  """

  @doc """
  Resolves `name`, written in a file that lives in `from_dir`, against the
  workflows folder `root`.

  Returns `{:ok, path}` when the result is inside `root`, following
  symlinks, or `:error` when it isn't. Absolute paths are always `:error`,
  and so are symlinks with an absolute target: the folder sits at a
  different absolute path on the host than in the containers, so only
  relative links mean the same thing everywhere. `from_dir` must itself be
  inside `root`.
  """
  def resolve(name, from_dir, root) do
    root = Path.expand(root)
    from = Path.relative_to(Path.expand(from_dir), root)

    # `Path.join/2` would glue an absolute `name` on as if it were relative.
    # Past that, `safe_relative_path` refuses `..` that climbs above `root`
    # and symlinks (checked on disk, under `root`) that point out.
    with :relative <- Path.type(name),
         safe when safe != :unsafe <- :filelib.safe_relative_path(Path.join(from, name), root) do
      {:ok, Path.join(root, IO.chardata_to_string(safe))}
    else
      _ -> :error
    end
  end
end
