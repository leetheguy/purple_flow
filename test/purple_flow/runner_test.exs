defmodule PurpleFlow.RunnerTest do
  # End to end against the in-VM runner: same protocol and timeouts as the
  # runner container, without the isolation (that's checked against the
  # compose stack, see specs/070_code_sandbox.md).
  use PurpleFlow.DataCase, async: false

  import PurpleFlow.WorkflowHelpers

  alias PurpleFlow.Runner.Client

  defp run(source, input \\ nil, steps \\ %{}), do: Client.run(source, "test.exs", input, steps)

  describe "result shapes" do
    test "{:ok, value}" do
      assert {:ok, %{"n" => 2}} = run(~s|{:ok, %{"n" => input["n"] + 1}}|, %{"n" => 1})
    end

    test "{:ok, value, route}" do
      assert {:ok, 5, "big"} =
               run(~s|{:ok, input + steps["a"]["output"], "big"}|, 2, %{"a" => %{"output" => 3}})
    end

    test "{:ok, value, nil} is just {:ok, value}" do
      assert {:ok, 1} = run("{:ok, 1, nil}")
    end

    test "a plain value becomes {:ok, value}" do
      assert {:ok, 20} = run("input * 10", 2)
      assert {:ok, nil} = run("nil")
    end

    test "{:error, message}" do
      assert {:error, "nope"} = run(~s|{:error, "nope"}|)
      assert {:error, ":nope"} = run("{:error, :nope}")
    end
  end

  describe "errors" do
    test "a raised exception comes back as its message" do
      assert {:error, "kaboom"} = run(~s|raise "kaboom"|)
    end

    test "a throw or exit comes back as an error" do
      assert {:error, "** (throw) :ball"} = run("throw(:ball)")
      assert {:error, "** (exit) :gone"} = run("exit(:gone)")
    end

    test "a syntax error comes back as an error" do
      assert {:error, _} = run("1 +")
    end

    test "output that isn't JSON is an error" do
      assert {:error, "output isn't JSON: " <> _} = run("{:ok, {1, 2}}")
    end

    test "a route that isn't a string is an error" do
      assert {:error, "node returned something unexpected: " <> _} = run("{:ok, 1, :big}")
    end

    test "a script that kills its own process is an error" do
      assert {:error, "script crashed: killed"} = run("Process.exit(self(), :kill)")
    end
  end

  describe "stopping a script" do
    # The runner is in this VM, so a script can report its pid to a named
    # test process.
    setup do
      name = :"runner_test_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      %{name: Atom.to_string(name)}
    end

    @sleeper ~s|send(String.to_existing_atom(input["to"]), {:script, self()}); :timer.sleep(:infinity)|

    test "closing the connection kills the script", %{name: name} do
      caller = spawn(fn -> run(@sleeper, %{"to" => name}) end)

      assert_receive {:script, script}
      ref = Process.monitor(script)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^ref, :process, ^script, :killed}
    end

    test "a step timeout kills the script", %{name: name} do
      workflow =
        load_workflow!(
          """
          [workflow]
          name = "slow"

          [[steps]]
          name = "slow"
          node = "slow.toml"
          timeout = 0.2
          """,
          %{
            "slow.toml" => ~s|module = "PurpleFlow.Nodes.Code"\n[config]\nfile = "slow.exs"\n|,
            "slow.exs" => @sleeper
          }
        )

      id = PurpleFlow.Id.generate()
      Phoenix.PubSub.subscribe(PurpleFlow.PubSub, PurpleFlow.topic(id))
      {:ok, ^id} = PurpleFlow.start_run(workflow, %{"to" => name}, id: id)

      assert_receive {:script, script}
      ref = Process.monitor(script)

      assert_receive {:run_finished, ^id, _status}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^script, :killed}
      assert [%{status: "timed_out"}] = rows(PurpleFlow.Runs.get(id), "slow")
    end
  end
end
