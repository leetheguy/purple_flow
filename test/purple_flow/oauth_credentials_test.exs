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

  describe "renewing, when things go wrong" do
    test "a token without an expiry is used until the provider refuses it" do
      oauth!(%{"access_token" => "old", "refresh_token" => "r1", "expires_at" => expires_in(-5)})
      token_endpoint(fn conn, _params -> Req.Test.json(conn, %{"access_token" => "forever"}) end)

      assert Credentials.get("GMAIL") == "forever"

      token_endpoint(fn _conn, _params -> flunk("shouldn't renew") end)
      assert Credentials.get("GMAIL") == "forever"
    end

    test "saved tokens without an access token are renewed first" do
      oauth!(%{"refresh_token" => "r1"})
      token_endpoint(fn conn, _params -> Req.Test.json(conn, %{"access_token" => "a1"}) end)

      assert Credentials.get("GMAIL") == "a1"
    end

    test "an expired token with no refresh token says to reconnect" do
      oauth!(%{"access_token" => "old", "expires_at" => expires_in(-5)})
      token_endpoint(fn _conn, _params -> flunk("nothing to renew with") end)

      assert {:error, message} = Credentials.get("GMAIL")
      assert message =~ "needs reconnecting at /credentials (no refresh token was given)"
      assert [%{oauth_error: "no refresh token was given"}] = Credentials.list()
    end

    test "a provider outage fails the step but doesn't ask for a reconnect" do
      oauth!(%{"access_token" => "old", "refresh_token" => "r1", "expires_at" => expires_in(-5)})

      token_endpoint(fn conn, _params ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "backend_error"})
      end)

      assert {:error, "credential GMAIL couldn't be renewed: backend_error"} =
               Credentials.get("GMAIL")

      assert [%{oauth_error: nil}] = Credentials.list()

      token_endpoint(fn conn, _params -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, "credential GMAIL couldn't be renewed: " <> why} = Credentials.get("GMAIL")
      assert why =~ "timeout"
      assert [%{oauth_error: nil}] = Credentials.list()
    end

    test "a refusal with no description says the status" do
      oauth!(%{"access_token" => "old", "refresh_token" => "r1", "expires_at" => expires_in(-5)})
      token_endpoint(fn conn, _params -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, message} = Credentials.get("GMAIL")
      assert message =~ "needs reconnecting at /credentials (HTTP 401)"
    end

    test "a credential saved without a client secret sends an empty one" do
      {:ok, cred} =
        Credentials.create("NOSECRET", "", %{type: "oauth", oauth: %{"client_id" => "cid"}})

      tokens = %{"access_token" => "old", "refresh_token" => "r1", "expires_at" => expires_in(-5)}
      cred |> Ecto.Changeset.change(key: Cipher.encrypt(Jason.encode!(tokens))) |> Repo.update!()

      token_endpoint(fn conn, params ->
        assert %{"client_id" => "cid", "client_secret" => ""} = params
        Req.Test.json(conn, %{"access_token" => "new", "expires_in" => 3600})
      end)

      assert Credentials.get("NOSECRET") == "new"
    end
  end

  describe "connecting" do
    test "trades the code for tokens and saves them" do
      cred = oauth!(nil)

      token_endpoint(fn conn, params ->
        assert %{
                 "grant_type" => "authorization_code",
                 "code" => "c0de",
                 "redirect_uri" => "https://pf.test/cb",
                 "code_verifier" => "verifier"
               } = params

        Req.Test.json(conn, %{"access_token" => "a1", "refresh_token" => "r1", "expires_in" => 60})
      end)

      assert {:ok, %Credential{oauth_error: nil}} =
               OAuth.connect(cred, "c0de", "https://pf.test/cb", "verifier")

      assert Credentials.set?("GMAIL")
    end

    test "a refused code is an error, and nothing is saved" do
      cred = oauth!(nil)

      token_endpoint(fn conn, _params ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, "invalid_grant"} = OAuth.connect(cred, "bad", "https://pf.test/cb", "v")
      refute Credentials.set?("GMAIL")
    end

    test "a provider with its own authorize address keeps its query string" do
      {:ok, cred} =
        Credentials.create("OTHER", "", %{
          type: "oauth",
          oauth: %{"client_id" => "cid", "auth_url" => "https://idp.test/auth?tenant=t1"}
        })

      assert "https://idp.test/auth?tenant=t1&" <> query =
               OAuth.authorize_url(cred, "https://pf.test/cb", "s", "v")

      assert %{"client_id" => "cid", "scope" => ""} = URI.decode_query(query)
    end
  end
end
