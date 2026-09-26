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

  describe "auth" do
    setup do
      {:ok, cred} = PurpleFlow.Credentials.create("HOOK_TOKEN", "")
      {:ok, _} = PurpleFlow.Credentials.update(cred.id, %{key: "s3cret"})

      dir = Path.join(System.tmp_dir!(), "pf_hooks_#{System.unique_integer([:positive])}")

      for {name, webhook} <- [
            {"guarded", ~s(auth = "HOOK_TOKEN")},
            {"telegram", ~s(auth = "HOOK_TOKEN"\nauth_header = "X-Telegram-Bot-Api-Secret-Token")}
          ] do
        File.mkdir_p!(Path.join(dir, name))
        File.write!(Path.join([dir, name, "echo.toml"]), ~s(module = "PurpleFlow.Test.FakeNode"))

        File.write!(Path.join([dir, name, "workflow.toml"]), """
        [workflow]
        name = "#{name}"

        [trigger.webhook]
        path = "#{name}"
        #{webhook}

        [[steps]]
        name = "echo"
        node = "echo.toml"
        """)
      end

      original = Application.get_env(:purple_flow, :workflows_dir)
      Application.put_env(:purple_flow, :workflows_dir, dir)
      :ok = PurpleFlow.Workflows.reload()
      assert PurpleFlow.Workflows.errors() == []

      on_exit(fn ->
        Application.put_env(:purple_flow, :workflows_dir, original)
        PurpleFlow.Workflows.reload()
      end)

      %{cred: cred}
    end

    defp run_count, do: PurpleFlow.Repo.aggregate(PurpleFlow.Runs.Run, :count)

    test "the right bearer token starts a run", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer s3cret") |> post("/hooks/guarded")
      assert %{"headers" => headers} = json_response(conn, 200)
      refute Map.has_key?(headers, "authorization")
    end

    test "the Bearer scheme is case-insensitive", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "bearer s3cret") |> post("/hooks/guarded")
      assert json_response(conn, 200)
    end

    test "a missing or wrong token gets an empty 401 and records no run", %{conn: conn} do
      before = run_count()

      for header <- [nil, "Bearer nope", "s3cret", "Basic s3cret"] do
        conn = if header, do: put_req_header(conn, "authorization", header), else: conn
        assert conn |> post("/hooks/guarded") |> response(401) == ""
      end

      assert run_count() == before
    end

    test "an archived credential gets 401", %{conn: conn, cred: cred} do
      {:ok, _} = PurpleFlow.Credentials.archive(cred.id)

      conn = conn |> put_req_header("authorization", "Bearer s3cret") |> post("/hooks/guarded")
      assert response(conn, 401) == ""
    end

    test "auth_header reads the bare token from that header, never saving it", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", "s3cret")
        |> post("/hooks/telegram")

      assert %{"headers" => headers} = json_response(conn, 200)
      refute Map.has_key?(headers, "x-telegram-bot-api-secret-token")
    end

    test "with auth_header, a Bearer prefix or the default header doesn't count", %{conn: conn} do
      assert conn
             |> put_req_header("x-telegram-bot-api-secret-token", "Bearer s3cret")
             |> post("/hooks/telegram")
             |> response(401)

      assert conn
             |> put_req_header("authorization", "Bearer s3cret")
             |> post("/hooks/telegram")
             |> response(401)
    end
  end
end
