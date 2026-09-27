defmodule PurpleFlow.FailuresTest do
  # Failures, on_fail, the failed route, and kill: specs/130_failures.md.
  use PurpleFlow.DataCase, async: false

  import ExUnit.CaptureLog
  import PurpleFlow.WorkflowHelpers

  test "a failed item stops there; the others carry on and the run completes" do
    workflow =
      steps!(
        "carry_on",
        """
        [[steps]]
        name = "a"
        node = "a.toml"
        [[steps]]
        name = "b"
        node = "n.toml"
        after = ["a"]
        """,
        %{"a.toml" => fake_node(%{"fail_if" => 2}), "n.toml" => fake_node()}
      )

    result = run!(workflow, [1, 2, 3])
    assert result.run.status == "complete"

    assert [%{status: "error", error: %{"message" => "boom on 2"}}] =
             Enum.filter(rows(result, "a"), &(&1.status != "ok"))

    assert result |> rows("b") |> Enum.map(& &1.input) |> Enum.sort() == [1, 3]
  end

  test "on_fail = \"end_run\" fails the run and starts nothing new" do
    workflow =
      steps!(
        "ends",
        """
        [[steps]]
        name = "a"
        node = "a.toml"
        concurrency = 1
        on_fail = "end_run"
        """,
        %{"a.toml" => fake_node(%{"fail_if" => 2})}
      )

    result = run!(workflow, [1, 2, 3])
    assert result.run.status == "failed"
    assert %{"step" => "a", "item" => 1, "message" => "boom on 2"} = result.run.error
    # Item 3 never started.
    assert result |> rows("a") |> Enum.map(& &1.input) == [1, 2]
  end

  test "end_run lets executions already running finish, and they're saved" do
    workflow =
      steps!(
        "ends_gently",
        """
        [[steps]]
        name = "a"
        node = "a.toml"
        on_fail = "end_run"
        [[steps]]
        name = "b"
        node = "n.toml"
        after = ["a"]
        """,
        %{
          "a.toml" => fake_node(%{"sleep_input" => true, "fail_if" => 1}),
          "n.toml" => fake_node()
        }
      )

    result = run!(workflow, [1, 150])
    assert result.run.status == "failed"

    assert result |> rows("a") |> Enum.map(&{&1.input, &1.status}) |> Enum.sort() ==
             [{1, "error"}, {150, "ok"}]

    # What it produced after the run ended went nowhere.
    assert rows(result, "b") == []
  end

  test "the failed route gets the error and the input" do
    workflow =
      steps!(
        "handled",
        """
        [[steps]]
        name = "a"
        node = "a.toml"
        [[steps]]
        name = "oops"
        node = "n.toml"
        after = ["a"]
        when = "failed"
        [[steps]]
        name = "fine"
        node = "n.toml"
        after = ["a"]
        """,
        %{"a.toml" => fake_node(%{"fail_if" => 2}), "n.toml" => fake_node()}
      )

    result = run!(workflow, [1, 2])
    assert [%{input: %{"error" => "boom on 2", "input" => 2}}] = rows(result, "oops")
    assert [%{input: 1}] = rows(result, "fine")
  end

  test "a raise and a crash each count as a failure" do
    workflow =
      steps!(
        "broken",
        """
        [[steps]]
        name = "raises"
        node = "raise.toml"
        [[steps]]
        name = "crashes"
        node = "crash.toml"
        """,
        %{
          "raise.toml" => fake_node(%{"raise" => true}),
          "crash.toml" => fake_node(%{"crash" => true})
        }
      )

    result = run!(workflow, 1)
    assert result.run.status == "complete"
    assert [%{status: "error", error: %{"message" => "kaboom"}}] = rows(result, "raises")

    assert [%{status: "error", error: %{"message" => "node crashed: " <> _}}] =
             rows(result, "crashes")
  end

  test "kill stops running executions and saves them and the run as killed" do
    workflow =
      steps!(
        "stuck",
        """
        [[steps]]
        name = "a"
        node = "slow.toml"
        concurrency = 1
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 60_000})}
      )

    id = start!(workflow, [1, 2])
    assert_receive {:run_progress, ^id, %{"a" => %{running: 1, queued: 1}}}, 1_000

    assert :ok = PurpleFlow.kill(id)
    result = finish!(id)

    assert result.run.status == "killed"
    assert [%{input: 1, status: "killed"}] = rows(result, "a")
    assert {:error, _} = PurpleFlow.kill(id)
  end

  test "a crashed run process is saved as failed" do
    workflow =
      steps!(
        "crashing_run",
        """
        [[steps]]
        name = "a"
        node = "slow.toml"
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 60_000})}
      )

    id = start!(workflow, 1)
    [{pid, _}] = Registry.lookup(PurpleFlow.RunRegistry, id)

    # A cast the run has no clause for raises inside it: a bug, on purpose.
    capture_log(fn ->
      GenServer.cast(pid, :not_a_message_it_handles)
      assert_receive {:run_finished, ^id, "failed"}, 5_000
    end)

    result = PurpleFlow.Runs.get(id)
    assert result.run.status == "failed"
    assert result.run.error["message"] =~ "the run crashed"
  end
end
