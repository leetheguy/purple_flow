defmodule PurpleFlow.RunnerTest do
  # End to end against the in-VM runner: same protocol and timeouts as the
  # runner container, without the isolation (that's checked against the
  # compose stack, see specs/100_runner_container.md).
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

    @spawner ~s|pid = spawn(fn -> :timer.sleep(:infinity) end)
               send(String.to_existing_atom(input["to"]), {:started, pid})|

    test "what a finished script started is killed", %{name: name} do
      assert {:ok, _} = run(@spawner <> "\n:done", %{"to" => name})

      assert_receive {:started, pid}
      ref = Process.monitor(pid)
      # :noproc if it was already gone by the time it's watched.
      # Swept by the Reaper, at most 100 ms after the last sweep.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:killed, :noproc],
                     1_000
    end

    test "what a stopped script started is killed", %{name: name} do
      caller = spawn(fn -> run(@spawner <> "\n" <> @sleeper, %{"to" => name}) end)

      assert_receive {:started, pid}
      assert_receive {:script, _script}
      ref = Process.monitor(pid)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    end

    # Its own group leader passes output on, so IO calls still get answered
    # (an unanswered one would hang the script).
    test "a script can still write output" do
      assert {:ok, 1} = run(~s|IO.write(""); 1|)
    end
  end

  describe "talking to a runner elsewhere" do
    # A stand-in runner on a free port: it reads one request and does
    # whatever `reply` says with the socket.
    defp fake_runner(reply) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listen)
           {:ok, _request} = :gen_tcp.recv(socket, 0)
           reply.(socket)
         end}
      )

      use_runner({"127.0.0.1", port})
    end

    defp use_runner(address) do
      original = Application.get_env(:purple_flow, :runner_address)
      Application.put_env(:purple_flow, :runner_address, address)
      on_exit(fn -> Application.put_env(:purple_flow, :runner_address, original) end)
    end

    test "uses the configured address" do
      fake_runner(&:gen_tcp.send(&1, ~s({"ok": "from afar"})))
      assert {:ok, "from afar"} = run("1")
    end

    test "a runner that answers with something else is an error" do
      fake_runner(&:gen_tcp.send(&1, ~s({"what": 1})))
      assert {:error, "the Code runner sent back something unexpected"} = run("1")
    end

    test "a runner that hangs up without answering is an error" do
      fake_runner(&:gen_tcp.close/1)
      assert {:error, "lost the Code runner: " <> _} = run("1")
    end

    test "a runner that isn't there is an error" do
      # A port that was free a moment ago, with nothing listening now.
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      use_runner({"127.0.0.1", port})

      assert {:error, "can't reach the Code runner at 127.0.0.1:" <> _} = run("1")
    end
  end

  test "input that can't be sent as JSON is an error, before connecting" do
    assert {:error, "input isn't JSON: " <> _} = run("input", {:not, :json})
  end
end
