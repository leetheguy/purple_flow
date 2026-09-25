defmodule PurpleFlow.NodesTest do
  use PurpleFlow.DataCase, async: false

  alias PurpleFlow.Nodes.{Code, Http, Postgres}

  describe "Http" do
    test "returns the decoded body" do
      Req.Test.stub(Http, fn conn ->
        assert conn.method == "POST"
        assert conn.query_string == "page=2"
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{"ok" => true}} =
               Http.execute(nil, %{
                 "method" => "POST",
                 "url" => "http://api.test/items",
                 "query" => %{"page" => 2},
                 "body" => %{"a" => 1}
               })
    end

    test "a non-2xx response is an error" do
      Req.Test.stub(Http, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.text("nope")
      end)

      assert {:error, "HTTP 500: nope"} = Http.execute(nil, %{"url" => "http://api.test/"})
    end
  end

  describe "Postgres" do
    setup do
      config = PurpleFlow.Repo.config()

      url =
        "postgres://#{config[:username]}:#{config[:password]}@#{config[:hostname]}:#{config[:port] || 5432}/#{config[:database]}"

      %{url: url}
    end

    test "returns rows as maps, with params", %{url: url} do
      assert {:ok, [%{"n" => 2, "word" => "hi"}]} =
               Postgres.execute(nil, %{
                 "database_url" => url,
                 "query" => "SELECT $1::int + 1 AS n, $2::text AS word",
                 "params" => [1, "hi"]
               })
    end

    test "a bad query is an error", %{url: url} do
      assert {:error, message} =
               Postgres.execute(nil, %{"database_url" => url, "query" => "SELECT nope"})

      assert message =~ "nope"
    end
  end

  describe "Code" do
    test "runs the script with input and steps" do
      dir = Path.join(System.tmp_dir!(), "pf_code_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "s.exs"), ~s|{:ok, input + steps["a"]["output"], "route"}|)

      {:ok, config} = Code.prepare(%{"file" => "s.exs"}, dir)
      assert {:ok, 5, "route"} = Code.execute(2, config, %{"a" => %{"output" => 3}})
    end

    test "a plain value becomes {:ok, value}" do
      dir = Path.join(System.tmp_dir!(), "pf_code_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "s.exs"), "input * 10")

      {:ok, config} = Code.prepare(%{"file" => "s.exs"}, dir)
      assert {:ok, 20} = Code.execute(2, config, %{})
    end
  end

  describe "Workflow" do
    test "runs another workflow and returns its output" do
      assert {:ok, %{"n" => 4}} =
               PurpleFlow.Nodes.Workflow.execute(%{"n" => 2}, %{"workflow" => "double"})
    end

    test "an unknown workflow is an error" do
      assert {:error, _} = PurpleFlow.Nodes.Workflow.execute(%{}, %{"workflow" => "nope"})
    end
  end
end
