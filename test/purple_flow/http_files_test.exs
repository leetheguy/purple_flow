defmodule PurpleFlow.HttpFilesTest do
  # Files over HTTP: specs/260_file_transport.md.
  use ExUnit.Case, async: true

  alias PurpleFlow.{Id, RunFiles}
  alias PurpleFlow.Nodes.Http

  setup do
    run_id = Id.generate()
    on_exit(fn -> RunFiles.delete_run(run_id) end)
    %{run_id: run_id}
  end

  defp run_file(run_id, bytes, name, type) do
    {:ok, writer} = RunFiles.write(RunFiles.open(run_id, name, type, 0), bytes)
    RunFiles.close(writer)
  end

  # Answers with what the request carried.
  defp echo_request do
    Req.Test.stub(Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      Req.Test.json(conn, %{
        "type" => Plug.Conn.get_req_header(conn, "content-type"),
        "length" => Plug.Conn.get_req_header(conn, "content-length"),
        "md5" => Base.encode16(:crypto.hash(:md5, body))
      })
    end)
  end

  defp refuse_requests do
    Req.Test.stub(Http, fn _conn -> flunk("nothing should be sent") end)
  end

  describe "body_file" do
    test "sends the file whole, with the reference's type and the file's length",
         %{run_id: run_id} do
      bytes = :crypto.strong_rand_bytes(200_000)
      ref = run_file(run_id, bytes, "photo.jpg", "image/jpeg")
      echo_request()

      assert {:ok, response} =
               Http.execute(nil, %{
                 "method" => "PUT",
                 "url" => "http://api.test/photo.jpg",
                 "body_file" => ref
               })

      assert response == %{
               "type" => ["image/jpeg"],
               "length" => ["200000"],
               "md5" => Base.encode16(:crypto.hash(:md5, bytes))
             }
    end

    test "takes the bare file ID too", %{run_id: run_id} do
      ref = run_file(run_id, "hello", "a.txt", "text/plain")
      echo_request()

      assert {:ok, %{"length" => ["5"]}} =
               Http.execute(nil, %{
                 "method" => "PUT",
                 "url" => "http://api.test/",
                 "body_file" => ref["file"]
               })
    end

    test "a content-type in headers wins over the reference's", %{run_id: run_id} do
      ref = run_file(run_id, "a,b", "data.csv", "text/csv")
      echo_request()

      assert {:ok, %{"type" => ["application/octet-stream"]}} =
               Http.execute(nil, %{
                 "method" => "PUT",
                 "url" => "http://api.test/",
                 "headers" => %{"Content-Type" => "application/octet-stream"},
                 "body_file" => ref
               })
    end

    test "a value that isn't a file, or a file that's gone, fails before sending",
         %{run_id: run_id} do
      refuse_requests()

      assert {:error, "not a file: " <> _} =
               Http.execute(nil, %{"url" => "http://api.test/", "body_file" => "report.pdf"})

      gone = run_file(run_id, "x", "a", nil)
      RunFiles.delete_run(run_id)

      assert {:error, "file " <> _} =
               Http.execute(nil, %{"url" => "http://api.test/", "body_file" => gone})
    end

    test "body and body_file together fail to load; either alone loads" do
      assert {:error, "takes body or body_file, not both"} =
               Http.prepare(%{"body" => "x", "body_file" => "{{ input.doc }}"}, ".", ".")

      assert {:ok, _} = Http.prepare(%{"body" => "x"}, ".", ".")
      assert {:ok, _} = Http.prepare(%{"body_file" => "{{ input.doc }}"}, ".", ".")
    end
  end
end
