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
      assert {:error, "takes one of body, body_file, and form, not more"} =
               Http.prepare(%{"body" => "x", "body_file" => "{{ input.doc }}"}, ".", ".")

      assert {:ok, _} = Http.prepare(%{"body" => "x"}, ".", ".")
      assert {:ok, _} = Http.prepare(%{"body_file" => "{{ input.doc }}"}, ".", ".")
    end
  end

  describe "form" do
    # Answers with the form's fields, and each file part's name, type, and bytes.
    defp echo_form do
      Req.Test.stub(Http, fn conn ->
        opts = Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: 10_000_000)
        conn = Plug.Parsers.call(conn, opts)

        fields =
          Map.new(conn.body_params, fn
            {name, %Plug.Upload{} = upload} ->
              {name,
               %{
                 "filename" => upload.filename,
                 "type" => upload.content_type,
                 "md5" => Base.encode16(:crypto.hash(:md5, File.read!(upload.path)))
               }}

            {name, value} ->
              {name, value}
          end)

        Req.Test.json(conn, fields)
      end)
    end

    test "file references become file parts, beside text fields", %{run_id: run_id} do
      bytes = :crypto.strong_rand_bytes(150_000)
      ref = run_file(run_id, bytes, "scan.pdf", "application/pdf")
      echo_form()

      assert {:ok, fields} =
               Http.execute(nil, %{
                 "method" => "POST",
                 "url" => "http://api.test/documents",
                 "form" => %{
                   "title" => "Q3",
                   "pages" => 4,
                   "tags" => ["a", "b"],
                   "doc" => ref
                 }
               })

      assert fields == %{
               "title" => "Q3",
               "pages" => "4",
               "tags" => ~s(["a","b"]),
               "doc" => %{
                 "filename" => "scan.pdf",
                 "type" => "application/pdf",
                 "md5" => Base.encode16(:crypto.hash(:md5, bytes))
               }
             }
    end

    test "a map that only looks like a reference is sent as text" do
      echo_form()

      assert {:ok, %{"note" => ~s({"file":"not-an-id"})}} =
               Http.execute(nil, %{
                 "method" => "POST",
                 "url" => "http://api.test/",
                 "form" => %{"note" => %{"file" => "not-an-id"}}
               })
    end

    test "a file that's gone fails before sending", %{run_id: run_id} do
      gone = run_file(run_id, "x", "a.txt", nil)
      RunFiles.delete_run(run_id)
      refuse_requests()

      assert {:error, "file " <> _} =
               Http.execute(nil, %{"url" => "http://api.test/", "form" => %{"doc" => gone}})
    end

    test "form with body or body_file fails to load; form alone loads" do
      for other <- ["body", "body_file"] do
        assert {:error, "takes one of body, body_file, and form, not more"} =
                 Http.prepare(%{"form" => %{}, other => "x"}, ".", ".")
      end

      assert {:ok, _} = Http.prepare(%{"form" => %{"a" => 1}}, ".", ".")
    end

    test "form must be a table, when it loads or once its placeholder is filled in" do
      assert {:error, "form must be a table of fields, not \"x\""} =
               Http.prepare(%{"form" => "x"}, ".", ".")

      assert {:ok, _} = Http.prepare(%{"form" => "{{ input.form }}"}, ".", ".")
      refuse_requests()

      assert {:error, "form must be a table of fields, not \"x\""} =
               Http.execute(nil, %{"url" => "http://api.test/", "form" => "x"})
    end
  end
end
