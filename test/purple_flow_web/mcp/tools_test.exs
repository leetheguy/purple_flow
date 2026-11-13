defmodule PurpleFlowWeb.MCP.ToolsTest do
  use ExUnit.Case, async: false

  # Not async: sets the agent token in the environment and the files
  # service's address in the app's config.

  alias PurpleFlowWeb.MCP.Tools
  alias PurpleFlowWeb.Plugs.FilesProxy

  @dufs_login "Basic " <> Base.encode64("purpleflow:agent-token")

  setup do
    System.put_env("PURPLEFLOW_AGENT_TOKEN", "agent-token")
    Application.put_env(:purple_flow, :files_url, "http://files:5000")

    on_exit(fn ->
      System.delete_env("PURPLEFLOW_AGENT_TOKEN")
      Application.delete_env(:purple_flow, :files_url)
    end)

    :ok
  end

  # A stand-in for dufs: reports each request it gets to the test, then
  # answers with `reply`.
  defp dufs(reply) do
    test = self()

    Req.Test.stub(FilesProxy, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:dufs, conn.method, conn.request_path, conn.query_string, body,
         Map.new(conn.req_headers)}
      )

      reply.(conn)
    end)
  end

  defp ok(conn), do: Plug.Conn.send_resp(conn, 201, "")

  defp listing(paths) do
    fn conn -> Req.Test.json(conn, %{"kind" => "Index", "paths" => paths}) end
  end

  defp text(%{"content" => [%{"type" => "text", "text" => text}]}), do: text

  describe "the tool list" do
    test "lists the eleven tools in a fixed order, each with an input schema" do
      tools = Tools.list()

      assert Enum.map(tools, & &1["name"]) ==
               ~w(list search read stat hash write append mkdir copy move delete)

      for tool <- tools do
        assert tool["inputSchema"]["type"] == "object"
        assert tool["inputSchema"]["additionalProperties"] == false
        assert "path" in tool["inputSchema"]["required"]
        assert is_binary(tool["description"])
      end
    end
  end

  describe "list" do
    test "asks dufs for the folder as JSON and returns its entries" do
      dufs(
        listing([
          %{"path_type" => "Dir", "name" => "b", "mtime" => 1_794_540_740_497, "size" => 1},
          %{"path_type" => "File", "name" => "x.toml", "mtime" => 0, "size" => 42}
        ])
      )

      assert {:ok, %{"isError" => false, "structuredContent" => result}} =
               Tools.call("list", %{"path" => "hello"})

      assert_received {:dufs, "GET", "/fs/hello/", "json", "", headers}
      assert headers["authorization"] == @dufs_login

      assert result == %{
               "entries" => [
                 %{
                   "name" => "b",
                   "type" => "dir",
                   "size" => 1,
                   "mtime" => "2026-11-13T03:32:20.497Z"
                 },
                 %{
                   "name" => "x.toml",
                   "type" => "file",
                   "size" => 42,
                   "mtime" => "1970-01-01T00:00:00.000Z"
                 }
               ]
             }
    end

    test "the top of the folder is an empty path or a slash" do
      dufs(listing([]))

      assert {:ok, %{"isError" => false}} = Tools.call("list", %{"path" => ""})
      assert_received {:dufs, "GET", "/fs/", "json", _, _}
      assert {:ok, %{"isError" => false}} = Tools.call("list", %{"path" => "/"})
      assert_received {:dufs, "GET", "/fs/", "json", _, _}
    end

    test "a folder that isn't there is a tool error" do
      dufs(&Plug.Conn.send_resp(&1, 404, "Not Found"))

      assert {:ok, %{"isError" => true} = result} = Tools.call("list", %{"path" => "nope"})
      assert text(result) =~ "nothing at nope"
    end
  end

  describe "search" do
    test "searches under the folder and returns paths relative to it" do
      dufs(listing([%{"path_type" => "File", "name" => "b/x.txt", "mtime" => 0, "size" => 3}]))

      assert {:ok, %{"structuredContent" => %{"entries" => [entry]}}} =
               Tools.call("search", %{"path" => "a", "query" => "x y"})

      assert_received {:dufs, "GET", "/fs/a/", query, _, _}
      assert URI.decode_query(query) == %{"q" => "x y", "json" => ""}
      assert entry["name"] == "b/x.txt"
    end
  end

  describe "read" do
    test "returns a text file's content as text" do
      dufs(&Plug.Conn.send_resp(&1, 200, "name = \"hello\"\n"))

      assert {:ok, %{"isError" => false} = result} =
               Tools.call("read", %{"path" => "hello/workflow.toml"})

      assert_received {:dufs, "GET", "/fs/hello/workflow.toml", "", _, headers}
      refute Map.has_key?(headers, "range")
      assert text(result) == "name = \"hello\"\n"
    end

    test "returns a binary file as base64, with the exact bytes" do
      dufs(&Plug.Conn.send_resp(&1, 200, <<255, 0, 1>>))

      assert {:ok, %{"structuredContent" => result}} = Tools.call("read", %{"path" => "a/bin"})
      assert result == %{"encoding" => "base64", "content" => Base.encode64(<<255, 0, 1>>)}
    end

    test "with offset and length, asks for only that range" do
      dufs(&Plug.Conn.send_resp(&1, 206, "wo"))

      assert {:ok, result} =
               Tools.call("read", %{"path" => "w.txt", "offset" => 1, "length" => 2})

      assert_received {:dufs, "GET", "/fs/w.txt", _, _, %{"range" => "bytes=1-2"}}
      assert text(result) == "wo"
    end

    test "offset 0 and length 1 is the first byte" do
      dufs(&Plug.Conn.send_resp(&1, 206, "w"))

      assert {:ok, %{"isError" => false}} =
               Tools.call("read", %{"path" => "w.txt", "offset" => 0, "length" => 1})

      assert_received {:dufs, "GET", "/fs/w.txt", _, _, %{"range" => "bytes=0-0"}}
    end

    test "offset without length, a negative offset, or a length under 1, is a bad argument" do
      assert {:error, {:invalid_arguments, _}} =
               Tools.call("read", %{"path" => "w", "offset" => -1, "length" => 1})

      assert {:error, {:invalid_arguments, _}} =
               Tools.call("read", %{"path" => "w", "offset" => 1})

      assert {:error, {:invalid_arguments, _}} =
               Tools.call("read", %{"path" => "w", "offset" => 0, "length" => 0})
    end
  end

  describe "stat" do
    test "reports a file's type, size, time, and etag" do
      dufs(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("1794540740497-3"))
        |> Plug.Conn.put_resp_header("last-modified", "Fri, 13 Nov 2026 03:32:20 GMT")
        |> Plug.Conn.put_resp_header("content-length", "3")
        |> Plug.Conn.send_resp(200, "")
      end)

      assert {:ok, %{"structuredContent" => result}} = Tools.call("stat", %{"path" => "x.txt"})
      assert_received {:dufs, "HEAD", "/fs/x.txt", _, _, _}

      assert result == %{
               "exists" => true,
               "type" => "file",
               "size" => 3,
               "mtime" => "2026-11-13T03:32:20Z",
               "etag" => ~s("1794540740497-3")
             }
    end

    test "a folder has no etag" do
      dufs(&Plug.Conn.send_resp(&1, 200, ""))

      assert {:ok, %{"structuredContent" => %{"exists" => true, "type" => "dir"}}} =
               Tools.call("stat", %{"path" => "a"})
    end

    test "a missing path is exists: false, not an error" do
      dufs(&Plug.Conn.send_resp(&1, 404, ""))

      assert {:ok, %{"isError" => false, "structuredContent" => %{"exists" => false}}} =
               Tools.call("stat", %{"path" => "nope"})
    end
  end

  describe "hash" do
    test "returns the file's SHA-256" do
      dufs(&Plug.Conn.send_resp(&1, 200, "98ea6e4f"))

      assert {:ok, %{"structuredContent" => %{"sha256" => "98ea6e4f"}}} =
               Tools.call("hash", %{"path" => "x.txt"})

      assert_received {:dufs, "GET", "/fs/x.txt", "hash", _, _}
    end
  end

  describe "the tools that change files" do
    test "write sends the text as the file" do
      dufs(&ok/1)

      assert {:ok, %{"isError" => false}} =
               Tools.call("write", %{"path" => "n/e/w.txt", "content" => "one"})

      assert_received {:dufs, "PUT", "/fs/n/e/w.txt", _, "one", _}
    end

    test "write with base64 content sends the exact bytes" do
      dufs(&ok/1)

      assert {:ok, %{"isError" => false}} =
               Tools.call("write", %{
                 "path" => "a/bin",
                 "content" => Base.encode64(<<255, 0>>),
                 "encoding" => "base64"
               })

      assert_received {:dufs, "PUT", "/fs/a/bin", _, <<255, 0>>, _}
    end

    test "write with content that isn't base64 is a bad argument, and nothing is sent" do
      dufs(&ok/1)

      assert {:error, {:invalid_arguments, _}} =
               Tools.call("write", %{"path" => "a", "content" => "!!", "encoding" => "base64"})

      refute_received {:dufs, _, _, _, _, _}
    end

    test "encoding text sends the content as is; another encoding is a bad argument" do
      dufs(&ok/1)

      assert {:ok, %{"isError" => false}} =
               Tools.call("write", %{"path" => "a", "content" => "AA==", "encoding" => "text"})

      assert_received {:dufs, "PUT", "/fs/a", _, "AA==", _}

      assert {:error, {:invalid_arguments, _}} =
               Tools.call("write", %{"path" => "a", "content" => "AA", "encoding" => "hex"})
    end

    test "append adds to the end" do
      dufs(&Plug.Conn.send_resp(&1, 204, ""))

      assert {:ok, %{"isError" => false}} =
               Tools.call("append", %{"path" => "w.txt", "content" => "+more"})

      assert_received {:dufs, "PATCH", "/fs/w.txt", _, "+more", %{"x-update-range" => "append"}}
    end

    test "mkdir makes a folder" do
      dufs(&ok/1)
      assert {:ok, %{"isError" => false}} = Tools.call("mkdir", %{"path" => "m"})
      assert_received {:dufs, "MKCOL", "/fs/m", _, _, _}
    end

    test "copy and move send a Destination on the files service" do
      dufs(&Plug.Conn.send_resp(&1, 204, ""))

      assert {:ok, %{"isError" => false}} =
               Tools.call("copy", %{"path" => "a.txt", "destination" => "m/c.txt"})

      assert_received {:dufs, "COPY", "/fs/a.txt", _, _,
                       %{"destination" => "http://files:5000/fs/m/c.txt"}}

      assert {:ok, %{"isError" => false}} =
               Tools.call("move", %{"path" => "m/c.txt", "destination" => "m/d.txt"})

      assert_received {:dufs, "MOVE", "/fs/m/c.txt", _, _,
                       %{"destination" => "http://files:5000/fs/m/d.txt"}}
    end

    test "delete removes the path" do
      dufs(&Plug.Conn.send_resp(&1, 204, ""))
      assert {:ok, %{"isError" => false}} = Tools.call("delete", %{"path" => "n"})
      assert_received {:dufs, "DELETE", "/fs/n", _, _, _}
    end
  end

  describe "paths" do
    test "a name with a space, ?, #, or % reaches the file with that exact name" do
      dufs(&Plug.Conn.send_resp(&1, 200, "x"))

      assert {:ok, _} = Tools.call("read", %{"path" => "a b/c?d#e%f.txt"})
      assert_received {:dufs, "GET", path, "", _, _}
      assert path == "/fs/a%20b/c%3Fd%23e%25f.txt"
    end

    test "..  . \\ and NUL are refused, and nothing reaches dufs" do
      dufs(&ok/1)

      for path <- ["../x", "a/../../x", "a/./b", "a\\b", "a\0b"] do
        assert {:ok, %{"isError" => true} = result} = Tools.call("read", %{"path" => path})
        assert text(result) =~ "can't"
      end

      assert {:ok, %{"isError" => true}} =
               Tools.call("move", %{"path" => "a", "destination" => "../../etc/x"})

      refute_received {:dufs, _, _, _, _, _}
    end
  end

  describe "errors" do
    test "another status is a tool error with dufs's body, cut to 500 characters" do
      dufs(&Plug.Conn.send_resp(&1, 500, String.duplicate("x", 600)))

      assert {:ok, %{"isError" => true} = result} = Tools.call("read", %{"path" => "a"})
      assert text(result) =~ "500"
      assert text(result) =~ String.duplicate("x", 500)
      refute text(result) =~ String.duplicate("x", 501)
    end

    test "the error starts with the status and dufs's body" do
      dufs(&Plug.Conn.send_resp(&1, 500, "disk full"))

      assert {:ok, result} = Tools.call("read", %{"path" => "a"})
      assert text(result) == "the files service answered 500: disk full"
    end

    test "a redirect from dufs is an error, not a success" do
      dufs(&Plug.Conn.send_resp(&1, 300, ""))

      assert {:ok, %{"isError" => true}} = Tools.call("mkdir", %{"path" => "a"})
    end

    test "dufs that can't be reached is a tool error saying so" do
      Req.Test.stub(FilesProxy, &Req.Test.transport_error(&1, :econnrefused))

      assert {:ok, %{"isError" => true} = result} = Tools.call("list", %{"path" => ""})
      assert text(result) =~ "couldn't reach the files service"
    end

    test "with no files service, the tool error says so" do
      Application.delete_env(:purple_flow, :files_url)

      assert {:ok, %{"isError" => true} = result} = Tools.call("list", %{"path" => ""})
      assert text(result) =~ "isn't set up"
    end

    test "no result or error contains dufs's login, even when dufs echoes it" do
      dufs(fn conn ->
        Plug.Conn.send_resp(conn, 500, inspect(conn.req_headers))
      end)

      assert {:ok, result} = Tools.call("read", %{"path" => "a"})
      refute text(result) =~ "agent-token"
      refute text(result) =~ Base.encode64("purpleflow:agent-token")
    end

    test "an unknown tool, or a missing argument, is a bad call" do
      assert {:error, :unknown_tool} = Tools.call("rm_rf", %{})
      assert {:error, {:invalid_arguments, message}} = Tools.call("write", %{"path" => "a"})
      assert message =~ "content"
      assert {:error, {:invalid_arguments, _}} = Tools.call("list", %{"path" => 7})
      assert {:error, {:invalid_arguments, _}} = Tools.call("list", ["hello"])
    end
  end
end
