defmodule PurpleFlow.RunTest do
  # Not async: runs and tasks are separate processes sharing the test's database.
  use PurpleFlow.DataCase, async: false

  import PurpleFlow.WorkflowHelpers

  defp outputs(result, step), do: result |> rows(step) |> Enum.map(& &1.output)

  test "straight line: each step gets the previous output" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "line"
        [[steps]]
        name = "a"
        node = "a.toml"
        [[steps]]
        name = "b"
        node = "b.toml"
        after = ["a"]
        """,
        %{"a.toml" => fake_node(%{"return" => %{"x" => 1}}), "b.toml" => fake_node()}
      )

    result = run!(workflow, %{"hello" => "world"})

    assert result.run.status == "complete"
    assert [%{input: %{"hello" => "world"}, output: %{"x" => 1}, item: nil}] = rows(result, "a")
    assert [%{input: %{"x" => 1}, output: %{"x" => 1}}] = rows(result, "b")
    assert result.run.output == %{"x" => 1}
  end

  test "a list runs once per item, and results come back as one flat list" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "flat"
        [[steps]]
        name = "explode"
        node = "explode.toml"
        [[steps]]
        name = "echo"
        node = "echo.toml"
        after = ["explode"]
        """,
        %{"explode.toml" => fake_node(%{"explode" => 2}), "echo.toml" => fake_node()}
      )

    result = run!(workflow, [1, 2, 3])

    # 3 items, each returning 2 copies -> one flat list of 6.
    assert outputs(result, "explode") == [[1, 1], [2, 2], [3, 3]]

    assert Enum.map(rows(result, "echo"), &{&1.item, &1.input, &1.from_item}) ==
             [{0, 1, 0}, {1, 1, 0}, {2, 2, 1}, {3, 2, 1}, {4, 3, 2}, {5, 3, 2}]

    assert result.run.output == [1, 1, 2, 2, 3, 3]
  end

  test "run = \"all\" gets the whole list in one execution" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "all"
        [[steps]]
        name = "all"
        node = "n.toml"
        run = "all"
        """,
        %{"n.toml" => fake_node()}
      )

    result = run!(workflow, [1, 2, 3])
    assert [%{item: nil, input: [1, 2, 3], output: [1, 2, 3]}] = rows(result, "all")
  end

  test "an empty list means zero executions, and the run still completes" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "empty"
        [[steps]]
        name = "a"
        node = "n.toml"
        [[steps]]
        name = "b"
        node = "n.toml"
        after = ["a"]
        """,
        %{"n.toml" => fake_node()}
      )

    result = run!(workflow, [])
    assert result.run.status == "complete"
    assert result.steps == []
    assert result.run.output == []
  end

  test "sequential concurrency runs one item at a time" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "seq"
        [[steps]]
        name = "slow"
        node = "slow.toml"
        concurrency = "sequential"
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 30})}
      )

    [first, second, third] = rows(run!(workflow, [1, 2, 3]), "slow")
    assert DateTime.compare(second.started_at, first.finished_at) != :lt
    assert DateTime.compare(third.started_at, second.finished_at) != :lt
  end

  test "an output over 10,000 items fails the run" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "cap"
        [[steps]]
        name = "big"
        node = "big.toml"
        """,
        %{"big.toml" => fake_node(%{"explode" => 10_001})}
      )

    result = run!(workflow, "x")
    assert result.run.status == "failed"
    assert result.run.error["message"] =~ "more than 10000 items"
  end

  test "routes: a single execution only takes its branch, and branches meet once" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "ifelse"
        [[steps]]
        name = "check"
        node = "check.toml"
        [[steps]]
        name = "big"
        node = "n.toml"
        after = ["check"]
        when = "big"
        [[steps]]
        name = "small"
        node = "n.toml"
        after = ["check"]
        when = "small"
        [[steps]]
        name = "notify"
        node = "n.toml"
        after = ["big", "small"]
        """,
        %{"check.toml" => fake_node(%{"route_over" => 10}), "n.toml" => fake_node()}
      )

    result = run!(workflow, 50)
    assert [%{route: "big"}] = rows(result, "check")
    assert [%{input: 50}] = rows(result, "big")
    assert rows(result, "small") == []
    assert [%{input: 50}] = rows(result, "notify")
  end

  test "routes per item: each item goes down its own branch" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "split"
        [[steps]]
        name = "check"
        node = "check.toml"
        [[steps]]
        name = "big"
        node = "n.toml"
        after = ["check"]
        when = "big"
        [[steps]]
        name = "small"
        node = "n.toml"
        after = ["check"]
        when = "small"
        """,
        %{"check.toml" => fake_node(%{"route_over" => 10}), "n.toml" => fake_node()}
      )

    result = run!(workflow, [5, 50, 7, 70])
    assert outputs(result, "big") == [50, 70]
    assert Enum.map(rows(result, "big"), & &1.from_item) == [1, 3]
    assert outputs(result, "small") == [5, 7]
  end

  test "parallel branches that meet again: the step runs once per branch" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "parallel"
        [[steps]]
        name = "left"
        node = "n.toml"
        [[steps]]
        name = "right"
        node = "n.toml"
        [[steps]]
        name = "join"
        node = "n.toml"
        after = ["left", "right"]
        """,
        %{"n.toml" => fake_node()}
      )

    result = run!(workflow, "hi")
    assert length(rows(result, "join")) == 2
  end

  test "an error fails the run and nothing after it starts" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "fails"
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
    assert result.run.status == "failed"
    assert %{"step" => "a", "item" => 1, "message" => "boom on 2"} = result.run.error
    assert rows(result, "b") == []
  end

  test "an exception counts as an error" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "raises"
        [[steps]]
        name = "a"
        node = "a.toml"
        """,
        %{"a.toml" => fake_node(%{"raise" => true})}
      )

    result = run!(workflow, 1)
    assert [%{status: "error", error: %{"message" => "kaboom"}}] = rows(result, "a")
  end

  test "a slow node times out on its own" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "slow"
        [[steps]]
        name = "a"
        node = "a.toml"
        timeout = 0.05
        """,
        %{"a.toml" => fake_node(%{"sleep" => 1_000})}
      )

    result = run!(workflow, 1)
    assert result.run.status == "failed"
    assert [%{status: "timed_out"}] = rows(result, "a")
  end

  test "templates can use the input and ancestor outputs" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "refs"
        [[steps]]
        name = "a"
        node = "a.toml"
        [[steps]]
        name = "b"
        node = "b.toml"
        after = ["a"]
        """,
        %{
          "a.toml" => fake_node(%{"return" => %{"id" => 42}}),
          "b.toml" =>
            fake_node(%{"return" => "a said {{ steps.a.output.id }}, input {{ input.id }}"})
        }
      )

    assert run!(workflow, nil).run.output == "a said 42, input 42"
  end

  test "credentials are redacted from saved records" do
    System.put_env("PF_RUN_TEST_TOKEN", "super-secret-value")

    workflow =
      load_workflow!(
        """
        [workflow]
        name = "secret"
        [[steps]]
        name = "a"
        node = "a.toml"
        """,
        %{"a.toml" => fake_node(%{"return" => "token is {{ env.PF_RUN_TEST_TOKEN }}"})}
      )

    result = run!(workflow, nil)
    assert [%{output: "token is [redacted]"}] = rows(result, "a")
    refute inspect(result) =~ "super-secret-value"
  end
end
