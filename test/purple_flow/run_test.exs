defmodule PurpleFlow.RunTest do
  # How items flow through a run: specs/120_flow.md.
  # Not async: runs and tasks are separate processes sharing the test's database.
  use PurpleFlow.DataCase, async: false

  import PurpleFlow.WorkflowHelpers

  defp outputs(result, step), do: result |> rows(step) |> Enum.map(& &1.output)
  defp inputs(result, step), do: result |> rows(step) |> Enum.map(& &1.input)
  defp before?(a, b), do: DateTime.compare(a, b) == :lt

  test "straight line: each step gets the item before it" do
    workflow =
      steps!(
        "line",
        """
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
    assert [%{input: %{"hello" => "world"}, output: %{"x" => 1}, item: 0}] = rows(result, "a")
    assert [%{input: %{"x" => 1}, output: %{"x" => 1}, item: 0, from_item: 0}] = rows(result, "b")
    assert result.run.output == %{"x" => 1}
  end

  test "a returned list splits: each item gets its own execution" do
    workflow =
      steps!(
        "split",
        """
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

    # The trigger's list split into 3 items; each returned 2 copies: 6 items.
    assert Enum.sort(inputs(result, "explode")) == [1, 2, 3]
    assert Enum.sort(inputs(result, "echo")) == [1, 1, 2, 2, 3, 3]

    # Each echo came from the explode execution that had its value.
    explode = Map.new(rows(result, "explode"), &{&1.item, &1.input})
    for row <- rows(result, "echo"), do: assert(explode[row.from_item] == row.input)

    assert Enum.sort(result.run.output) == [1, 1, 2, 2, 3, 3]
  end

  test "an object holding a list is one item" do
    workflow =
      steps!(
        "wrapped",
        """
        [[steps]]
        name = "a"
        node = "a.toml"
        [[steps]]
        name = "b"
        node = "b.toml"
        after = ["a"]
        """,
        %{"a.toml" => fake_node(%{"return" => %{"rows" => [1, 2, 3]}}), "b.toml" => fake_node()}
      )

    result = run!(workflow, nil)
    assert [%{input: %{"rows" => [1, 2, 3]}}] = rows(result, "b")
  end

  test "an empty list means zero executions, and the run still completes" do
    workflow =
      steps!(
        "empty",
        """
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
    assert result.run.output == nil
  end

  test "items move on without waiting for the rest of their step" do
    workflow =
      steps!(
        "pipeline",
        """
        [[steps]]
        name = "slow"
        node = "slow.toml"
        [[steps]]
        name = "next"
        node = "n.toml"
        after = ["slow"]
        """,
        %{"slow.toml" => fake_node(%{"sleep_input" => true}), "n.toml" => fake_node()}
      )

    result = run!(workflow, [5, 300])
    [fast_next] = Enum.filter(rows(result, "next"), &(&1.input == 5))
    [slow] = Enum.filter(rows(result, "slow"), &(&1.input == 300))

    assert before?(fast_next.started_at, slow.finished_at)
  end

  test "concurrency caps running executions across the run" do
    workflow =
      steps!(
        "capped",
        """
        [[steps]]
        name = "a"
        node = "n.toml"
        [[steps]]
        name = "b"
        node = "n.toml"
        [[steps]]
        name = "slow"
        node = "slow.toml"
        after = ["a", "b"]
        concurrency = 2
        """,
        %{"n.toml" => fake_node(), "slow.toml" => fake_node(%{"sleep" => 40})}
      )

    # Items arrive from two branches; the cap still holds across both.
    rows = rows(run!(workflow, [1, 2, 3]), "slow")
    assert length(rows) == 6

    # At the moment each one started, at most two were running.
    for row <- rows do
      running_then =
        Enum.count(rows, fn other ->
          DateTime.compare(other.started_at, row.started_at) != :gt and
            before?(row.started_at, other.finished_at)
        end)

      assert running_then <= 2
    end
  end

  test "concurrency = 1 runs one at a time, in queue order" do
    workflow =
      steps!(
        "seq",
        """
        [[steps]]
        name = "slow"
        node = "slow.toml"
        concurrency = 1
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 20})}
      )

    [first, second, third] = rows(run!(workflow, [1, 2, 3]), "slow")
    assert Enum.map([first, second, third], & &1.input) == [1, 2, 3]
    assert DateTime.compare(second.started_at, first.finished_at) != :lt
    assert DateTime.compare(third.started_at, second.finished_at) != :lt
  end

  test "delay spaces out starts" do
    workflow =
      steps!(
        "spaced",
        """
        [[steps]]
        name = "a"
        node = "n.toml"
        delay = 50
        """,
        %{"n.toml" => fake_node()}
      )

    starts = run!(workflow, [1, 2, 3]) |> rows("a") |> Enum.map(& &1.started_at)

    for [earlier, later] <- Enum.chunk_every(starts, 2, 1, :discard) do
      assert DateTime.diff(later, earlier, :millisecond) >= 45
    end
  end

  test "timeout = 0 never times out; a timeout stops the execution" do
    workflow =
      steps!(
        "timeouts",
        """
        [[steps]]
        name = "patient"
        node = "slow.toml"
        [[steps]]
        name = "hasty"
        node = "slow.toml"
        timeout = 0.05
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 150})}
      )

    result = run!(workflow, 1)
    assert [%{status: "ok"}] = rows(result, "patient")

    assert [%{status: "timed_out", error: %{"message" => "timed out after 0.05s"}}] =
             rows(result, "hasty")
  end

  test "backpressure: a full queue set to wait holds back the step feeding it" do
    workflow =
      steps!(
        "held",
        """
        [[steps]]
        name = "src"
        node = "src.toml"
        concurrency = 1
        [[steps]]
        name = "slow"
        node = "slow.toml"
        after = ["src"]
        concurrency = 1
        max_queue = 1
        """,
        %{"src.toml" => fake_node(%{"sleep" => 10}), "slow.toml" => fake_node(%{"sleep" => 60})}
      )

    result = run!(workflow, [0, 1, 2, 3])
    src = rows(result, "src")
    slow = rows(result, "slow")
    assert length(slow) == 4

    # src can't start item i until slow has taken item i - 1 off its queue.
    for i <- 2..3 do
      assert DateTime.compare(Enum.at(src, i).started_at, Enum.at(slow, i - 1).started_at) != :lt
    end
  end

  test "overflow: items that don't fit take the overflow route and are recorded" do
    workflow =
      steps!(
        "spill",
        """
        [[steps]]
        name = "src"
        node = "src.toml"
        [[steps]]
        name = "sink"
        node = "slow.toml"
        after = ["src"]
        concurrency = 1
        max_queue = 2
        on_full = "overflow"
        [[steps]]
        name = "spilled"
        node = "n.toml"
        after = ["sink"]
        when = "overflow"
        """,
        %{
          "src.toml" => fake_node(%{"return" => [1, 2, 3, 4, 5]}),
          "slow.toml" => fake_node(%{"sleep" => 20}),
          "n.toml" => fake_node()
        }
      )

    result = run!(workflow, nil)
    sink = rows(result, "sink")
    assert sink |> Enum.filter(&(&1.status == "ok")) |> Enum.map(& &1.input) == [1, 2]
    assert sink |> Enum.filter(&(&1.status == "overflow")) |> Enum.map(& &1.input) == [3, 4, 5]
    assert result |> inputs("spilled") |> Enum.sort() == [3, 4, 5]
  end

  test "routes: a single execution only takes its branch" do
    workflow =
      steps!(
        "ifelse",
        """
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
      steps!(
        "per_item_routes",
        """
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
    assert result |> outputs("big") |> Enum.sort() == [50, 70]
    assert result |> outputs("small") |> Enum.sort() == [5, 7]
    assert result.run.output |> Map.keys() |> Enum.sort() == ["big", "small"]
  end

  test "branches meeting again: one execution per item from each branch" do
    workflow =
      steps!(
        "parallel",
        """
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

    assert length(rows(run!(workflow, [1, 2]), "join")) == 4
  end

  test "steps.X.output is the item on this item's path" do
    workflow =
      steps!(
        "lineage",
        """
        [[steps]]
        name = "fetch"
        node = "fetch.toml"
        [[steps]]
        name = "double"
        node = "n.toml"
        after = ["fetch"]
        [[steps]]
        name = "say"
        node = "say.toml"
        after = ["double"]
        """,
        %{
          "fetch.toml" => fake_node(%{"return" => [%{"id" => 1}, %{"id" => 2}]}),
          "n.toml" => fake_node(),
          "say.toml" => fake_node(%{"return" => "user {{ steps.fetch.output.id }}"})
        }
      )

    assert run!(workflow, nil) |> outputs("say") |> Enum.sort() == ["user 1", "user 2"]
  end

  test "the run's output: one execution's output, or every item in start order" do
    workflow =
      steps!(
        "outputs",
        """
        [[steps]]
        name = "once"
        node = "list.toml"
        [[steps]]
        name = "each"
        node = "n.toml"
        after = ["once"]
        concurrency = 1
        [[steps]]
        name = "also"
        node = "list.toml"
        """,
        %{"list.toml" => fake_node(%{"return" => [3, 1, 2]}), "n.toml" => fake_node()}
      )

    # `also` ran once and returned a list: that list. `each` ran three
    # times, one at a time: its items in start order.
    assert run!(workflow, nil).run.output == %{"also" => [3, 1, 2], "each" => [3, 1, 2]}
  end

  test "rows are saved in batches, and every one is there when the run ends" do
    workflow =
      steps!(
        "many",
        """
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

    id = start!(workflow, Enum.to_list(1..500))
    assert_receive {:run_progress, ^id, _stats}, 5_000
    result = finish!(id)

    assert length(rows(result, "a")) == 500
    assert length(rows(result, "b")) == 500
  end

  test "run_progress says what's queued, running, and done per step" do
    workflow =
      steps!(
        "progress",
        """
        [[steps]]
        name = "a"
        node = "slow.toml"
        concurrency = 2
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 400})}
      )

    id = start!(workflow, [1, 2, 3])
    assert_receive {:run_progress, ^id, %{"a" => %{queued: 1, running: 2, concurrency: 2}}}, 1_000
    finish!(id)
  end

  test "templates can use the input and ancestor outputs" do
    workflow =
      steps!(
        "refs",
        """
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
    {:ok, cred} = PurpleFlow.Credentials.create("PF_RUN_TEST_TOKEN", "")
    {:ok, _} = PurpleFlow.Credentials.update(cred.id, %{key: "super-secret-value"})

    workflow =
      steps!(
        "secret",
        """
        [[steps]]
        name = "a"
        node = "a.toml"
        """,
        %{"a.toml" => fake_node(%{"return" => "token is {{ creds.PF_RUN_TEST_TOKEN }}"})}
      )

    result = run!(workflow, nil)
    assert [%{output: "token is [redacted]"}] = rows(result, "a")
    refute inspect(result) =~ "super-secret-value"
  end

  test "stream_to gets every item a last step produces, as it's produced" do
    workflow =
      steps!(
        "streamed",
        """
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

    id = start!(workflow, [1, 2], stream_to: self())
    finish!(id)
    assert_received {:run_item, ^id, "b", 1}
    assert_received {:run_item, ^id, "b", 2}
    refute_received {:run_item, ^id, "a", _}
  end
end
