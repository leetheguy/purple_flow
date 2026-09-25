defmodule PurpleFlow.Workflow.LoaderTest do
  use ExUnit.Case, async: true

  import PurpleFlow.WorkflowHelpers

  alias PurpleFlow.Workflow.Loader

  defp problems(workflow_toml, files) do
    {:error, problems} = Loader.load(write_workflow(workflow_toml, files))
    Enum.join(problems, "\n")
  end

  test "a good workflow loads, with triggers, options, and ancestors" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "good"

        [trigger.webhook]
        path = "good"

        [trigger.cron]
        schedule = "0 * * * *"

        [[steps]]
        name = "a"
        node = "n.toml"

        [[steps]]
        name = "b"
        node = "n.toml"
        after = ["a"]
        run = "all"
        concurrency = "sequential"
        timeout = 5

        [[steps]]
        name = "c"
        node = "n.toml"
        after = ["b"]
        when = "yes"
        """,
        %{"n.toml" => fake_node()}
      )

    assert workflow.name == "good"
    assert workflow.webhook == "good"
    assert workflow.cron == "0 * * * *"

    [a, b, c] = workflow.steps
    assert a.after == [] and a.run == :each and a.concurrency == 1_000 and a.timeout == 30_000
    assert b.run == :all and b.concurrency == 1 and b.timeout == 5_000
    assert c.when == "yes"
    assert c.ancestors == ["a", "b"]
  end

  test "every problem is reported together" do
    text =
      problems(
        """
        [workflow]
        name = "bad"

        [trigger.cron]
        schedule = "not a schedule"

        [[steps]]
        name = "missing_file"
        node = "nope.toml"

        [[steps]]
        name = "bad_module"
        node = "bad_module.toml"

        [[steps]]
        name = "orphan"
        node = "n.toml"
        after = ["ghost"]

        [[steps]]
        name = "two_parents"
        node = "n.toml"
        after = ["orphan", "orphan2"]
        when = "x"

        [[steps]]
        name = "bad_options"
        node = "n.toml"
        run = "sometimes"
        """,
        %{"n.toml" => fake_node(), "bad_module.toml" => ~s(module = "Not.A.Node")}
      )

    assert text =~ "can't read"
    assert text =~ "Not.A.Node isn't a module that implements PurpleFlow.Node"
    assert text =~ "`when` needs exactly one `after`"
    assert text =~ ~s(run must be "each" or "all")
    assert text =~ ~s(cron schedule "not a schedule" isn't valid)
  end

  test "unknown after names and cycles" do
    assert problems(
             """
             [workflow]
             name = "bad"
             [[steps]]
             name = "a"
             node = "n.toml"
             after = ["ghost"]
             """,
             %{"n.toml" => fake_node()}
           ) =~ ~s(after "ghost", but there's no step with that name)

    assert problems(
             """
             [workflow]
             name = "loop"
             [[steps]]
             name = "a"
             node = "n.toml"
             after = ["b"]
             [[steps]]
             name = "b"
             node = "n.toml"
             after = ["a"]
             """,
             %{"n.toml" => fake_node()}
           ) =~ "loop back on themselves"
  end

  test "placeholders must use set env vars and ancestors only" do
    text =
      problems(
        """
        [workflow]
        name = "refs"
        [[steps]]
        name = "a"
        node = "n.toml"
        [[steps]]
        name = "b"
        node = "sibling.toml"
        """,
        %{
          "n.toml" => fake_node(%{"return" => "{{ env.PF_DEFINITELY_UNSET }}"}),
          "sibling.toml" => fake_node(%{"return" => "{{ steps.a.output }}"})
        }
      )

    assert text =~ "env var PF_DEFINITELY_UNSET isn't set"
    assert text =~ ~s("a" isn't an ancestor of this step)
  end

  test "a Code node's script is checked at load time" do
    text =
      problems(
        """
        [workflow]
        name = "code"
        [[steps]]
        name = "a"
        node = "code.toml"
        """,
        %{
          "code.toml" => ~s(module = "PurpleFlow.Nodes.Code"\n[config]\nfile = "broken.exs"),
          "broken.exs" => "if input do"
        }
      )

    assert text =~ "broken.exs line"
  end
end
