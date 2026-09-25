defmodule PurpleFlow.TemplateTest do
  use PurpleFlow.DataCase, async: true

  alias PurpleFlow.{Credentials, Template}

  @ctx %{
    input: %{"user" => %{"id" => 7, "tags" => ["a", "b"]}},
    steps: %{"fetch" => %{"output" => %{"total" => 3}}}
  }

  test "a string that's only a placeholder keeps the value's type" do
    assert {:ok, %{"id" => 7, "tags" => ["a", "b"]}, []} =
             Template.render(
               %{"id" => "{{ input.user.id }}", "tags" => "{{input.user.tags}}"},
               @ctx
             )
  end

  test "placeholders inside text become text" do
    assert {:ok, "user 7 has [\"a\",\"b\"]", []} =
             Template.render("user {{ input.user.id }} has {{ input.user.tags }}", @ctx)
  end

  test "list positions and ancestor outputs" do
    assert {:ok, ["b", 3], []} =
             Template.render(["{{ input.user.tags.1 }}", "{{ steps.fetch.output.total }}"], @ctx)
  end

  test "credentials are filled in and reported as secrets" do
    {:ok, cred} = Credentials.create("PF_TEMPLATE_TEST", "")
    {:ok, _} = Credentials.update(cred.id, %{key: "s3cret-token"})

    assert {:ok, "Bearer s3cret-token", ["s3cret-token"]} =
             Template.render("Bearer {{ creds.PF_TEMPLATE_TEST }}", @ctx)
  end

  test "missing things fail with a clear message" do
    assert {:error, "{{ input.user.nope }}: no \"nope\" found"} =
             Template.render("{{ input.user.nope }}", @ctx)

    assert {:error, "credential PF_NOT_SET_ANYWHERE isn't set — set it at /credentials"} =
             Template.render("{{ creds.PF_NOT_SET_ANYWHERE }}", @ctx)

    assert {:error, "step other isn't an ancestor, or didn't run"} =
             Template.render("{{ steps.other.output }}", @ctx)

    assert {:error, "don't know what {{ nonsense }} means"} =
             Template.render("{{ nonsense }}", @ctx)
  end

  test "refs lists placeholders without filling them in" do
    refs =
      Template.refs(%{
        "a" => "{{ creds.X }} {{ steps.fetch.output.y }}",
        "b" => ["{{ input.z }}"],
        "c" => 1
      })

    assert {:creds, "X"} in refs
    assert {:steps, "fetch", ["y"]} in refs
    assert {:input, ["z"]} in refs
  end
end
