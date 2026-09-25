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
  - has only Elixir's own compiled modules on its code path, not this app's,
    so `PurpleFlow.*` modules don't exist to be called

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
      :peer.call(peer, Code, :eval_quoted, [quoted, binding, opts], :infinity)
    after
      :peer.stop(peer)
    end
  end

  defp peer_options do
    %{
      connection: :standard_io,
      exec: {find_executable!("env"), [~c"-i", find_executable!("erl")]},
      args: elixir_code_paths()
    }
  end

  defp find_executable!(name) do
    path = System.find_executable(name) || raise "#{name} not found on PATH"
    to_charlist(path)
  end

  # Elixir's own compiled modules, not this app's. Lets the peer run
  # Code.eval_quoted/3 and anything the standard library offers, nothing more.
  defp elixir_code_paths do
    [:elixir, :eex, :logger, :compiler]
    |> Enum.map(&:code.lib_dir/1)
    |> Enum.map(&Path.join(&1, "ebin"))
    |> Enum.flat_map(&["-pa", &1])
    |> Enum.map(&to_charlist/1)
  end
end
