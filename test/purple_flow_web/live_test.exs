defmodule PurpleFlowWeb.LiveTest do
  use PurpleFlowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PurpleFlow.WorkflowHelpers

  test "home lists workflows, and Run starts one", %{conn: conn} do
    Phoenix.PubSub.subscribe(PurpleFlow.PubSub, "runs")
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#workflow-echo")
    assert has_element?(view, "#workflow-double")

    view
    |> form("#run-form-echo", %{"workflow" => "echo", "input" => ~s({"a": 1})})
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    assert "/runs/" <> run_id = path

    # Let the run finish before the test (and its database sandbox) ends.
    assert_receive {:run_finished, ^run_id, "complete"}, 5_000

    # The box is just the body; the run's input is shaped like a webhook's.
    assert %{run: %{input: input}} = PurpleFlow.Runs.get(run_id)
    assert input == %{"body" => %{"a" => 1}, "query" => %{}, "headers" => %{}}
  end

  @tag :capture_log
  test "home follows reloads: a broken edit and a folder that won't load", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "pf_live_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.cp_r!("test/support/workflows/echo", Path.join(dir, "echo"))

    original = Application.get_env(:purple_flow, :workflows_dir)
    Application.put_env(:purple_flow, :workflows_dir, dir)
    :ok = PurpleFlow.Workflows.reload()

    on_exit(fn ->
      Application.put_env(:purple_flow, :workflows_dir, original)
      PurpleFlow.Workflows.reload()
      File.rm_rf!(dir)
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#workflow-echo")
    refute has_element?(view, "#stale-echo")
    refute has_element?(view, "#reload-button")

    File.write!(Path.join([dir, "echo", "workflow.toml"]), "[workflow\nname =")
    File.mkdir_p!(Path.join(dir, "draft"))
    File.write!(Path.join([dir, "draft", "workflow.toml"]), "[workflow]")
    :ok = PurpleFlow.Workflows.reload()

    # No refresh: the page hears the reload.
    assert has_element?(view, "#workflow-echo")
    assert has_element?(view, "#stale-echo")
    assert has_element?(view, "#load-error-draft")
  end

  test "search narrows the workflow list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#no-matches")

    view |> element("#workflows-search") |> render_keyup(%{"value" => "DOUB"})
    assert has_element?(view, "#workflow-double")
    refute has_element?(view, "#workflow-echo")

    view |> element("#workflows-search") |> render_keyup(%{"value" => "nothing-like-this"})
    assert has_element?(view, "#no-matches")

    view |> element("#workflows-search") |> render_keyup(%{"value" => ""})
    assert has_element?(view, "#workflow-echo")
    assert has_element?(view, "#workflow-double")
  end

  test "each workflow links to its folder in Files", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#files-echo")

    Application.put_env(:purple_flow, :files_url, "http://files:5000")
    on_exit(fn -> Application.delete_env(:purple_flow, :files_url) end)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s(#files-echo[href="/files/echo/"]))
  end

  describe "workflows in subfolders" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pf_tree_#{System.unique_integer([:positive])}")
      File.rm_rf!(dir)

      for {folder, name} <- [
            {"echo", "echo"},
            {"billing/invoices", "invoices"},
            {"billing/reports/monthly", "monthly"},
            {"my stuff/notes", "notes"}
          ] do
        path = Path.join(dir, folder)
        File.mkdir_p!(path)
        File.cp!("test/support/workflows/echo/echo.toml", Path.join(path, "echo.toml"))

        File.write!(Path.join(path, "workflow.toml"), """
        [workflow]
        name = "#{name}"

        [[steps]]
        name = "echo"
        node = "echo.toml"
        """)
      end

      File.mkdir_p!(Path.join(dir, "shared"))
      File.write!(Path.join([dir, "shared", "n.toml"]), "")

      original = Application.get_env(:purple_flow, :workflows_dir)
      Application.put_env(:purple_flow, :workflows_dir, dir)
      :ok = PurpleFlow.Workflows.reload()

      on_exit(fn ->
        Application.put_env(:purple_flow, :workflows_dir, original)
        PurpleFlow.Workflows.reload()
        File.rm_rf!(dir)
      end)
    end

    # Group and workflow ids in page order.
    defp listed(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#workflows [id^='group-'], #workflows [id^='workflow-']")
      |> LazyHTML.attribute("id")
    end

    test "groups come before workflows, and start collapsed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert listed(view) == ["group-billing", "group-my-stuff", "workflow-echo"]
      refute has_element?(view, "#group-shared")

      view |> element("#toggle-group-billing") |> render_click()
      view |> element("#toggle-group-billing--reports") |> render_click()
      view |> element("#toggle-group-my-stuff") |> render_click()

      assert listed(view) == [
               "group-billing",
               "group-billing--reports",
               "workflow-monthly",
               "workflow-invoices",
               "group-my-stuff",
               "workflow-notes",
               "workflow-echo"
             ]

      # Closing a group hides everything in it; reopening keeps what was open inside.
      view |> element("#toggle-group-billing") |> render_click()
      refute has_element?(view, "#workflow-invoices")
      view |> element("#toggle-group-billing") |> render_click()
      assert has_element?(view, "#workflow-monthly")
    end

    test "search opens the groups it matches in, and hides the rest", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#workflows-search") |> render_keyup(%{"value" => "month"})
      assert listed(view) == ["group-billing", "group-billing--reports", "workflow-monthly"]

      view |> element("#workflows-search") |> render_keyup(%{"value" => "billing"})

      assert listed(view) -- ["group-billing", "group-billing--reports"] ==
               ["workflow-monthly", "workflow-invoices"]

      # Clearing the search collapses them again.
      view |> element("#workflows-search") |> render_keyup(%{"value" => ""})
      refute has_element?(view, "#workflow-monthly")
    end

    test "Files links open the nested folder", %{conn: conn} do
      Application.put_env(:purple_flow, :files_url, "http://files:5000")
      on_exit(fn -> Application.delete_env(:purple_flow, :files_url) end)

      {:ok, view, _html} = live(conn, ~p"/")

      for group <- ["billing", "billing--reports", "my-stuff"],
          do: view |> element("#toggle-group-#{group}") |> render_click()

      assert has_element?(view, ~s(#files-invoices[href="/files/billing/invoices/"]))
      assert has_element?(view, ~s(#files-monthly[href="/files/billing/reports/monthly/"]))
      assert has_element?(view, ~s(#files-notes[href="/files/my%20stuff/notes/"]))
    end
  end

  test "bad JSON input shows an error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#run-form-echo", %{"workflow" => "echo", "input" => "{nope"})
      |> render_submit()

    assert html =~ "isn&#39;t valid JSON"
  end

  test "run page shows steps, and rows expand to show input and output", %{conn: conn} do
    {:ok, workflow} = PurpleFlow.Workflows.fetch("echo")
    result = run!(workflow, %{"hello" => "world"})

    {:ok, view, _html} = live(conn, ~p"/runs/#{result.run.id}")
    assert has_element?(view, "#run-status", "complete")
    assert has_element?(view, "#step-echo")

    html = view |> element("#step-echo button") |> render_click()
    assert html =~ "hello"
  end

  test "per-item steps expand into one row per item", %{conn: conn} do
    {:ok, workflow} = PurpleFlow.Workflows.fetch("echo")
    result = run!(workflow, [1, 2, 3])

    {:ok, view, _html} = live(conn, ~p"/runs/#{result.run.id}")
    view |> element("#step-echo button") |> render_click()
    assert has_element?(view, "#step-echo-item-0")
    assert has_element?(view, "#step-echo-item-2")
  end

  test "each step shows ok / total, with a dot for all, some, or none ok", %{conn: conn} do
    workflow =
      steps!(
        "tally",
        """
        [[steps]]
        name = "all_ok"
        node = "n.toml"
        [[steps]]
        name = "some_ok"
        node = "some.toml"
        [[steps]]
        name = "none_ok"
        node = "none.toml"
        """,
        %{
          "n.toml" => fake_node(),
          "some.toml" => fake_node(%{"fail_if" => 2}),
          "none.toml" => fake_node(%{"raise" => true})
        }
      )

    result = run!(workflow, [1, 2, 3])
    {:ok, view, _html} = live(conn, ~p"/runs/#{result.run.id}")

    assert has_element?(view, "#step-all_ok-counts", "3/3")
    assert has_element?(view, "#step-some_ok-counts", "2/3")
    assert has_element?(view, "#step-none_ok-counts", "0/3")
    assert has_element?(view, "#step-all_ok-dot[data-status=ok]")
    assert has_element?(view, "#step-some_ok-dot[data-status=partial]")
    assert has_element?(view, "#step-none_ok-dot[data-status=failed]")
    refute has_element?(view, "#kill-run")
  end

  test "a running run shows what's queued and running, and Kill stops it", %{conn: conn} do
    workflow =
      steps!(
        "killable",
        """
        [[steps]]
        name = "slow"
        node = "slow.toml"
        concurrency = 1
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 60_000})}
      )

    id = start!(workflow, [1, 2])
    {:ok, view, _html} = live(conn, ~p"/runs/#{id}")
    assert_receive {:run_progress, ^id, _}, 1_000

    # The page hears the same progress message.
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#step-slow-live", "queue 1 · running 1/1")

    view |> element("#kill-run") |> render_click()
    assert_receive {:run_finished, ^id, "killed"}, 5_000
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#run-status", "killed")
    assert has_element?(view, "#run-killed")
    refute has_element?(view, "#kill-run")
  end

  test "the runs list has Kill for a running run", %{conn: conn} do
    workflow =
      steps!(
        "killable_list",
        """
        [[steps]]
        name = "slow"
        node = "slow.toml"
        """,
        %{"slow.toml" => fake_node(%{"sleep" => 60_000})}
      )

    id = start!(workflow, 1)
    {:ok, view, _html} = live(conn, ~p"/workflows/killable_list")

    view |> element("#kill-#{id}") |> render_click()
    assert_receive {:run_finished, ^id, "killed"}, 5_000
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#kill-#{id}")
  end

  test "runs list shows the workflow's runs", %{conn: conn} do
    {:ok, workflow} = PurpleFlow.Workflows.fetch("echo")
    result = run!(workflow, 1)

    {:ok, view, _html} = live(conn, ~p"/workflows/echo")
    assert has_element?(view, "#run-#{result.run.id}")
  end
end
