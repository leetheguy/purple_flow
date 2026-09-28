defmodule PurpleFlowWeb.OAuthControllerTest do
  # Connecting an OAuth credential: specs/200_oauth_credentials.md.
  use PurpleFlowWeb.ConnCase, async: false

  alias PurpleFlow.Credentials
  alias PurpleFlow.Credentials.OAuth

  setup do
    {:ok, cred} =
      Credentials.create("GMAIL", "", %{
        type: "oauth",
        oauth: %{"client_id" => "cid", "scopes" => "mail.send"},
        client_secret: "shh"
      })

    %{cred: cred}
  end

  defp start_connect(conn, cred) do
    conn = get(conn, ~p"/credentials/#{cred.id}/connect")
    "https://accounts.google.com/o/oauth2/v2/auth?" <> query = redirected_to(conn, 302)
    {conn, URI.decode_query(query)}
  end

  test "connect sends the browser to the provider, and the callback saves the tokens",
       %{conn: conn, cred: cred} do
    {conn, query} = start_connect(conn, cred)
    assert query["redirect_uri"] == PurpleFlowWeb.OAuthController.callback_url()

    Req.Test.stub(OAuth, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert %{"grant_type" => "authorization_code", "code" => "c0de"} = params

      # The verifier matches the challenge the browser carried.
      assert Base.url_encode64(:crypto.hash(:sha256, params["code_verifier"]), padding: false) ==
               query["code_challenge"]

      Req.Test.json(conn, %{"access_token" => "a1", "refresh_token" => "r1", "expires_in" => 3600})
    end)

    conn =
      conn
      |> recycle()
      |> get(~p"/credentials/oauth/callback", %{"state" => query["state"], "code" => "c0de"})

    assert redirected_to(conn) == ~p"/credentials"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "GMAIL connected"
    assert Credentials.get("GMAIL") == "a1"
  end

  test "a callback with the wrong state saves nothing", %{conn: conn, cred: cred} do
    {conn, _query} = start_connect(conn, cred)
    Req.Test.stub(OAuth, fn _conn -> flunk("shouldn't trade the code") end)

    conn =
      conn
      |> recycle()
      |> get(~p"/credentials/oauth/callback", %{"state" => "forged", "code" => "c0de"})

    assert redirected_to(conn) == ~p"/credentials"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't match"
    assert Credentials.get("GMAIL") == nil
  end

  test "a refusal at the provider saves nothing", %{conn: conn, cred: cred} do
    {conn, query} = start_connect(conn, cred)

    conn =
      conn
      |> recycle()
      |> get(~p"/credentials/oauth/callback", %{
        "state" => query["state"],
        "error" => "access_denied"
      })

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "access_denied"
    assert Credentials.get("GMAIL") == nil
  end

  test "a callback no connect started saves nothing", %{conn: conn} do
    conn = get(conn, ~p"/credentials/oauth/callback", %{"state" => "x", "code" => "c0de"})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no connection was started"
  end

  test "connect for a text credential goes back to the page", %{conn: conn} do
    {:ok, text} = Credentials.create("PLAIN", "")
    conn = get(conn, ~p"/credentials/#{text.id}/connect")
    assert redirected_to(conn) == ~p"/credentials"
  end
end
