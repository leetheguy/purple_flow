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
        concurrency = 1
        delay = 50
        timeout = 5
        max_queue = 10
        on_full = "overflow"
        on_fail = "end_run"

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
    assert a.after == [] and a.concurrency == 1_000 and a.delay == 0 and a.timeout == 0
    assert a.max_queue == nil and a.on_full == :wait and a.on_fail == :continue
    assert b.concurrency == 1 and b.delay == 50 and b.timeout == 5_000
    assert b.max_queue == 10 and b.on_full == :overflow and b.on_fail == :end_run
    assert c.when == "yes"
    assert c.ancestors == ["a", "b"]
  end

  test "comments at the top of workflow.toml and node files are kept for people to read" do
    workflow =
      load_workflow!(
        """
          # Says hello.
        #
        ##   Twice, indented.

        [workflow]
        # Not this one: it's after the first setting.
        name = "commented"

        [[steps]]
        name = "a"
        node = "a.toml"

        [[steps]]
        name = "b"
        node = "b.toml"
        after = ["a"]
        """,
        %{"a.toml" => "#Greets.\r\n" <> fake_node(), "b.toml" => "\n\n" <> fake_node()}
      )

    assert workflow.comment == "Says hello.\n\n  Twice, indented."
    assert [%{comment: "Greets."}, %{comment: nil}] = workflow.steps
    assert Loader.leading_comment("") == nil
    assert Loader.leading_comment("#\n#\nname = 1") == nil
  end

  test "credential_names lists webhook auth and creds refs, even when the workflow doesn't load" do
    path =
      write_workflow(
        """
        [workflow]
        name = "creds"

        [trigger.webhook]
        path = "creds"
        auth = "HOOK_TOKEN"

        [[steps]]
        name = "a"
        node = "a.toml"

        [[steps]]
        name = "b"
        node = "b.toml"
        after = "nowhere"

        [[steps]]
        name = "c"
        node = "missing.toml"
        """,
        %{
          "a.toml" => fake_node(%{"h" => "Bearer {{ creds.API_KEY }}", "x" => "{{ input.x }}"}),
          "b.toml" => fake_node(%{"list" => ["{{ creds.DB_PASS }}", "{{creds.API_KEY}}"]})
        }
      )

    assert {:error, _} = Loader.load(path)
    assert Loader.credential_names(path) == ["API_KEY", "DB_PASS", "HOOK_TOKEN"]
    assert Loader.credential_names("/nonexistent/workflow.toml") == []
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
        concurrency = 0
        """,
        %{"n.toml" => fake_node(), "bad_module.toml" => ~s(module = "Not.A.Node")}
      )

    assert text =~ "can't read"
    assert text =~ "Not.A.Node isn't a module that implements PurpleFlow.Node"
    assert text =~ "`when` needs exactly one `after`"
    assert text =~ "concurrency must be a number"
    assert text =~ ~s(cron schedule "not a schedule" isn't valid)
    assert text =~ ~s(webhook respond must be "result", "immediately", or "stream")
  end

  test "step settings are checked, and old ones say what to use instead" do
    step = fn extra ->
      problems(
        """
        [workflow]
        name = "opts"
        [[steps]]
        name = "a"
        node = "n.toml"
        #{extra}
        """,
        %{"n.toml" => fake_node()}
      )
    end

    assert step.(~s(run = "all")) =~ "`run` was removed"
    assert step.(~s(run = "all")) =~ "Batch step"

    assert step.(~s(concurrency = "sequential")) =~
             "concurrency must be a number, 1 for one at a time"

    assert step.("delay = -1") =~ "delay must be milliseconds 0 or more"
    assert step.("timeout = -1") =~ "timeout must be a number of seconds (0 for no limit)"
    assert step.("max_queue = 0") =~ "max_queue must be a number of items, 1 or more"
    assert step.(~s(on_full = "overflow")) =~ "on_full needs max_queue"
    assert step.(~s(max_queue = 5\non_full = "drop")) =~ ~s(on_full must be "wait" or "overflow")
    assert step.(~s(on_fail = "panic")) =~ ~s(on_fail must be "continue" or "end_run")
  end

  test "respond = \"stream\" loads" do
    workflow =
      load_workflow!(
        """
        [workflow]
        name = "streams"
        [trigger.webhook]
        path = "streams"
        respond = "stream"
        [[steps]]
        name = "a"
        node = "n.toml"
        """,
        %{"n.toml" => fake_node()}
      )

    assert workflow.respond == :stream
  end

  test "a Batch step needs a whole-number size, and wait if set" do
    batch = fn config ->
      problems(
        """
        [workflow]
        name = "b"
        [[steps]]
        name = "chunk"
        node = "chunk.toml"
        """,
        %{"chunk.toml" => ~s(module = "PurpleFlow.Nodes.Batch"\n[config]\n#{config})}
      )
    end

    assert batch.("") =~ "Batch needs `size`"
    assert batch.("size = 0") =~ "Batch size must be a whole number, 1 or more"
    assert batch.("size = 10\nwait = 1.5") =~ "Batch wait must be a whole number"
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

  # 100 branches that meet again make 2^100 paths from the first step to the
  # last; the checks must not walk them one by one.
  defp diamonds(n, extra \\ "") do
    steps =
      for i <- 1..n, into: "" do
        prev = if i == 1, do: "start", else: "merge_#{i - 1}"

        """
        [[steps]]
        name = "left_#{i}"
        node = "n.toml"
        after = ["#{prev}"]
        [[steps]]
        name = "right_#{i}"
        node = "n.toml"
        after = ["#{prev}"]
        [[steps]]
        name = "merge_#{i}"
        node = "n.toml"
        after = ["left_#{i}", "right_#{i}"]
        """
      end

    """
    [workflow]
    name = "diamonds"
    [[steps]]
    name = "start"
    node = "n.toml"
    #{extra}
    """ <> steps
  end

  test "branches that meet again, 100 times over, load quickly" do
    workflow = load_workflow!(diamonds(100), %{"n.toml" => fake_node()})
    assert length(workflow.steps) == 301
  end

  test "a loop behind 100 diamonds is still found" do
    assert problems(diamonds(100, ~s(after = ["merge_100"])), %{"n.toml" => fake_node()}) =~
             "loop back on themselves"
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

    test "max_upload defaults to 100 MB, takes 0 for no limit, and must be bytes" do
      assert load_workflow!(auth_workflow(""), %{"n.toml" => fake_node()}).max_upload ==
               100_000_000

      assert load_workflow!(auth_workflow("max_upload = 0"), %{"n.toml" => fake_node()}).max_upload ==
               0

      assert problems(auth_workflow(~s(max_upload = "big")), %{"n.toml" => fake_node()}) =~
               "webhook max_upload must be"
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

    test "a symlinked folder isn't searched for workflows", %{root: root, outside: outside} do
      File.write!(Path.join(outside, "workflow.toml"), "[workflow]\nname = \"sneaky\"")
      File.ln_s!(outside, Path.join(root, "sneaky"))

      assert {loaded, []} = Loader.load_all(root)
      refute Map.has_key?(loaded, "sneaky")
    end

    test "a nested workflow can reach shared files by climbing", %{root: root} do
      File.mkdir_p!(Path.join([root, "billing", "invoices"]))
      path = Path.join([root, "billing", "invoices", "workflow.toml"])

      File.write!(path, """
      [workflow]
      name = "invoices"
      [[steps]]
      name = "a"
      node = "../../shared/n.toml"
      """)

      assert {:ok, _} = Loader.load(path, root)
    end
  end

  describe "find/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "pf_find_#{System.unique_integer([:positive])}")
      File.rm_rf!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      for folder <- ["hello", "hello/tmp", "billing/invoices", "billing/reports/monthly"] do
        File.mkdir_p!(Path.join(root, folder))
        File.write!(Path.join([root, folder, "workflow.toml"]), "")
      end

      File.mkdir_p!(Path.join([root, "shared"]))
      File.mkdir_p!(Path.join([root, ".git", "wf"]))
      File.write!(Path.join([root, ".git", "wf", "workflow.toml"]), "")
      File.write!(Path.join(root, "workflow.toml"), "")
      %{root: root}
    end

    test "finds workflows at any depth, but not inside one or in dot-folders", %{root: root} do
      assert Loader.find(root) ==
               Enum.map(
                 ["billing/invoices", "billing/reports/monthly", "hello"],
                 &Path.join([root, &1, "workflow.toml"])
               )
    end
  end
end
