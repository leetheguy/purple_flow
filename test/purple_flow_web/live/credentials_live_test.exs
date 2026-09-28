defmodule PurpleFlowWeb.CredentialsLiveTest do
  use PurpleFlowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PurpleFlow.Credentials

  test "the add row creates a credential and resets itself", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/credentials")

    html =
      view
      |> form("#add-credential-form", %{
        "credential" => %{
          "name" => "STRIPE_KEY",
          "description" => "checkout",
          "key" => "sk_live_x"
        }
      })
      |> render_submit()

    assert html =~ "STRIPE_KEY"
    assert html =~ "checkout"
    assert Credentials.get("STRIPE_KEY") == "sk_live_x"

    # the form resets to empty
    assert view |> element("#add-credential-form input[name='credential[name]']") |> render() =~
             ~s(value="")
  end

  test "Clear blanks the add row without writing anything", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/credentials")

    typed = %{"credential" => %{"name" => "DRAFT", "description" => "half", "key" => "typed"}}
    view |> form("#add-credential-form", typed) |> render_change()

    assert has_element?(
             view,
             ~s(#add-credential-form input[name="credential[name]"][value="DRAFT"])
           )

    view |> element("#add-credential-form button", "Clear") |> render_click()

    for field <- ~w(name description key) do
      assert has_element?(
               view,
               ~s(#add-credential-form input[name="credential[#{field}]"][value=""])
             )
    end

    assert Credentials.list() == []
  end

  test "Save clears what was typed into the add row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/credentials")

    typed = %{"credential" => %{"name" => "TOKEN", "description" => "api", "key" => "t0k"}}
    view |> form("#add-credential-form", typed) |> render_change()
    view |> form("#add-credential-form", typed) |> render_submit()

    assert Credentials.get("TOKEN") == "t0k"

    for field <- ~w(name description key) do
      assert has_element?(
               view,
               ~s(#add-credential-form input[name="credential[#{field}]"][value=""])
             )
    end
  end

  test "Edit switches the row to inputs, with the secret field empty", %{conn: conn} do
    {:ok, cred} = Credentials.create("A", "first")
    {:ok, _} = Credentials.update(cred.id, %{key: "secret-value"})

    {:ok, view, _html} = live(conn, ~p"/credentials")

    html = view |> element("#credential-#{cred.id} button[phx-click=edit]") |> render_click()

    assert html =~ ~s(value="A")
    assert html =~ ~s(value="first")
    refute html =~ "secret-value"
    assert html =~ ~s(name="credential[key]")
  end

  test "Cancel discards edits without writing anything", %{conn: conn} do
    {:ok, cred} = Credentials.create("A", "first")

    {:ok, view, _html} = live(conn, ~p"/credentials")
    view |> element("#credential-#{cred.id} button[phx-click=edit]") |> render_click()

    html = view |> element("#edit-credential-form-#{cred.id} button", "Cancel") |> render_click()

    refute html =~ "edit-credential-form"
    [row] = Credentials.list()
    assert row.name == "A"
    assert row.description == "first"
  end

  test "Save persists changes, leaving the secret untouched when left empty", %{conn: conn} do
    {:ok, cred} = Credentials.create("A", "first")
    {:ok, _} = Credentials.update(cred.id, %{key: "secret-value"})

    {:ok, view, _html} = live(conn, ~p"/credentials")
    view |> element("#credential-#{cred.id} button[phx-click=edit]") |> render_click()

    view
    |> form("#edit-credential-form-#{cred.id}", %{
      "credential" => %{"name" => "A", "description" => "second", "key" => ""}
    })
    |> render_submit()

    assert Credentials.get("A") == "secret-value"
    [row] = Credentials.list()
    assert row.description == "second"
  end

  test "Save with a new secret value replaces the stored one", %{conn: conn} do
    {:ok, cred} = Credentials.create("A", "")
    {:ok, _} = Credentials.update(cred.id, %{key: "old"})

    {:ok, view, _html} = live(conn, ~p"/credentials")
    view |> element("#credential-#{cred.id} button[phx-click=edit]") |> render_click()

    view
    |> form("#edit-credential-form-#{cred.id}", %{
      "credential" => %{"name" => "A", "description" => "", "key" => "new"}
    })
    |> render_submit()

    assert Credentials.get("A") == "new"
  end

  test "a set credential's value never appears in the rendered page", %{conn: conn} do
    {:ok, cred} = Credentials.create("A", "")
    {:ok, _} = Credentials.update(cred.id, %{key: "super-secret-value"})

    {:ok, view, html} = live(conn, ~p"/credentials")
    refute html =~ "super-secret-value"

    edit_html = view |> element("#credential-#{cred.id} button[phx-click=edit]") |> render_click()
    refute edit_html =~ "super-secret-value"
  end

  test "archiving a row removes it from the list and frees its name", %{conn: conn} do
    {:ok, cred} = Credentials.create("A", "")

    {:ok, view, _html} = live(conn, ~p"/credentials")
    html = view |> element("#credential-#{cred.id} button[phx-click=archive]") |> render_click()

    refute html =~ "id=\"credential-#{cred.id}\""
    assert {:ok, _} = Credentials.create("A", "reused")
  end

  test "the search box filters by name and description", %{conn: conn} do
    {:ok, _} = Credentials.create("STRIPE_KEY", "checkout")
    {:ok, _} = Credentials.create("TELEGRAM_TOKEN", "bot")

    {:ok, view, _html} = live(conn, ~p"/credentials")

    html = view |> element("#credentials-search") |> render_keyup(%{"value" => "stripe"})
    assert html =~ "STRIPE_KEY"
    refute html =~ "TELEGRAM_TOKEN"

    html = view |> element("#credentials-search") |> render_keyup(%{"value" => "bot"})
    assert html =~ "TELEGRAM_TOKEN"
    refute html =~ "STRIPE_KEY"
  end

  describe "OAuth" do
    test "picking OAuth shows its fields, and saving goes to connect", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/credentials")
      refute has_element?(view, "#add-credential-form input[name='credential[client_id]']")

      view
      |> form("#add-credential-form", %{"credential" => %{"type" => "oauth"}})
      |> render_change()

      assert has_element?(view, "#add-credential-form input[name='credential[client_id]']")
      assert has_element?(view, "#add-credential-form input[name='credential[client_secret]']")
      assert has_element?(view, "#add-credential-form input[name='credential[scopes]']")
      assert has_element?(view, "#callback-url-add")
      refute has_element?(view, "#add-credential-form input[name='credential[key]']")

      assert {:error, {:redirect, %{to: to}}} =
               view
               |> form("#add-credential-form", %{
                 "credential" => %{
                   "type" => "oauth",
                   "name" => "GMAIL",
                   "client_id" => "cid",
                   "client_secret" => "shh",
                   "scopes" => "https://www.googleapis.com/auth/gmail.send"
                 }
               })
               |> render_submit()

      [cred] = Credentials.list()
      assert to == ~p"/credentials/#{cred.id}/connect"
      assert %{type: "oauth", set: false} = cred
      assert cred.oauth["auth_url"] =~ "accounts.google.com"
    end

    test "without a client ID it isn't saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/credentials")

      view
      |> form("#add-credential-form", %{"credential" => %{"type" => "oauth"}})
      |> render_change()

      html =
        view
        |> form("#add-credential-form", %{"credential" => %{"type" => "oauth", "name" => "G"}})
        |> render_submit()

      assert html =~ "needs a client ID"
      assert Credentials.list() == []
    end

    test "Reconnect is red until it's connected", %{conn: conn} do
      {:ok, cred} =
        Credentials.create("GMAIL", "", %{type: "oauth", oauth: %{"client_id" => "cid"}})

      {:ok, view, _html} = live(conn, ~p"/credentials")
      assert has_element?(view, "#reconnect-#{cred.id}.bg-red-500")
      assert view |> element("#credential-state-#{cred.id}") |> render() =~ "not connected"

      tokens =
        Jason.encode!(%{"access_token" => "a", "refresh_token" => "r", "expires_at" => nil})

      PurpleFlow.Repo.update!(
        Ecto.Changeset.change(cred, key: PurpleFlow.Credentials.Cipher.encrypt(tokens))
      )

      {:ok, view, _html} = live(conn, ~p"/credentials")
      refute has_element?(view, "#reconnect-#{cred.id}.bg-red-500")
      assert view |> element("#credential-state-#{cred.id}") |> render() =~ "connected"
    end

    test "editing keeps the client secret when it's left blank", %{conn: conn} do
      {:ok, cred} =
        Credentials.create("GMAIL", "", %{
          type: "oauth",
          oauth: %{"client_id" => "cid"},
          client_secret: "shh"
        })

      before = Credentials.fetch(cred.id).client_secret
      {:ok, view, _html} = live(conn, ~p"/credentials")
      view |> element("#credential-#{cred.id} button[phx-click=edit]") |> render_click()

      view
      |> form("#edit-credential-form-#{cred.id}", %{
        "credential" => %{"name" => "GMAIL", "client_id" => "cid2", "client_secret" => ""}
      })
      |> render_submit()

      after_edit = Credentials.fetch(cred.id)
      assert after_edit.client_secret == before
      assert after_edit.oauth["client_id"] == "cid2"
    end
  end
end
