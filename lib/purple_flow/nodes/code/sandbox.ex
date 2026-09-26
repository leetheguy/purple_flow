defmodule PurpleFlow.Nodes.Code.Sandbox do
  @moduledoc """
  Runs a Code node's script on a throwaway peer BEAM node instead of in this
  VM, so the script never has ambient access to this app's secrets or state.

  See `specs/070_code_sandbox.md` for why and how.
  """

  @doc """
  Evaluates `quoted` on a fresh, isolated peer node, with `binding` (e.g.
  `input:`, `steps:`) available to it. Returns whatever `Code.eval_quoted/3`
  returns there: `{result, bindings}`.

  The peer:

  - has no network distribution (`connection: :standard_io`) and so is
    unreachable from anywhere but this process
  - starts with an empty OS environment (launched through `env -i`), so
    `System.get_env/0,1` finds nothing there
  - has its code path replaced, before the script runs, with only OTP's
    kernel/stdlib and Elixir's own compiled modules — not this app's or its
    dependencies', so `PurpleFlow.*` (and `Postgrex`, etc.) don't exist to
    be called

  Raises if the peer can't be started at all. A script error or infinite
  loop inside `quoted` is the caller's problem, same as it always was; this
  function doesn't itself enforce a timeout (the underlying `:peer.call` is
  given `:infinity`) — `PurpleFlow.StepTask` already enforces the step's own
  timeout a layer up, by killing the task this runs in. `:peer.call/5`'s
  default timeout is a mere 5 seconds, far shorter than a step's configured
  timeout can be, so it must be overridden rather than left at its default.

  Started with `:peer.start_link/1`, not `:peer.start/1`: the peer's
  controlling process must be linked to this one. `PurpleFlow.StepTask` kills
  a wedged step with `Task.shutdown(inner, :brutal_kill)`, which delivers a
  real exit signal to linked processes but leaves unlinked ones untouched.
  Without the link, a timed-out or crashed Code node would orphan its peer
  `erl` OS process, indefinitely — including whatever the script was still
  doing on it.
  """
  def eval_quoted(quoted, binding, opts \\ []) do
    {:ok, peer, _node} = :peer.start_link(peer_options())

    try do
      true = :peer.call(peer, :code, :set_path, [allowed_code_paths()], :infinity)
      :peer.call(peer, Code, :eval_quoted, [quoted, binding, opts], :infinity)
    after
      :peer.stop(peer)
    end
  end

  defp peer_options do
    %{
      connection: :standard_io,
      exec: {find_executable!("env"), [~c"-i", find_executable!("erl")]},
      # +fnu: `env -i` drops the locale, and Elixir warns on every boot
      # without UTF-8 filename encoding.
      args: [~c"+fnu" | clean_boot_args()]
    }
  end

  defp find_executable!(name) do
    path = System.find_executable(name) || raise "#{name} not found on PATH"
    to_charlist(path)
  end

  # A bare `erl` boots `$ROOT/bin/start.boot`, which a plain OTP install has
  # but a Mix release doesn't — there `erl` is the release's bundled one, and
  # its clean boot file lives under `releases/<vsn>/` instead, with paths
  # relative to `$RELEASE_LIB`. Either way the boot file puts more on the
  # code path than the script should see (a release's puts every dependency
  # and this app itself there), which `allowed_code_paths/0` then replaces.
  defp clean_boot_args do
    root = to_string(:code.root_dir())
    vsn = to_string(Application.spec(:purple_flow, :vsn))

    candidates = [
      Path.join([root, "bin", "start_clean"]),
      Path.join([root, "releases", vsn, "start_clean"])
    ]

    case Enum.find(candidates, &File.exists?(&1 <> ".boot")) do
      nil ->
        raise "no start_clean.boot under #{root}"

      boot ->
        Enum.map(
          ["-boot", boot, "-boot_var", "RELEASE_LIB", Path.join(root, "lib")],
          &to_charlist/1
        )
    end
  end

  # OTP's kernel/stdlib plus Elixir's own compiled modules, not this app's
  # or its dependencies'. Lets the peer run Code.eval_quoted/3 and anything
  # the standard library offers, nothing more. The peer shares this node's
  # install, so the same directories exist there.
  defp allowed_code_paths do
    [:kernel, :stdlib, :compiler, :elixir, :eex, :logger]
    |> Enum.map(&:code.lib_dir/1)
    |> Enum.map(&(&1 |> Path.join("ebin") |> to_charlist()))
  end
end
