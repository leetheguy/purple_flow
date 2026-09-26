defmodule PurpleFlow.Workflow.LoaderTest do
  use PurpleFlow.DataCase, async: true

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
    assert workflow.respond == :result
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

        [trigger.webhook]
        path = "bad"
        respond = "later"

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
    assert text =~ ~s(webhook respond must be "result" or "immediately")
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
          "n.toml" => fake_node(%{"return" => "{{ creds.PF_DEFINITELY_UNSET }}"}),
          "sibling.toml" => fake_node(%{"return" => "{{ steps.a.output }}"})
        }
      )

    assert text =~ "credential PF_DEFINITELY_UNSET isn't set"
    assert text =~ ~s("a" isn't an ancestor of this step)
  end

  describe "webhook auth" do
    defp auth_workflow(webhook) do
      """
      [workflow]
      name = "guarded"

      [trigger.webhook]
      path = "guarded"
      #{webhook}

      [[steps]]
      name = "a"
      node = "n.toml"
      """
    end

    test "auth naming a set credential loads, with auth_header lowercased" do
      {:ok, cred} = PurpleFlow.Credentials.create("HOOK_TOKEN", "")
      {:ok, _} = PurpleFlow.Credentials.update(cred.id, %{key: "t"})

      workflow =
        load_workflow!(
          auth_workflow(~s(auth = "HOOK_TOKEN"\nauth_header = "X-Secret-Token")),
          %{"n.toml" => fake_node()}
        )

      assert workflow.auth == "HOOK_TOKEN"
      assert workflow.auth_header == "x-secret-token"
    end

    test "auth naming an unset credential fails" do
      assert problems(auth_workflow(~s(auth = "PF_UNSET_HOOK")), %{"n.toml" => fake_node()}) =~
               "webhook auth credential PF_UNSET_HOOK isn't set"
    end

    test "auth_header without auth fails" do
      assert problems(auth_workflow(~s(auth_header = "x-token")), %{"n.toml" => fake_node()}) =~
               "webhook auth_header needs auth"
    end

    test "auth = \"\" means no auth" do
      workflow = load_workflow!(auth_workflow(~s(auth = "")), %{"n.toml" => fake_node()})
      assert workflow.auth == nil
    end
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

  describe "paths stay inside the workflows folder" do
    # root/wf/workflow.toml, root/shared/, and a folder outside root.
    setup do
      base = Path.join(System.tmp_dir!(), "pf_paths_#{System.unique_integer([:positive])}")
      # unique_integer repeats across test runs, and /tmp doesn't get cleared.
      File.rm_rf!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      root = Path.join(base, "root")
      outside = Path.join(base, "outside")

      for dir <- [Path.join(root, "wf"), Path.join(root, "shared"), outside],
          do: File.mkdir_p!(dir)

      File.write!(Path.join([root, "shared", "n.toml"]), fake_node())
      File.write!(Path.join(outside, "n.toml"), fake_node())
      File.write!(Path.join(outside, "s.exs"), "input")
      %{root: root, outside: outside}
    end

    defp load_with_node(root, node, files \\ %{}) do
      for {name, contents} <- files, do: File.write!(Path.join([root, "wf", name]), contents)

      path = Path.join([root, "wf", "workflow.toml"])

      File.write!(path, """
      [workflow]
      name = "paths"
      [[steps]]
      name = "a"
      node = "#{node}"
      """)

      Loader.load(path, root)
    end

    test "a node file elsewhere in the workflows folder loads", %{root: root} do
      assert {:ok, _} = load_with_node(root, "../shared/n.toml")
    end

    test "climbing out, absolute paths, and symlinks out all fail", %{
      root: root,
      outside: outside
    } do
      File.ln_s!(outside, Path.join([root, "wf", "link"]))

      for node <- ["../../outside/n.toml", Path.join(outside, "n.toml"), "link/n.toml"] do
        assert {:error, [problem]} = load_with_node(root, node)
        assert problem == ~s(step "a": node path leaves the workflows folder)
      end
    end

    test "a relative symlink that stays inside the folder is fine", %{root: root} do
      File.ln_s!("../shared", Path.join([root, "wf", "link"]))
      assert {:ok, _} = load_with_node(root, "link/n.toml")
    end

    # Its target is a different path on the host than in the containers.
    test "an absolute symlink is refused, even pointing inside", %{root: root} do
      File.ln_s!(Path.join(root, "shared"), Path.join([root, "wf", "link"]))
      assert {:error, [_]} = load_with_node(root, "link/n.toml")
    end

    test "a Code node's file can't leave the folder either", %{root: root, outside: outside} do
      code = fn file -> ~s(module = "PurpleFlow.Nodes.Code"\n[config]\nfile = "#{file}") end

      for file <- ["../../outside/s.exs", Path.join(outside, "s.exs")] do
        assert {:error, [problem]} =
                 load_with_node(root, "code.toml", %{"code.toml" => code.(file)})

        assert problem =~ "leaves the workflows folder"
      end
    end

    test "a workflow folder that's a symlink out doesn't load", %{root: root, outside: outside} do
      File.write!(Path.join(outside, "workflow.toml"), "[workflow]\nname = \"sneaky\"")
      File.ln_s!(outside, Path.join(root, "sneaky"))

      {loaded, errors} = Loader.load_all(root)
      refute Map.has_key?(loaded, "sneaky")
      assert [{_, ["the workflow folder leaves the workflows folder"]}] = errors
    end
  end
end
