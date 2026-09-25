defmodule PurpleFlowWeb.WebhookControllerTest do
  use PurpleFlowWeb.ConnCase, async: false

  test "a known path starts a run and replies with its id", %{conn: conn} do
    Phoenix.PubSub.subscribe(PurpleFlow.PubSub, "runs")

    conn =
      conn
      |> put_req_header("authorization", "Bearer caller-secret")
      |> post("/hooks/echo?x=1", %{"hello" => "world"})

    assert %{"run_id" => run_id} = json_response(conn, 202)
    assert_receive {:run_finished, ^run_id, "complete"}, 5_000

    %{run: run} = PurpleFlow.Runs.get(run_id)
    assert run.trigger == "webhook"

    assert %{"body" => %{"hello" => "world"}, "query" => %{"x" => "1"}, "headers" => headers} =
             run.input

    refute Map.has_key?(headers, "authorization")
  end

  test "an unknown path is a 404", %{conn: conn} do
    assert %{"error" => _} = conn |> post("/hooks/nope") |> json_response(404)
  end
end
