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

    test "stream = \"sse\" emits one item per event" do
      Req.Test.stub(Http, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        : a comment
        event: delta
        data: {"text": "Hel"}

        data: lo
        data: world
        id: 7

        data: [DONE]

        data: cut off
        """)
      end)

      assert {:ok, []} = Http.execute(nil, %{"url" => "http://api.test/", "stream" => "sse"})
      assert_received {:emit, %{"event" => "delta", "data" => %{"text" => "Hel"}}, nil}
      assert_received {:emit, %{"event" => "message", "data" => "lo\nworld", "id" => "7"}, nil}
      assert_received {:emit, %{"event" => "message", "data" => "[DONE]"}, nil}
      refute_received {:emit, %{"data" => "cut off"}, _}
    end

    test "stream = \"ndjson\" and \"lines\" emit one item per line, even the last with no newline" do
      Req.Test.stub(Http, fn conn ->
        Plug.Conn.send_resp(conn, 200, "{\"n\": 1}\n\n{\"n\": 2}")
      end)

      assert {:ok, []} = Http.execute(nil, %{"url" => "http://api.test/", "stream" => "ndjson"})
      assert_received {:emit, %{"n" => 1}, nil}
      assert_received {:emit, %{"n" => 2}, nil}

      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 200, "one\r\ntwo") end)
      assert {:ok, []} = Http.execute(nil, %{"url" => "http://api.test/", "stream" => "lines"})
      assert_received {:emit, "one", nil}
      assert_received {:emit, "two", nil}
    end

    test "a streamed non-2xx response is an error and emits nothing" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 503, "data: busy\n\n") end)

      assert {:error, "HTTP 503: data: busy" <> _} =
               Http.execute(nil, %{"url" => "http://api.test/", "stream" => "sse"})

      refute_received {:emit, _, _}
    end

    test "streamed messages split across chunks come out whole" do
      chunks = ["data: {\"a\"", ": 1}\n", "\nda", "ta: two\n\n"]

      {items, _parser} =
        Enum.flat_map_reduce(chunks, PurpleFlow.StreamParser.new(), fn chunk, parser ->
          PurpleFlow.StreamParser.parse("sse", parser, chunk)
        end)

      assert items == [
               %{"event" => "message", "data" => %{"a" => 1}},
               %{"event" => "message", "data" => "two"}
             ]
    end

    test "an unknown stream protocol fails at load time" do
      assert {:error, "stream must be" <> _} =
               Http.prepare(%{"stream" => "carrier pigeon"}, ".", ".")
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

      {:ok, config} = Code.prepare(%{"file" => "s.exs"}, dir, dir)
      assert {:ok, 5, "route"} = Code.execute(2, config, %{"a" => %{"output" => 3}})
    end

    test "a plain value becomes {:ok, value}" do
      dir = Path.join(System.tmp_dir!(), "pf_code_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "s.exs"), "input * 10")

      {:ok, config} = Code.prepare(%{"file" => "s.exs"}, dir, dir)
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

  describe "Noop" do
    test "hands its input on unchanged" do
      assert {:ok, %{"a" => [1, 2]}} = PurpleFlow.Nodes.Noop.execute(%{"a" => [1, 2]}, %{})
    end
  end

  describe "Wait" do
    alias PurpleFlow.Nodes.Wait

    test "waits ms, then hands its input on" do
      {time, result} = :timer.tc(fn -> Wait.execute("x", %{"ms" => 50}) end, :millisecond)
      assert result == {:ok, "x"}
      assert time >= 50
    end

    test "ms may arrive as text from a template" do
      assert {:ok, 1} = Wait.execute(1, %{"ms" => "5"})
      assert {:error, "Wait ms must be" <> _} = Wait.execute(1, %{"ms" => "soon"})
    end

    test "until waits for a time; a past time doesn't wait" do
      soon = DateTime.utc_now() |> DateTime.add(50, :millisecond) |> DateTime.to_iso8601()
      {time, {:ok, 1}} = :timer.tc(fn -> Wait.execute(1, %{"until" => soon}) end, :millisecond)
      assert time >= 40

      assert {:ok, 1} = Wait.execute(1, %{"until" => "2000-01-01T00:00:00Z"})
      assert {:error, "Wait until must be" <> _} = Wait.execute(1, %{"until" => "tomorrow"})
    end

    test "prepare wants exactly one of ms or until, and checks plain values" do
      assert {:ok, _} = Wait.prepare(%{"ms" => 10}, ".", ".")
      assert {:ok, _} = Wait.prepare(%{"ms" => "{{ input.ms }}"}, ".", ".")
      assert {:ok, _} = Wait.prepare(%{"until" => "2030-01-01T00:00:00Z"}, ".", ".")
      assert {:error, _} = Wait.prepare(%{}, ".", ".")
      assert {:error, _} = Wait.prepare(%{"ms" => 1, "until" => "2030-01-01T00:00:00Z"}, ".", ".")
      assert {:error, _} = Wait.prepare(%{"ms" => -1}, ".", ".")
      assert {:error, _} = Wait.prepare(%{"until" => "noon"}, ".", ".")
    end
  end

  describe "Respond" do
    alias PurpleFlow.Nodes.Respond

    test "answers with the input by default and hands it on" do
      assert {:ok, %{"a" => 1}} = Respond.execute(%{"a" => 1}, %{})

      assert_received {:respond, %{"status" => 200, "headers" => %{}, "body" => %{"a" => 1}}}
    end

    test "status, headers, and body come from config" do
      config = %{"status" => "201", "headers" => %{"X-Id" => 7}, "body" => "made"}
      assert {:ok, "in"} = Respond.execute("in", config)

      assert_received {:respond,
                       %{"status" => 201, "headers" => %{"x-id" => "7"}, "body" => "made"}}
    end

    test "a bad status or header is an error, and nothing is sent" do
      assert {:error, "Respond status" <> _} = Respond.execute(1, %{"status" => 99})

      assert {:error, "Respond header" <> _} =
               Respond.execute(1, %{"headers" => %{"a" => "x\ny"}})

      assert {:error, "Respond headers" <> _} = Respond.execute(1, %{"headers" => "a"})
      refute_received {:respond, _}
    end

    test "prepare checks plain values and leaves templates for later" do
      assert {:ok, _} = Respond.prepare(%{"status" => "{{ input.status }}"}, ".", ".")
      assert {:error, _} = Respond.prepare(%{"status" => 700}, ".", ".")
      assert {:error, _} = Respond.prepare(%{"headers" => []}, ".", ".")
    end
  end
end
