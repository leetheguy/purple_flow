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

    view |> element("#add-credential-form button", "Clear") |> render_click()

    assert Credentials.list() == []
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

    html = view |> element("#credentials-search") |> render_keyup(%{"q" => "stripe"})
    assert html =~ "STRIPE_KEY"
    refute html =~ "TELEGRAM_TOKEN"

    html = view |> element("#credentials-search") |> render_keyup(%{"q" => "bot"})
    assert html =~ "TELEGRAM_TOKEN"
    refute html =~ "STRIPE_KEY"
  end
end
