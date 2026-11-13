defmodule PurpleFlow.MCPConnectionsTest do
  use PurpleFlow.DataCase, async: true

  alias PurpleFlow.MCPConnections
  alias PurpleFlow.MCPConnections.Connection

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  # The S256 challenge for @verifier, from RFC 7636's appendix B.
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @client "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @redirect "https://claude.ai/api/mcp/auth_callback"
  @t0 ~U[2026-11-13 12:00:00.000000Z]

  defp allow(now \\ @t0) do
    {:ok, code} =
      MCPConnections.allow(
        %{
          client_id: @client,
          client_name: "Claude",
          redirect_uri: @redirect,
          code_challenge: @challenge
        },
        now
      )

    code
  end

  defp exchange(code, overrides \\ %{}, now \\ @t0) do
    %{
      "code" => code,
      "code_verifier" => @verifier,
      "client_id" => @client,
      "redirect_uri" => @redirect
    }
    |> Map.merge(overrides)
    |> MCPConnections.exchange_code(now)
  end

  defp connected(now \\ @t0) do
    {:ok, tokens} = exchange(allow(now), %{}, now)
    tokens
  end

  describe "trading a code for tokens" do
    test "the right code and verifier get an access token and a refresh token" do
      assert {:ok, tokens} = exchange(allow())
      assert %{access_token: access, refresh_token: refresh, expires_in: 3600} = tokens
      assert is_binary(access) and is_binary(refresh) and access != refresh
      assert {:ok, %Connection{client_name: "Claude"}} = MCPConnections.verify_access(access, @t0)
    end

    test "a wrong verifier is refused" do
      assert {:error, :invalid_grant} =
               exchange(allow(), %{"code_verifier" => String.duplicate("a", 43)})
    end

    test "a missing verifier is refused" do
      assert {:error, :invalid_grant} = exchange(allow(), %{"code_verifier" => nil})
    end

    test "a code works once" do
      code = allow()
      assert {:ok, _} = exchange(code)
      assert {:error, :invalid_grant} = exchange(code)
    end

    test "a code works for 60 seconds, and not after" do
      assert {:ok, _} = exchange(allow(), %{}, DateTime.add(@t0, 60))
      assert {:error, :invalid_grant} = exchange(allow(), %{}, DateTime.add(@t0, 61))
    end

    test "a different client_id or redirect_uri is refused" do
      assert {:error, :invalid_grant} =
               exchange(allow(), %{"client_id" => "https://evil.example/c"})

      assert {:error, :invalid_grant} =
               exchange(allow(), %{"redirect_uri" => "https://evil.example/cb"})
    end

    test "an unknown code is refused" do
      assert {:error, :invalid_grant} = exchange("nope")
    end
  end

  describe "access tokens" do
    test "work for an hour, and not after" do
      %{access_token: access} = connected()

      assert {:ok, _} = MCPConnections.verify_access(access, DateTime.add(@t0, 3599))
      assert :error = MCPConnections.verify_access(access, DateTime.add(@t0, 3600))
    end

    test "an unknown token doesn't work" do
      assert :error = MCPConnections.verify_access("nope", @t0)
    end

    test "using one records when the app was last used" do
      %{access_token: access} = connected()
      later = DateTime.add(@t0, 30)

      assert {:ok, _} = MCPConnections.verify_access(access, later)
      assert [%Connection{last_used_at: ^later}] = MCPConnections.list()
    end
  end

  describe "refreshing" do
    test "a refresh token gets new tokens, and then stops working" do
      %{access_token: old_access, refresh_token: old_refresh} = connected()
      later = DateTime.add(@t0, 7200)

      assert {:ok, %{access_token: access, refresh_token: refresh}} =
               MCPConnections.refresh(
                 %{"refresh_token" => old_refresh, "client_id" => @client},
                 later
               )

      assert {:ok, _} = MCPConnections.verify_access(access, later)
      assert :error = MCPConnections.verify_access(old_access, @t0)
      assert refresh != old_refresh

      assert {:error, :invalid_grant} =
               MCPConnections.refresh(
                 %{"refresh_token" => old_refresh, "client_id" => @client},
                 later
               )
    end

    test "works without a client_id, but not with another one" do
      %{refresh_token: refresh} = connected()

      assert {:error, :invalid_grant} =
               MCPConnections.refresh(
                 %{"refresh_token" => refresh, "client_id" => "https://x.example/c"},
                 @t0
               )

      assert {:ok, _} = MCPConnections.refresh(%{"refresh_token" => refresh}, @t0)
    end

    test "an unknown refresh token is refused" do
      assert {:error, :invalid_grant} = MCPConnections.refresh(%{"refresh_token" => "nope"}, @t0)
    end
  end

  describe "connected apps" do
    test "lists only apps that finished signing in" do
      _abandoned = allow()
      connected()

      assert [%Connection{client_name: "Claude", access_hash: hash}] = MCPConnections.list()
      assert is_binary(hash)
    end

    test "a new sign-in clears out codes nobody used, but not connected apps or live codes" do
      connected()
      live = allow(DateTime.add(@t0, 60))
      _stale = allow()

      allow(DateTime.add(@t0, 120))

      assert [%Connection{}] = MCPConnections.list()
      assert Repo.aggregate(Connection, :count) == 3
      assert {:ok, _} = exchange(live, %{}, DateTime.add(@t0, 120))
    end

    test "connecting the same app again replaces its earlier connection" do
      %{access_token: old_access, refresh_token: old_refresh} = connected()
      %{access_token: new_access} = connected(DateTime.add(@t0, 10))

      assert [%Connection{}] = MCPConnections.list()
      assert :error = MCPConnections.verify_access(old_access, DateTime.add(@t0, 10))
      assert {:ok, _} = MCPConnections.verify_access(new_access, DateTime.add(@t0, 10))

      assert {:error, :invalid_grant} =
               MCPConnections.refresh(%{"refresh_token" => old_refresh}, @t0)
    end

    test "an abandoned second sign-in leaves the first connection working" do
      %{access_token: access} = connected()
      _abandoned = allow(DateTime.add(@t0, 10))

      assert {:ok, _} = MCPConnections.verify_access(access, DateTime.add(@t0, 10))
    end

    test "disconnecting one stops its tokens at once" do
      %{access_token: access, refresh_token: refresh} = connected()
      [connection] = MCPConnections.list()

      assert :ok = MCPConnections.disconnect(connection.id)
      assert :error = MCPConnections.verify_access(access, @t0)
      assert {:error, :invalid_grant} = MCPConnections.refresh(%{"refresh_token" => refresh}, @t0)
      assert MCPConnections.list() == []
    end

    test "nothing is stored in the clear" do
      code = allow()
      {:ok, %{access_token: access, refresh_token: refresh}} = exchange(code)

      stored = Repo.all(Connection) |> inspect(limit: :infinity)

      for secret <- [code, access, refresh] do
        refute stored =~ secret
        refute stored =~ inspect(secret)
      end
    end
  end
end
