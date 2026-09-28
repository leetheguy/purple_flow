defmodule PurpleFlow.OAuthCredentialsTest do
  # OAuth credentials: specs/200_oauth_credentials.md.
  use PurpleFlow.DataCase, async: false

  alias PurpleFlow.Credentials
  alias PurpleFlow.Credentials.{Cipher, Credential, OAuth}
  alias PurpleFlow.Repo

  defp oauth!(tokens) do
    {:ok, cred} =
      Credentials.create("GMAIL", "", %{
        type: "oauth",
        oauth: %{"client_id" => "cid", "scopes" => "mail.send"},
        client_secret: "shh"
      })

    if tokens do
      cred |> Ecto.Changeset.change(key: Cipher.encrypt(Jason.encode!(tokens))) |> Repo.update!()
    end

    cred
  end

  defp expires_in(seconds), do: System.system_time(:second) + seconds

  defp token_endpoint(fun) do
    Req.Test.stub(OAuth, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fun.(conn, URI.decode_query(body))
    end)
  end

  test "a fresh access token is handed out without asking the provider" do
    oauth!(%{"access_token" => "a1", "refresh_token" => "r1", "expires_at" => expires_in(600)})
    token_endpoint(fn _conn, _params -> flunk("shouldn't renew") end)

    assert Credentials.get("GMAIL") == "a1"
  end

  test "an expired token is renewed, saved, and handed out; the refresh token is kept" do
    oauth!(%{"access_token" => "old", "refresh_token" => "r1", "expires_at" => expires_in(10)})

    token_endpoint(fn conn, params ->
      assert conn.request_path == "/token"

      assert %{
               "grant_type" => "refresh_token",
               "refresh_token" => "r1",
               "client_id" => "cid",
               "client_secret" => "shh"
             } = params

      Req.Test.json(conn, %{"access_token" => "new", "expires_in" => 3600})
    end)

    assert Credentials.get("GMAIL") == "new"

    token_endpoint(fn _conn, _params -> flunk("shouldn't renew again") end)
    assert Credentials.get("GMAIL") == "new"

    cred = Repo.get_by!(Credential, name: "GMAIL")
    assert %{"refresh_token" => "r1"} = cred.key |> Cipher.decrypt() |> Jason.decode!()
  end

  test "a refused renewal marks the credential and says to reconnect" do
    oauth!(%{"access_token" => "old", "refresh_token" => "r1", "expires_at" => expires_in(-5)})

    token_endpoint(fn conn, _params ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => "invalid_grant",
        "error_description" => "Token has been expired or revoked."
      })
    end)

    assert {:error, message} = Credentials.get("GMAIL")
    assert message =~ "credential GMAIL needs reconnecting at /credentials"
    assert message =~ "Token has been expired or revoked."
    assert [%{oauth_error: "Token has been expired or revoked."}] = Credentials.list()

    # A step using it fails with the same message.
    assert {:error, ^message} =
             PurpleFlow.Template.render(%{"auth" => "Bearer {{ creds.GMAIL }}"}, %{
               input: nil,
               steps: %{}
             })
  end

  test "many callers at the moment it expires renew it once" do
    oauth!(%{"access_token" => "old", "refresh_token" => "r1", "expires_at" => expires_in(0)})
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    token_endpoint(fn conn, _params ->
      Agent.update(calls, &(&1 + 1))
      Process.sleep(50)
      Req.Test.json(conn, %{"access_token" => "new", "expires_in" => 3600})
    end)

    tokens =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> Credentials.get("GMAIL") end) end)
      |> Task.await_many()

    assert Enum.uniq(tokens) == ["new"]
    assert Agent.get(calls, & &1) == 1
  end

  test "an OAuth credential isn't set until it's connected" do
    cred = oauth!(nil)
    assert Credentials.get("GMAIL") == nil
    refute Credentials.set?("GMAIL")
    assert [%{type: "oauth", set: false}] = Credentials.list()
    assert Credentials.fetch(cred.id).client_secret != "shh"
  end

  test "an OAuth credential needs a client ID" do
    assert {:error, changeset} =
             Credentials.create("X", "", %{type: "oauth", oauth: %{"client_id" => " "}})

    assert %{oauth: ["needs a client ID"]} = errors_on(changeset)
  end

  test "the authorize address carries the client, scopes, state, and PKCE challenge" do
    cred = oauth!(nil)
    url = OAuth.authorize_url(cred, "https://pf.test/cb", "st4te", "verifier")

    assert "https://accounts.google.com/o/oauth2/v2/auth?" <> query = url

    assert %{
             "client_id" => "cid",
             "redirect_uri" => "https://pf.test/cb",
             "scope" => "mail.send",
             "state" => "st4te",
             "response_type" => "code",
             "code_challenge_method" => "S256",
             "code_challenge" => challenge,
             "access_type" => "offline"
           } = URI.decode_query(query)

    assert challenge == Base.url_encode64(:crypto.hash(:sha256, "verifier"), padding: false)
  end
end
