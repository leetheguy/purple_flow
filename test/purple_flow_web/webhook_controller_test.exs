defmodule PurpleFlowWeb.WebhookControllerTest do
  use PurpleFlowWeb.ConnCase, async: false

  test "by default, the reply is the run's output", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer caller-secret")
      |> post("/hooks/echo?x=1", %{"hello" => "world"})

    # The echo workflow returns its input, so the output is the webhook input.
    assert %{"body" => %{"hello" => "world"}, "query" => %{"x" => "1"}, "headers" => headers} =
             json_response(conn, 200)

    refute Map.has_key?(headers, "authorization")

    [run_id] = get_resp_header(conn, "x-run-id")
    assert %{run: %{trigger: "webhook", status: "complete"}} = PurpleFlow.Runs.get(run_id)
  end

  test "a failed run replies 500 with the error", %{conn: conn} do
    conn = post(conn, "/hooks/boom")
    assert %{"error" => error, "run_id" => _} = json_response(conn, 500)
    assert error =~ "kaboom"
  end

  test "respond = \"immediately\" replies right away with the run id", %{conn: conn} do
    Phoenix.PubSub.subscribe(PurpleFlow.PubSub, "runs")

    assert %{"run_id" => run_id} = conn |> post("/hooks/echo-later") |> json_response(202)

    # Let the run finish before the test's database sandbox goes away.
    assert_receive {:run_finished, ^run_id, "complete"}, 5_000
  end

  test "an unknown path is a 404", %{conn: conn} do
    assert %{"error" => _} = conn |> post("/hooks/nope") |> json_response(404)
  end
end
