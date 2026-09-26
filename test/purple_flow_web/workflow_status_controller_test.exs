defmodule PurpleFlowWeb.WorkflowStatusControllerTest do
  use PurpleFlowWeb.ConnCase, async: false

  # Not async: sets the env var the controller reads per request.

  defp with_token(_context) do
    System.put_env("PURPLEFLOW_AGENT_TOKEN", "agent-secret")
    on_exit(fn -> System.delete_env("PURPLEFLOW_AGENT_TOKEN") end)
  end

  test "doesn't exist without a token configured", %{conn: conn} do
    System.delete_env("PURPLEFLOW_AGENT_TOKEN")
    conn = conn |> put_req_header("authorization", "Bearer anything") |> get("/api/workflows")
    assert json_response(conn, 404)
  end

  describe "with a token configured" do
    setup :with_token

    test "a missing or wrong token gets 401", %{conn: conn} do
      assert json_response(get(conn, "/api/workflows"), 401)

      conn = conn |> put_req_header("authorization", "Bearer nope") |> get("/api/workflows")
      assert json_response(conn, 401)
    end

    test "the right token gets every workflow and its state", %{conn: conn} do
      conn =
        conn |> put_req_header("authorization", "Bearer agent-secret") |> get("/api/workflows")

      assert %{"reloaded_at" => reloaded_at, "workflows" => workflows, "not_loaded" => []} =
               json_response(conn, 200)

      assert {:ok, _, _} = DateTime.from_iso8601(reloaded_at)

      assert %{
               "folder" => "echo",
               "webhook" => "echo",
               "cron" => nil,
               "problems" => [],
               "running_older_version" => false,
               "loaded_at" => _
             } = Enum.find(workflows, &(&1["name"] == "echo"))
    end

    test "the admin login is not required, and doesn't help", %{conn: conn} do
      System.put_env("PURPLEFLOW_ADMIN_USERNAME", "admin")
      System.put_env("PURPLEFLOW_ADMIN_PASSWORD", "hunter2")

      on_exit(fn ->
        System.delete_env("PURPLEFLOW_ADMIN_USERNAME")
        System.delete_env("PURPLEFLOW_ADMIN_PASSWORD")
      end)

      admin =
        conn
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("admin", "hunter2"))

      assert json_response(get(admin, "/api/workflows"), 401)

      agent = conn |> put_req_header("authorization", "Bearer agent-secret")
      assert json_response(get(agent, "/api/workflows"), 200)
    end
  end
end
