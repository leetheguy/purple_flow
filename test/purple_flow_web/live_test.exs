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
    assert path =~ "/runs/"

    # Let the run finish before the test (and its database sandbox) ends.
    assert_receive {:run_finished, _id, "complete"}, 5_000
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

  test "runs list shows the workflow's runs", %{conn: conn} do
    {:ok, workflow} = PurpleFlow.Workflows.fetch("echo")
    result = run!(workflow, 1)

    {:ok, view, _html} = live(conn, ~p"/workflows/echo")
    assert has_element?(view, "#run-#{result.run.id}")
  end
end
