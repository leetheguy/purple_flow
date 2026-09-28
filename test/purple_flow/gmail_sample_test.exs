defmodule PurpleFlow.GmailSampleTest do
  # samples/gmail end to end, with Gmail stubbed: the Code step builds the
  # message and the HTTP step sends it with the OAuth credential's token.
  use PurpleFlow.DataCase, async: false

  import PurpleFlow.WorkflowHelpers

  alias PurpleFlow.Credentials
  alias PurpleFlow.Credentials.Cipher

  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  test "sends the built message with the credential's access token" do
    {:ok, cred} =
      Credentials.create("GMAIL", "", %{type: "oauth", oauth: %{"client_id" => "cid"}})

    tokens =
      Jason.encode!(%{"access_token" => "ya29.tok", "refresh_token" => "r", "expires_at" => nil})

    PurpleFlow.Repo.update!(Ecto.Changeset.change(cred, key: Cipher.encrypt(tokens)))

    Req.Test.stub(PurpleFlow.Nodes.Http, fn conn ->
      assert conn.request_path == "/gmail/v1/users/me/messages/send"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ya29.tok"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = body |> Jason.decode!() |> Map.fetch!("raw") |> Base.url_decode64!(padding: false)
      assert message =~ "To: someone@example.com\r\n"
      assert message =~ "Subject: =?UTF-8?B?" <> Base.encode64("Hi ✉") <> "?=\r\n"
      Req.Test.json(conn, %{"id" => "m1", "labelIds" => ["SENT"]})
    end)

    {:ok, workflow} = PurpleFlow.Workflow.Loader.load("samples/gmail/workflow.toml", "samples")

    body = %{"to" => "someone@example.com", "subject" => "Hi ✉", "text" => "hello"}
    %{run: run, steps: steps} = run!(workflow, %{"body" => body})

    assert run.status == "complete"
    assert run.output == %{"id" => "m1", "labelIds" => ["SENT"]}

    # The token never reaches the saved records.
    refute inspect(steps) =~ "ya29.tok"
  end
end
