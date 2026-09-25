defmodule PurpleFlow.Nodes.Code.SandboxTest do
  use ExUnit.Case, async: true

  alias PurpleFlow.Nodes.Code.Sandbox

  test "evaluates code with the given binding" do
    quoted = Code.string_to_quoted!("1 + input")
    assert {42, _bindings} = Sandbox.eval_quoted(quoted, input: 41)
  end

  test "killing the calling process also kills the peer OS process" do
    quoted = Code.string_to_quoted!(":timer.sleep(60_000)")

    {:ok, task_pid} =
      Task.start(fn ->
        Sandbox.eval_quoted(quoted, [])
      end)

    # Give the peer time to actually start before we kill its caller.
    Process.sleep(500)
    assert count_peer_processes() > 0

    Process.exit(task_pid, :kill)
    Process.sleep(1000)

    assert count_peer_processes() == 0
  end

  # A peer node's OS process always runs "-user peer" (see erl's -user flag,
  # which peer.erl passes itself). No non-test part of this app starts one,
  # so any match is either this test's own peer or a leaked one.
  defp count_peer_processes do
    case System.cmd("pgrep", ["-f", "user peer"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.split("\n") |> length()
      {_, 1} -> 0
    end
  end
end
