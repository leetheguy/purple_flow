defmodule PurpleFlowWeb.CanvasLiveTest do
  use PurpleFlowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PurpleFlow.WorkflowHelpers

  setup do
    dir = Path.join(System.tmp_dir!(), "pf_canvas_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)

    write = fn path, contents ->
      path = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    write.("main/workflow.toml", """
    # Checks numbers.
    #
    # Big ones get shouted.

    [workflow]
    name = "main"

    [trigger.webhook]
    path = "main"

    [[steps]]
    name = "check"
    node = "check.toml"

    [[steps]]
    name = "big"
    node = "loud.toml"
    after = ["check"]
    when = "big"

    [[steps]]
    name = "enrich"
    node = "enrich.toml"
    after = ["check"]

    [[steps]]
    name = "last"
    node = "loud.toml"
    after = ["big", "enrich"]
    """)

    write.("main/check.toml", "# Sends each number down big or small.\n" <> fake_node())
    write.("main/loud.toml", fake_node())

    write.("main/enrich.toml", """
    # Runs the sub workflow.
    module = "PurpleFlow.Nodes.Workflow"

    [config]
    workflow = "sub"
    """)

    write.("group/sub/workflow.toml", """
    [workflow]
    name = "sub"

    [[steps]]
    name = "only"
    node = "only.toml"
    """)

    write.("group/sub/only.toml", fake_node())

    original = Application.get_env(:purple_flow, :workflows_dir)
    Application.put_env(:purple_flow, :workflows_dir, dir)
    :ok = PurpleFlow.Workflows.reload()

    on_exit(fn ->
      Application.put_env(:purple_flow, :workflows_dir, original)
      PurpleFlow.Workflows.reload()
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Box ids, row by row.
  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#canvas [data-world] > div > div")
    |> Enum.map(fn row ->
      row |> LazyHTML.query("[data-node]") |> LazyHTML.attribute("id")
    end)
  end

  test "the Workflows page shows the comment and links to the canvas", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#comment-main", "Big ones get shouted.")
    refute has_element?(view, "#comment-sub")

    view |> element("#canvas-main") |> render_click()
    assert_redirect(view, ~p"/workflows/main/canvas")
  end

  test "steps are laid out in rows, with their kinds, names, and comments", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows/main/canvas")

    assert rows(view) == [
             ["canvas-start"],
             ["canvas-step-check"],
             ["canvas-step-big", "canvas-step-enrich"],
             ["canvas-step-last"]
           ]

    assert has_element?(view, "#canvas-start [data-comment]", "Checks numbers.")
    assert has_element?(view, "#canvas-start", "/hooks/main")
    assert has_element?(view, "#canvas-step-check [data-comment]", "down big or small")
    refute has_element?(view, "#canvas-step-big [data-comment]")
    assert has_element?(view, "#canvas-step-enrich [data-kind]", "Workflow")
    assert has_element?(view, "#canvas-step-check [data-kind]", "FakeNode")

    for id <- ~w(canvas-zoom-out canvas-zoom-reset canvas-zoom-in),
        do: assert(has_element?(view, "##{id}"))

    edges = view |> element("#canvas") |> render() |> edges()

    assert Enum.sort(edges) ==
             Enum.sort([
               ["", "check", nil],
               ["check", "big", "big"],
               ["check", "enrich", nil],
               ["big", "last", nil],
               ["enrich", "last", nil]
             ])
  end

  test "a Workflow step opens the other workflow's canvas", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows/main/canvas")
    assert has_element?(view, ~s(#canvas-step-enrich[href="/workflows/sub/canvas"]))
    # No files service here, so other steps aren't links.
    refute has_element?(view, "a#canvas-step-check")
  end

  test "steps open their node file in Files", %{conn: conn} do
    Application.put_env(:purple_flow, :files_url, "http://files:5000")
    on_exit(fn -> Application.delete_env(:purple_flow, :files_url) end)

    {:ok, view, _html} = live(conn, ~p"/workflows/main/canvas")
    assert has_element?(view, ~s(#canvas-step-check[href="/files/main/check.toml?edit"]))
    assert has_element?(view, ~s(#canvas-start[href="/files/main/workflow.toml?edit"]))
    assert has_element?(view, ~s(#canvas-step-enrich[href="/workflows/sub/canvas"]))

    {:ok, view, _html} = live(conn, ~p"/workflows/sub/canvas")
    assert has_element?(view, ~s(#canvas-step-only[href="/files/group/sub/only.toml?edit"]))
  end

  test "the canvas follows reloads", %{conn: conn, dir: dir} do
    {:ok, view, _html} = live(conn, ~p"/workflows/sub/canvas")
    refute has_element?(view, "#canvas-step-only [data-comment]")

    File.write!(Path.join(dir, "group/sub/only.toml"), "# Now it says.\n" <> fake_node())
    :ok = PurpleFlow.Workflows.reload()

    assert has_element?(view, "#canvas-step-only [data-comment]", "Now it says.")
  end

  test "an unknown workflow says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows/nope/canvas")
    assert has_element?(view, "#canvas-missing")
  end

  defp edges(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-edges")
    |> hd()
    |> Jason.decode!()
  end
end
